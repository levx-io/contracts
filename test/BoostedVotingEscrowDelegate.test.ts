import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { divf, expectApproxEqual, expectZero, getBlockTimestamp, mine, PRECISION_BASE, sleep } from "./utils";
import { BigNumber, constants, Signer } from "ethers";
import { BoostedVotingEscrowDelegate, ERC20Mock, NFTMock, VotingEscrow } from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signers";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const H = 3600;
const DAY = 86400;
const NUMBER_OF_DAYS = 3;
const INTERVAL = NUMBER_OF_DAYS * DAY;
const MIN_NUMBER_OF_DAYS = 219;
const MAX_NUMBER_OF_DAYS = 729;
const MIN_DURATION = MIN_NUMBER_OF_DAYS * DAY;
const MAX_DURATION = MAX_NUMBER_OF_DAYS * DAY;
const TOL = PRECISION_BASE.mul(120).div(INTERVAL);

const MAX_BOOST = 10;

const setupTest = async () => {
    const signers = await ethers.getSigners();
    const [alice, bob] = signers;

    const Token = await ethers.getContractFactory("ERC20Mock");
    const token = (await Token.deploy("Token", "TOKEN", constants.WeiPerEther.mul(2100000))) as ERC20Mock;

    const VE = await ethers.getContractFactory("VotingEscrow");
    const ve = (await VE.deploy(token.address, "veToken", "VE", INTERVAL, MAX_DURATION)) as VotingEscrow;

    const DiscountToken = await ethers.getContractFactory("NFTMock");
    const discountToken = (await DiscountToken.deploy("Discount", "DISC")) as NFTMock;

    const Delegate = await ethers.getContractFactory("BoostedVotingEscrowDelegate");
    const delegate = (await Delegate.deploy(
        token.address,
        ve.address,
        discountToken.address,
        MIN_DURATION,
        MAX_BOOST,
        constants.MaxUint256
    )) as BoostedVotingEscrowDelegate;
    await ve.setDelegate(delegate.address, true);

    const totalSupply = async (): Promise<BigNumber> => await ve["totalSupply()"]();
    const totalSupplyAt = async (block: number): Promise<BigNumber> => await ve.totalSupplyAt(block);
    const balanceOf = async (account: SignerWithAddress): Promise<BigNumber> =>
        await ve["balanceOf(address)"](account.address);
    const balanceOfAt = async (account: Signer, block: number): Promise<BigNumber> =>
        await ve.balanceOfAt(await account.getAddress(), block);

    return {
        alice,
        bob,
        token,
        ve,
        delegate,
        totalSupply,
        totalSupplyAt,
        balanceOf,
        balanceOfAt,
    };
};

