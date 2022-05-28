import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import {
    BlockInfo,
    divf,
    expectApproxEqual,
    expectZero,
    getBlockInfo,
    getBlockTimestamp,
    mine,
    PRECISION_BASE,
    sleep,
} from "./utils";
import { BigNumber, constants, Signer } from "ethers";
import { ERC20Mock, VotingEscrow } from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signers";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const H = 3600;
const DAY = 86400;
const NUMBER_OF_DAYS = 3;
const INTERVAL = NUMBER_OF_DAYS * DAY;
const MAXTIME = 2 * 365 * DAY;
const MULTIPLIER = constants.WeiPerEther;
const TOL = PRECISION_BASE.mul(120).div(INTERVAL);

const setupTest = async () => {
    const signers = await ethers.getSigners();
    const [alice, bob] = signers;

    const Token = await ethers.getContractFactory("ERC20Mock");
    const token = (await Token.deploy("Token", "TOKEN", constants.WeiPerEther.mul(2100000))) as ERC20Mock;

    const VE = await ethers.getContractFactory("VotingEscrow");
    const ve = (await VE.deploy(token.address, "veToken", "VE", INTERVAL, MAXTIME, MULTIPLIER)) as VotingEscrow;

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
        totalSupply,
        totalSupplyAt,
        balanceOf,
        balanceOfAt,
    };
};

/**
 *  Test voting power in the following scenario.
 *  Alice:
 *  ~~~~~~~
 *  ^
 *  | *       *
 *  | | \     |  \
 *  | |  \    |    \
 *  +-+---+---+------+---> t
 *
 *  Bob:
 *  ~~~~~~~
 *  ^
 *  |         *
 *  |         | \
 *  |         |  \
 *  +-+---+---+---+--+---> t
 *
 *  Alice has 100% of voting power in the first period.
 *  She has 2/3 power at the start of 2nd period, with Bob having 1/2 power
 *  (due to smaller locktime).
 *  Alice's power grows to 100% by Bob's unlock.
 *
 *  Checking that totalSupply is appropriate.
 *
 *  After the test is done, check all over again with balanceOfAt / totalSupplyAt
 **/
