import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { divf, expectApproxEqual, expectZero, getBlockTimestamp, mine, PRECISION_BASE, sleep } from "./utils";
import { BigNumber, BigNumberish, constants, Signer, utils } from "ethers";
import {
    ERC20Mock,
    NFTMock,
    UniswapV2Factory,
    UniswapV2Pair,
    VotingEscrowMigratorMock,
    VotingEscrowLegacy,
    LPVotingEscrowDelegateLegacy,
} from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signers";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const LOG_OFF = false;

const H = 3600;
const DAY = 86400;
const NUMBER_OF_DAYS = 3;
const INTERVAL = NUMBER_OF_DAYS * DAY;
const MAX_NUMBER_OF_DAYS = 729;
const MAX_DURATION = MAX_NUMBER_OF_DAYS * DAY;
const TOL = PRECISION_BASE.mul(120).div(INTERVAL);

const ONE = constants.WeiPerEther;
const MIN_AMOUNT = BigNumber.from(10).pow(15).mul(333);
const MAX_BOOST = BigNumber.from(10).pow(18).mul(1000);
const MINIMUM_LIQUIDITY = 1000;
const PENALTY_BASE = ONE;

const setupTest = async () => {
    const signers = await ethers.getSigners();
    const [alice, bob] = signers;

    const ERC20 = await ethers.getContractFactory("ERC20Mock");
    const weth = (await ERC20.deploy("Wrapped Ethereum", "WETH", constants.WeiPerEther.mul(2100000))) as ERC20Mock;
    const token = (await ERC20.deploy("Token", "TOKEN", constants.WeiPerEther.mul(2100000))) as ERC20Mock;

    const Factory = await ethers.getContractFactory("UniswapV2Factory");
    const factory = (await Factory.deploy(constants.AddressZero)) as UniswapV2Factory;
    await factory.createPair(weth.address, token.address);

    const Pair = await ethers.getContractFactory("UniswapV2Pair");
    const pair = Pair.attach(await factory.getPair(weth.address, token.address)) as UniswapV2Pair;
    const isToken1 = (await pair.token1()) == token.address;

    const VE = await ethers.getContractFactory("VotingEscrowLegacy");
    const ve = (await VE.deploy(token.address, "veToken", "VE", INTERVAL, MAX_DURATION)) as VotingEscrowLegacy;

    const Migrator = await ethers.getContractFactory("VotingEscrowMigratorMock");
    const migrator = (await Migrator.deploy(ve.address)) as VotingEscrowMigratorMock;

    const DiscountToken = await ethers.getContractFactory("NFTMock");
    const discountToken = (await DiscountToken.deploy("Discount", "DISC")) as NFTMock;

    const Delegate = await ethers.getContractFactory("LPVotingEscrowDelegateLegacy");
    const delegate = (await Delegate.deploy(
        ve.address,
        pair.address,
        discountToken.address,
        isToken1,
        MIN_AMOUNT,
        MAX_BOOST
    )) as LPVotingEscrowDelegateLegacy;
    await ve.setDelegate(delegate.address, true);

    const totalSupply = async (): Promise<BigNumber> => await ve["totalSupply()"]();
    const totalSupplyAt = async (block: number): Promise<BigNumber> => await ve.totalSupplyAt(block);
    const balanceOf = async (account: SignerWithAddress): Promise<BigNumber> =>
        await ve["balanceOf(address)"](account.address);
    const balanceOfAt = async (account: Signer, block: number): Promise<BigNumber> =>
        await ve.balanceOfAt(await account.getAddress(), block);

    const mintLPToken = async (account: Signer, amount: BigNumberish) => {
        const supply = await pair.totalSupply();
        await weth.connect(account).transfer(pair.address, amount);
        await token.connect(account).transfer(pair.address, amount);
        await pair.connect(account).mint(await account.getAddress());
        return (await pair.totalSupply()).sub(supply);
    };
    const burnLPToken = async (account: Signer, amount: BigNumberish) => {
        await pair.connect(account).transfer(pair.address, amount);
        await pair.connect(account).burn(await account.getAddress());
    };
    const getTokensInLP = async (amountLP: BigNumberish) => {
        const [reserve0, reserve1] = await pair.getReserves();
        const reserve = isToken1 ? reserve1 : reserve0;
        return BigNumber.from(amountLP)
            .mul(reserve)
            .div(await pair.totalSupply());
    };

    return {
        alice,
        bob,
        weth,
        token,
        pair,
        ve,
        migrator,
        delegate,
        totalSupply,
        totalSupplyAt,
        balanceOf,
        balanceOfAt,
        mintLPToken,
        burnLPToken,
        getTokensInLP,
    };
};