describe("BoostedVotingEscrowDelegate", () => {
    beforeEach(async () => {
        await ethers.provider.send("hardhat_reset", []);
    });

    it("should createLock()", async () => {
        const { token, ve, delegate, alice, bob, totalSupply, balanceOf } = await setupTest();

        const amount = constants.WeiPerEther.mul(1000);
        await token.connect(alice).transfer(bob.address, amount);

        await token.connect(alice).approve(ve.address, amount.mul(10));
        await token.connect(bob).approve(ve.address, amount.mul(10));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));

        // Move to timing which is good for testing - beginning of a UTC week
        let ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await sleep(H);

        await expect(delegate.connect(alice).createLock(amount, MIN_DURATION - 1)).to.be.revertedWith(
            "BVED: DURATION_TOO_SHORT"
        );
        await delegate.connect(alice).createLock(amount, MIN_DURATION);

        await sleep(H);
        await mine();

        let boosted_alice = amount.mul(MAX_BOOST).mul(MIN_DURATION).div(MAX_DURATION);
        expectApproxEqual(await totalSupply(), boosted_alice.div(MAX_DURATION).mul(MIN_DURATION - 2 * H), TOL);
        expectApproxEqual(await balanceOf(alice), boosted_alice.div(MAX_DURATION).mul(MIN_DURATION - 2 * H), TOL);
        expectZero(await balanceOf(bob));
        let t0 = await getBlockTimestamp();

        for (let i = 0; i < MIN_NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            expectApproxEqual(
                await totalSupply(),
                boosted_alice.div(MAX_DURATION).mul(Math.max(MIN_DURATION - 2 * H - dt, 0)),
                TOL
            );
            expectApproxEqual(
                await balanceOf(alice),
                boosted_alice.div(MAX_DURATION).mul(Math.max(MIN_DURATION - 2 * H - dt, 0)),
                TOL
            );
            expectZero(await balanceOf(bob));
        }

        await sleep(H);

        expectZero(await balanceOf(alice));
        await ve.connect(alice).withdraw();

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));

        await sleep(H);
        await mine();

        // Next interval (for round counting)
        ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await delegate.connect(alice).createLock(amount, 2 * MIN_DURATION);

        boosted_alice = amount
            .mul(MAX_BOOST)
            .mul(2 * MIN_DURATION)
            .div(MAX_DURATION);
        expectApproxEqual(await totalSupply(), boosted_alice.div(MAX_DURATION).mul(2).mul(MIN_DURATION), TOL);
        expectApproxEqual(await balanceOf(alice), boosted_alice.div(MAX_DURATION).mul(2).mul(MIN_DURATION), TOL);
        expectZero(await balanceOf(bob));

        await delegate.connect(bob).createLock(amount, MIN_DURATION);

        const boosted_bob = amount.mul(MAX_BOOST).mul(MIN_DURATION).div(MAX_DURATION);
        expectApproxEqual(
            await totalSupply(),
            boosted_alice
                .div(MAX_DURATION)
                .mul(2)
                .mul(MIN_DURATION)
                .add(boosted_bob.div(MAX_DURATION).mul(MIN_DURATION)),
            TOL
        );
        expectApproxEqual(await balanceOf(alice), boosted_alice.div(MAX_DURATION).mul(2).mul(MIN_DURATION), TOL);
        expectApproxEqual(await balanceOf(bob), boosted_bob.div(MAX_DURATION).mul(MIN_DURATION), TOL);

        t0 = await getBlockTimestamp();
        await sleep(H);
        await mine();

        for (let i = 0; i < MIN_NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            const w_total = await totalSupply();
            const w_alice = await balanceOf(alice);
            const w_bob = await balanceOf(bob);
            expect(w_total).to.be.equal(w_alice.add(w_bob));
            expectApproxEqual(w_alice, boosted_alice.div(MAX_DURATION).mul(Math.max(2 * MIN_DURATION - dt, 0)), TOL);
            expectApproxEqual(w_bob, boosted_bob.div(MAX_DURATION).mul(Math.max(MIN_DURATION - dt, 0)), TOL);
        }

        await sleep(H);
        await mine();

        await ve.connect(bob).withdraw();
        t0 = await getBlockTimestamp();

        const w_total = await totalSupply();
        const w_alice = await balanceOf(alice);
        expect(w_total).to.be.equal(w_alice);
        expectApproxEqual(w_total, boosted_alice.div(MAX_DURATION).mul(MIN_DURATION - 2 * H), TOL);
        expectZero(await balanceOf(bob));

        await sleep(H);
        await mine();

        for (let i = 0; i < MIN_NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            const w_total = await totalSupply();
            const w_alice = await balanceOf(alice);
            expect(w_total).to.be.equal(w_alice);
            expectApproxEqual(
                w_alice,
                boosted_alice.div(MAX_DURATION).mul(Math.max(MIN_DURATION - dt - 2 * H, 0)),
                TOL
            );
            expectZero(await balanceOf(bob));
        }

        await ve.connect(alice).withdraw();

        await sleep(H);
        await mine();

        await ve.connect(bob).withdraw();

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));

        await sleep(H);

        await expect(delegate.connect(alice).createLock(amount, MAX_DURATION + INTERVAL)).to.be.revertedWith(
            "VED: DURATION_TOO_LONG"
        );
        ts = await getBlockTimestamp();
        await delegate.connect(alice).createLock(amount, MAX_DURATION);

        await sleep(H);
        await mine();

        const duration = Math.floor((ts + MAX_DURATION) / INTERVAL) * INTERVAL - ts;
        boosted_alice = amount.mul(MAX_BOOST).mul(duration).div(MAX_DURATION);
        expectApproxEqual(await totalSupply(), boosted_alice.div(MAX_DURATION).mul(duration - H), TOL);
        expectApproxEqual(await balanceOf(alice), boosted_alice.div(MAX_DURATION).mul(duration - H), TOL);
        expectZero(await balanceOf(bob));
        t0 = await getBlockTimestamp();

        for (let i = 0; i < MAX_NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            expectApproxEqual(
                await totalSupply(),
                boosted_alice.div(MAX_DURATION).mul(Math.max(duration - H - dt, 0)),
                TOL
            );
            expectApproxEqual(
                await balanceOf(alice),
                boosted_alice.div(MAX_DURATION).mul(Math.max(duration - H - dt, 0)),
                TOL
            );
            expectZero(await balanceOf(bob));
        }

        await sleep(H);

        expectZero(await balanceOf(alice));
        await ve.connect(alice).withdraw();

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));
    });

    it("should createLock() and increaseAmount()", async () => {
        const { token, ve, delegate, alice, bob, totalSupply, balanceOf } = await setupTest();

        const amount = constants.WeiPerEther;
        await token.connect(alice).transfer(bob.address, amount);

        await token.connect(alice).approve(ve.address, amount.mul(10000));
        await token.connect(bob).approve(ve.address, amount.mul(10000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));

        // Move to timing which is good for testing - beginning of a UTC week
        const ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await sleep(H);

        await delegate.connect(alice).createLock(amount, 2 * MIN_DURATION);
        const unlockTime = await ve.unlockTime(alice.address);

        await sleep(H);
        await mine();

        const boosted_alice = amount
            .mul(MAX_BOOST)
            .mul(2 * MIN_DURATION)
            .div(MAX_DURATION);
        expectApproxEqual(await totalSupply(), boosted_alice.div(MAX_DURATION).mul(2 * MIN_DURATION - H), TOL);
        expectApproxEqual(await balanceOf(alice), boosted_alice.div(MAX_DURATION).mul(2 * MIN_DURATION - H), TOL);
        expectZero(await balanceOf(bob));

        await sleep(H);
        await mine();

        const amounts = [boosted_alice];
        for (let i = 0; i < MIN_NUMBER_OF_DAYS - 1; i++) {
            await sleep(24 * H);
            await mine();

            const ts = await getBlockTimestamp();
            let boosted_total = constants.Zero;
            for (let j = 0; j < amounts.length; j++) {
                boosted_total = boosted_total.add(
                    amounts[j].div(MAX_DURATION).mul(Math.max(unlockTime.sub(ts).toNumber(), 0))
                );
            }
            expectApproxEqual(await totalSupply(), boosted_total, TOL);
            expectApproxEqual(await balanceOf(alice), boosted_total, TOL);
            expectZero(await balanceOf(bob));

            await delegate.connect(alice).increaseAmount(amount);
            amounts.push(amount.mul(MAX_BOOST).mul(unlockTime.sub(ts)).div(MAX_DURATION));
        }
    });
});