describe("VotingEscrow", () => {
    beforeEach(async () => {
        await ethers.provider.send("hardhat_reset", []);
    });

    it("should properly increase and decrease voting power", async () => {
        const { token, ve, alice, bob, totalSupply, totalSupplyAt, balanceOf, balanceOfAt } = await setupTest();

        const amount = constants.WeiPerEther.mul(1000);
        await token.connect(alice).transfer(bob.address, amount);
        const stages: Record<string, BlockInfo | BlockInfo[]> = {};

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

        stages["before_deposits"] = await getBlockInfo();

        await ve.connect(alice).createLock(amount, (await getBlockTimestamp()) + INTERVAL);
        stages["alice_deposit"] = await getBlockInfo();

        await sleep(H);
        await mine();

        expectApproxEqual(await totalSupply(), amount.div(MAXTIME).mul(INTERVAL - 2 * H), TOL);
        expectApproxEqual(await balanceOf(alice), amount.div(MAXTIME).mul(INTERVAL - 2 * H), TOL);
        expectZero(await balanceOf(bob));
        let t0 = await getBlockTimestamp();

        stages["alice_in_0"] = [await getBlockInfo()];
        for (let i = 0; i < NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            expectApproxEqual(await totalSupply(), amount.div(MAXTIME).mul(Math.max(INTERVAL - 2 * H - dt, 0)), TOL);
            expectApproxEqual(await balanceOf(alice), amount.div(MAXTIME).mul(Math.max(INTERVAL - 2 * H - dt, 0)), TOL);
            expectZero(await balanceOf(bob));
            stages["alice_in_0"].push(await getBlockInfo());
        }

        await sleep(H);

        expectZero(await balanceOf(alice));
        await ve.connect(alice).withdraw();
        stages["alice_withdraw"] = await getBlockInfo();

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));

        await sleep(H);
        await mine();

        // Next interval (for round counting)
        ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL) + 1) * INTERVAL - ts);
        await mine();

        await ve.connect(alice).createLock(amount, (await getBlockTimestamp()) + 2 * INTERVAL);
        stages["alice_deposit_2"] = await getBlockInfo();

        expectApproxEqual(await totalSupply(), amount.div(MAXTIME).mul(2).mul(INTERVAL), TOL);
        expectApproxEqual(await balanceOf(alice), amount.div(MAXTIME).mul(2).mul(INTERVAL), TOL);
        expectZero(await balanceOf(bob));

        await ve.connect(bob).createLock(amount, (await getBlockTimestamp()) + INTERVAL);
        stages["bob_deposit_2"] = await getBlockInfo();

        expectApproxEqual(await totalSupply(), amount.div(MAXTIME).mul(3).mul(INTERVAL), TOL);
        expectApproxEqual(await balanceOf(alice), amount.div(MAXTIME).mul(2).mul(INTERVAL), TOL);
        expectApproxEqual(await balanceOf(bob), amount.div(MAXTIME).mul(INTERVAL), TOL);

        t0 = await getBlockTimestamp();
        await sleep(H);
        await mine();

        stages["alice_bob_in_2"] = [];
        // Beginning of interval: weight 3
        // End of interval: weight 1
        for (let i = 0; i < NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            const w_total = await totalSupply();
            const w_alice = await balanceOf(alice);
            const w_bob = await balanceOf(bob);
            expect(w_total).to.be.equal(w_alice.add(w_bob));
            expectApproxEqual(w_alice, amount.div(MAXTIME).mul(Math.max(2 * INTERVAL - dt, 0)), TOL);
            expectApproxEqual(w_bob, amount.div(MAXTIME).mul(Math.max(INTERVAL - dt, 0)), TOL);
            stages["alice_bob_in_2"].push(await getBlockInfo());
        }

        await sleep(H);
        await mine();

        await ve.connect(bob).withdraw();
        t0 = await getBlockTimestamp();
        stages["bob_withdraw_1"] = await getBlockInfo();
        let w_total = await totalSupply();
        let w_alice = await balanceOf(alice);
        expect(w_total).to.be.equal(w_alice);
        expectApproxEqual(w_total, amount.div(MAXTIME).mul(INTERVAL - 2 * H), TOL);
        expectZero(await balanceOf(bob));

        await sleep(H);
        await mine();

        stages["alice_in_2"] = [];
        for (let i = 0; i < NUMBER_OF_DAYS; i++) {
            for (let j = 0; j < 24; j++) {
                await sleep(H);
                await mine();
            }
            const dt = (await getBlockTimestamp()) - t0;
            const w_total = await totalSupply();
            const w_alice = await balanceOf(alice);
            expect(w_total).to.be.equal(w_alice);
            expectApproxEqual(w_alice, amount.div(MAXTIME).mul(Math.max(INTERVAL - dt - 2 * H, 0)), TOL);
            expectZero(await balanceOf(bob));
            stages["alice_in_2"].push(await getBlockInfo());
        }

        await ve.connect(alice).withdraw();
        stages["alice_withdraw_2"] = await getBlockInfo();

        await sleep(H);
        await mine();

        await ve.connect(bob).withdraw();
        stages["bob_withdraw_2"] = await getBlockInfo();

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await balanceOf(bob));

        // Now test historical balanceOfAt and others

        expectZero(await balanceOfAt(alice, stages["before_deposits"].number));
        expectZero(await balanceOfAt(bob, stages["before_deposits"].number));
        expectZero(await totalSupplyAt(stages["before_deposits"].number));

        w_alice = await balanceOfAt(alice, stages["alice_deposit"].number);
        expectApproxEqual(w_alice, amount.div(MAXTIME).mul(INTERVAL - H), TOL);
        expectZero(await balanceOfAt(bob, stages["alice_deposit"].number));
        w_total = await totalSupplyAt(stages["alice_deposit"].number);
        expect(w_alice).to.be.equal(w_total);

        let i = 0;
        for (const block of stages["alice_in_0"]) {
            if (i >= NUMBER_OF_DAYS) break;
            w_alice = await balanceOfAt(alice, block.number);
            expectZero(await balanceOfAt(bob, block.number));
            w_total = await totalSupplyAt(block.number);
            expect(w_alice).to.be.equal(w_total);
            const time_left = divf(INTERVAL * (NUMBER_OF_DAYS - i), NUMBER_OF_DAYS) - 2 * H;
            const error_1h = PRECISION_BASE.mul(H).div(time_left);
            expectApproxEqual(w_alice, amount.div(MAXTIME).mul(time_left), error_1h);
            i++;
        }

        expectZero(await totalSupplyAt(stages["alice_withdraw"].number));
        expectZero(await balanceOfAt(alice, stages["alice_withdraw"].number));
        expectZero(await balanceOfAt(bob, stages["alice_withdraw"].number));

        w_total = await totalSupplyAt(stages["alice_deposit_2"].number);
        w_alice = await balanceOfAt(alice, stages["alice_deposit_2"].number);
        expectApproxEqual(w_total, amount.div(MAXTIME).mul(2).mul(INTERVAL), TOL);
        expect(w_total).to.be.equal(w_alice);
        expectZero(await balanceOfAt(bob, stages["alice_deposit_2"].number));

        w_total = await totalSupplyAt(stages["bob_deposit_2"].number);
        w_alice = await balanceOfAt(alice, stages["bob_deposit_2"].number);
        expect(w_total).to.be.equal(w_alice.add(await balanceOfAt(bob, stages["bob_deposit_2"].number)));
        expectApproxEqual(w_total, amount.div(MAXTIME).mul(3).mul(INTERVAL), TOL);
        expectApproxEqual(w_alice, amount.div(MAXTIME).mul(2).mul(INTERVAL), TOL);

        t0 = stages["bob_deposit_2"].timestamp;
        i = 0;
        for (const block of stages["alice_bob_in_2"]) {
            w_alice = await balanceOfAt(alice, block.number);
            const w_bob = await balanceOfAt(bob, block.number);
            w_total = await totalSupplyAt(block.number);
            expect(w_total).to.be.equal(w_alice.add(w_bob));
            const dt = block.timestamp - t0;
            const error_1h = PRECISION_BASE.mul(H).div(2 * INTERVAL - i * DAY); //  Rounding error of 1 block is possible, and we have 1h blocks
            expectApproxEqual(w_alice, amount.div(MAXTIME).mul(Math.max(2 * INTERVAL - dt, 0)), error_1h);
            expectApproxEqual(w_bob, amount.div(MAXTIME).mul(Math.max(INTERVAL - dt, 0)), error_1h);
            i++;
        }

        w_total = await totalSupplyAt(stages["bob_withdraw_1"].number);
        w_alice = await balanceOfAt(alice, stages["bob_withdraw_1"].number);
        expect(w_total).to.be.equal(w_alice);
        expectApproxEqual(w_total, amount.div(MAXTIME).mul(INTERVAL - 2 * H), TOL);
        expectZero(await balanceOfAt(bob, stages["bob_withdraw_1"].number));

        t0 = stages["bob_withdraw_1"].timestamp;
        i = 0;
        for (const block of stages["alice_in_2"]) {
            w_alice = await balanceOfAt(alice, block.number);
            w_total = await totalSupplyAt(block.number);
            expect(w_total).to.be.equal(w_alice);
            expectZero(await balanceOfAt(bob, block.number));
            const dt = block.timestamp - t0;
            const error_1h = PRECISION_BASE.mul(H).div(INTERVAL - i * DAY + DAY); //  Rounding error of 1 block is possible, and we have 1h blocks
            expectApproxEqual(w_total, amount.div(MAXTIME).mul(Math.max(INTERVAL - dt - 2 * H, 0)), error_1h);
            i++;
        }

        expectZero(await totalSupplyAt(stages["bob_withdraw_2"].number));
        expectZero(await balanceOfAt(alice, stages["bob_withdraw_2"].number));
        expectZero(await balanceOfAt(bob, stages["bob_withdraw_2"].number));
    });
});