describe("LPVotingEscrowDelegateLegacy", () => {
    beforeEach(async () => {
        await ethers.provider.send("hardhat_reset", []);
    });

    it("should createLock() and withdraw() with increasing LP", async () => {
        const { ve, pair, delegate, alice, totalSupply, balanceOf, mintLPToken, getTokensInLP } = await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        let balanceLP_alice = constants.Zero;
        for (let i = 0; i < 100; i++) {
            await mintLPToken(alice, ONE);
            const lpTotal = await pair.totalSupply();
            const circulatingLP = lpTotal;
            const amountLP = ONE.sub(i === 0 ? MINIMUM_LIQUIDITY : 0);
            balanceLP_alice = balanceLP_alice.add(amountLP);
            expect(lpTotal).to.be.equal(ONE.mul(i + 1));
            expect(await pair.balanceOf(alice.address)).to.be.equal(balanceLP_alice);

            // Move to timing which is good for testing - beginning of a UTC week
            const ts = await getBlockTimestamp();
            await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
            await mine();

            await delegate.connect(alice).createLock(amountLP, MAX_DURATION);

            await sleep(H);
            await mine();

            expect(await pair.balanceOf(alice.address)).to.be.equal(balanceLP_alice.sub(amountLP));
            expect(await delegate.locked(alice.address)).to.be.equal(amountLP);
            expect(await delegate.lockedTotal()).to.be.equal(amountLP);

            const amountToken_alice = await getTokensInLP(amountLP);
            let amountVE_alice = amountToken_alice.add(
                amountToken_alice.mul(MAX_BOOST).mul(circulatingLP).div(lpTotal.pow(2))
            );
            if (amountVE_alice.gt(amountToken_alice.mul(333).div(10))) {
                amountVE_alice = amountToken_alice.mul(333).div(10);
            }
            log(i, lpTotal, amountLP, MAX_BOOST.mul(100).mul(circulatingLP).div(lpTotal.pow(2)).toNumber() / 100);
            expectApproxEqual(await totalSupply(), amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - 2 * H), TOL);
            expectApproxEqual(await balanceOf(alice), amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - H), TOL);

            await sleep(MAX_DURATION);
            await mine();

            expectZero(await balanceOf(alice));
            await ve.connect(alice).withdraw();

            expectZero(await totalSupply());
            expectZero(await balanceOf(alice));
        }
    });

    it("should createLock() and increaseAmount() with increasing amount out of fixed LP", async () => {
        const { pair, delegate, alice, totalSupply, balanceOf, mintLPToken, getTokensInLP } = await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        const lpTotal = ONE.mul(100);
        await mintLPToken(alice, lpTotal);
        expect(await pair.totalSupply()).to.be.equal(lpTotal);
        expect(await pair.balanceOf(alice.address)).to.be.equal(lpTotal.sub(MINIMUM_LIQUIDITY));

        // Move to timing which is good for testing - beginning of a UTC week
        const ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        let lpLockedTotal = constants.Zero;
        let amountVE_alice = constants.Zero;
        for (let i = 0; i < 100; i++) {
            const amountLP = ONE.sub(i === 0 ? MINIMUM_LIQUIDITY : 0);
            const circulatingLP = lpTotal.sub(lpLockedTotal);

            if (i === 0) {
                await delegate.connect(alice).createLock(amountLP, MAX_DURATION);
            } else {
                await delegate.connect(alice).increaseAmount(amountLP);
            }
            lpLockedTotal = lpLockedTotal.add(amountLP);

            await sleep(H);
            await mine();

            expect(await pair.balanceOf(alice.address)).to.be.equal(lpTotal.sub(lpLockedTotal).sub(MINIMUM_LIQUIDITY));
            expect(await delegate.locked(alice.address)).to.be.equal(lpLockedTotal);
            expect(await delegate.lockedTotal()).to.be.equal(lpLockedTotal);

            const amountToken_alice = await getTokensInLP(amountLP);
            let amount = amountToken_alice.add(
                amountToken_alice.mul(MAX_BOOST).mul(circulatingLP).div(lpTotal).div(lpTotal)
            );
            if (amount.gt(amountToken_alice.mul(333).div(10))) {
                amount = amountToken_alice.mul(333).div(10);
            }
            amountVE_alice = amountVE_alice.add(amount);
            log(
                i,
                lpTotal,
                lpLockedTotal,
                MAX_BOOST.mul(100).mul(circulatingLP).div(lpTotal).div(lpTotal).toNumber() / 100
            );
            expectApproxEqual(
                await totalSupply(),
                amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - H - i * DAY),
                TOL
            );
            expectApproxEqual(
                await balanceOf(alice),
                amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - H - i * DAY),
                TOL
            );

            await sleep(DAY - H);
            await mine();
        }
    });

    it("should createLock() and withdraw() with decreasing LP", async () => {
        const { ve, pair, delegate, alice, totalSupply, balanceOf, mintLPToken, burnLPToken, getTokensInLP } =
            await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        await mintLPToken(alice, ONE.mul(100));
        expect(await pair.totalSupply()).to.be.equal(ONE.mul(100));
        expect(await pair.balanceOf(alice.address)).to.be.equal(ONE.mul(100).sub(MINIMUM_LIQUIDITY));

        for (let i = 0; i < 100; i++) {
            const lpTotal = await pair.totalSupply();
            const circulatingLP = lpTotal;
            const amountLP = ONE.sub(i === 99 ? MINIMUM_LIQUIDITY : 0);
            const balanceLP_alice = circulatingLP.sub(MINIMUM_LIQUIDITY);
            expect(lpTotal).to.be.equal(ONE.mul(100).sub(ONE.mul(i)));
            expect(await pair.balanceOf(alice.address)).to.be.equal(balanceLP_alice);

            // Move to timing which is good for testing - beginning of a UTC week
            const ts = await getBlockTimestamp();
            await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
            await mine();

            await delegate.connect(alice).createLock(amountLP, MAX_DURATION);

            await sleep(H);
            await mine();

            expect(await pair.balanceOf(alice.address)).to.be.equal(balanceLP_alice.sub(amountLP));
            expect(await delegate.locked(alice.address)).to.be.equal(amountLP);
            expect(await delegate.lockedTotal()).to.be.equal(amountLP);

            const amountToken_alice = await getTokensInLP(amountLP);
            let amountVE_alice = amountToken_alice.add(
                amountToken_alice.mul(MAX_BOOST).mul(circulatingLP).div(lpTotal.pow(2))
            );
            if (amountVE_alice.gt(amountToken_alice.mul(333).div(10))) {
                amountVE_alice = amountToken_alice.mul(333).div(10);
            }
            log(i, lpTotal, amountLP, MAX_BOOST.mul(100).mul(circulatingLP).div(lpTotal).div(lpTotal).toNumber() / 100);
            expectApproxEqual(await totalSupply(), amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - 2 * H), TOL);
            expectApproxEqual(await balanceOf(alice), amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - H), TOL);

            await sleep(MAX_DURATION);
            await mine();

            expectZero(await balanceOf(alice));
            await ve.connect(alice).withdraw();

            expectZero(await totalSupply());
            expectZero(await balanceOf(alice));

            await burnLPToken(alice, amountLP);
        }
    });

    it("should createLock() and increaseAmount() with increasing LP", async () => {
        const { pair, delegate, alice, totalSupply, balanceOf, mintLPToken, getTokensInLP } = await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        // Move to timing which is good for testing - beginning of a UTC week
        const ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        let lpLockedTotal = constants.Zero;
        let amountVE_alice = constants.Zero;
        for (let i = 0; i < 100; i++) {
            await mintLPToken(alice, ONE);
            const lpTotal = await pair.totalSupply();
            const circulatingLP = lpTotal.sub(lpLockedTotal);
            const amountLP = ONE.sub(i === 0 ? MINIMUM_LIQUIDITY : 0);
            expect(lpTotal).to.be.equal(ONE.mul(i + 1));
            expect(await pair.balanceOf(alice.address)).to.be.equal(amountLP);

            await sleep(H);
            await mine();

            if (i === 0) {
                await delegate.connect(alice).createLock(amountLP, MAX_DURATION);
            } else {
                await delegate.connect(alice).increaseAmount(amountLP);
            }
            lpLockedTotal = lpLockedTotal.add(amountLP);

            await sleep(H);
            await mine();

            expectZero(await pair.balanceOf(alice.address));
            expect(await delegate.locked(alice.address)).to.be.equal(lpLockedTotal);
            expect(await delegate.lockedTotal()).to.be.equal(lpLockedTotal);

            const amountToken_alice = await getTokensInLP(amountLP);
            let amount = amountToken_alice.add(
                amountToken_alice.mul(MAX_BOOST).mul(circulatingLP).div(lpTotal).div(lpTotal)
            );
            if (amount.gt(amountToken_alice.mul(333).div(10))) {
                amount = amountToken_alice.mul(333).div(10);
            }
            amountVE_alice = amountVE_alice.add(amount);
            log(
                i,
                lpTotal,
                lpLockedTotal,
                MAX_BOOST.mul(100).mul(circulatingLP).div(lpTotal).div(lpTotal).toNumber() / 100
            );
            expectApproxEqual(
                await totalSupply(),
                amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - 2 * H - i * DAY),
                TOL
            );
            expectApproxEqual(
                await balanceOf(alice),
                amountVE_alice.div(MAX_DURATION).mul(MAX_DURATION - 2 * H - i * DAY),
                TOL
            );

            await sleep(DAY - 2 * H);
            await mine();
        }
    });

    it("should cancel()", async () => {
        const { ve, pair, delegate, migrator, alice, totalSupply, balanceOf, mintLPToken } = await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        await mintLPToken(alice, ONE.mul(1000));
        const amountLP = ONE;

        // Move to timing which is good for testing - beginning of a UTC week
        let ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        const unlockTime = Math.floor(((await getBlockTimestamp()) + INTERVAL) / INTERVAL) * INTERVAL;
        await delegate.connect(alice).createLock(amountLP, INTERVAL);

        let balance = await pair.balanceOf(alice.address);
        await sleep(DAY);

        const duration = unlockTime - (await getBlockTimestamp());
        await ve.connect(alice).cancel();

        let penaltyRate = PENALTY_BASE.mul(unlockTime - (await getBlockTimestamp())).div(duration);
        if (penaltyRate.lt(PENALTY_BASE.div(2))) penaltyRate = PENALTY_BASE.div(2);
        expect((await pair.balanceOf(alice.address)).sub(balance)).to.be.equal(
            amountLP.mul(PENALTY_BASE.sub(penaltyRate)).div(PENALTY_BASE)
        );
        expectZero(await ve.unlockTime(alice.address));

        // Move to timing which is good for testing - beginning of a UTC week
        ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await delegate.connect(alice).createLock(amountLP, INTERVAL);

        await sleep(DAY);
        await delegate.connect(alice).increaseAmount(amountLP);

        balance = await pair.balanceOf(alice.address);
        await sleep(DAY);

        await ve.connect(alice).cancel();

        expect((await pair.balanceOf(alice.address)).sub(balance)).to.be.equal(amountLP); // Half of the total amount
        expectZero(await ve.unlockTime(alice.address));

        await ve.setMigrator(migrator.address);
        await expect(ve.connect(alice).migrate()).to.be.revertedWith("VE: LOCK_NOT_FOUND");

        // Move to timing which is good for testing - beginning of a UTC week
        ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await delegate.connect(alice).createLock(amountLP, INTERVAL);

        await sleep(INTERVAL);
        await expect(ve.connect(alice).cancel()).to.be.revertedWith("VE: LOCK_EXPIRED");
        await ve.connect(alice).withdraw();
    });

    it("should withdraw()", async () => {
        const { ve, pair, migrator, delegate, alice, totalSupply, balanceOf, mintLPToken } = await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        await mintLPToken(alice, ONE);
        const lpTotal = await pair.totalSupply();
        const amountLP = ONE.sub(MINIMUM_LIQUIDITY);
        expect(lpTotal).to.be.equal(ONE);
        expect(await pair.balanceOf(alice.address)).to.be.equal(amountLP);

        // Move to timing which is good for testing - beginning of a UTC week
        const ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await delegate.connect(alice).createLock(amountLP, INTERVAL);

        await sleep(INTERVAL);
        await ve.connect(alice).withdraw();

        await expect(ve.connect(alice).cancel()).to.be.revertedWith("VE: LOCK_NOT_FOUND");

        await ve.setMigrator(migrator.address);
        await expect(ve.connect(alice).migrate()).to.be.revertedWith("VE: LOCK_NOT_FOUND");
    });

    it("should migrate()", async () => {
        const { ve, pair, migrator, delegate, alice, totalSupply, balanceOf, mintLPToken } = await setupTest();

        await pair.connect(alice).approve(delegate.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));

        await mintLPToken(alice, ONE);
        const lpTotal = await pair.totalSupply();
        const amountLP = ONE.sub(MINIMUM_LIQUIDITY);
        expect(lpTotal).to.be.equal(ONE);
        expect(await pair.balanceOf(alice.address)).to.be.equal(amountLP);

        // Move to timing which is good for testing - beginning of a UTC week
        const ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await delegate.connect(alice).createLock(amountLP, INTERVAL);

        await ve.setMigrator(migrator.address);
        await ve.connect(alice).migrate();

        expectZero(await ve.unlockTime(alice.address));
        await expect(ve.connect(alice).cancel()).to.be.revertedWith("VE: LOCK_NOT_FOUND");

        await sleep(INTERVAL);
        await ve.connect(alice).withdraw();

        await expect(delegate.connect(alice).createLock(amountLP, INTERVAL)).to.be.revertedWith("VE: LOCK_MIGRATED");
    });
});

const log = (i, lpTotal, lpLocked, boost) => {
    if (!LOG_OFF) {
        console.log(
            i +
                "\t" +
                Number(utils.formatEther(lpLocked)).toFixed(18) +
                "\t" +
                Number(utils.formatEther(lpTotal)).toFixed(18) +
                "\t" +
                boost.toFixed(2).toString().padStart(7, " ") +
                "x"
        );
    }
};
