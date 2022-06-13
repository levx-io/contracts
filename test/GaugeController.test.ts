import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { divf, getBlockTimestamp, mine, randomArray, randomMatrix, sleep } from "./utils";
import { BigNumber, constants, utils } from "ethers";
import { ERC20Mock, GaugeController, VotingEscrow } from "../typechain";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const DAY = 86400;
const NUMBER_OF_DAYS = 3;
const INTERVAL = NUMBER_OF_DAYS * DAY;
const WEIGHT_VOTE_DELAY = 7 * DAY;
const MAXTIME = Math.floor((2 * 365 * DAY) / INTERVAL) * INTERVAL;

const randomAddress = () => utils.hexlify(utils.randomBytes(20));
const array = <T>(size, callback: (index) => T) => new Array(size).fill(0).map((_, index) => callback(index));
const sum = (array: BigNumber[]) => array.reduce((prev, current) => prev.add(current), constants.Zero);

const setupTest = async () => {
    const accounts = await ethers.getSigners();
    const three_gauges = [randomAddress(), randomAddress(), randomAddress()];

    const Token = await ethers.getContractFactory("ERC20Mock");
    const token = (await Token.deploy("Token", "TOKEN", constants.WeiPerEther.mul(2100000))) as ERC20Mock;

    const VE = await ethers.getContractFactory("VotingEscrow");
    const ve = (await VE.deploy(token.address, "veToken", "VE", INTERVAL, MAXTIME)) as VotingEscrow;

    const GC = await ethers.getContractFactory("GaugeController");
    const gc = (await GC.deploy(INTERVAL, WEIGHT_VOTE_DELAY, token.address, ve.address)) as GaugeController;

    // Set up gauges and types
    await gc["addType(string,uint256)"]("Liquidity", constants.WeiPerEther);
    for (const gauge of three_gauges) {
        await gc["addGauge(address,int128)"](gauge, 0);
    }

    // Distribute coins
    for (const account of accounts.slice(0, 3)) {
        await token.transfer(account.address, BigNumber.from(10).pow(24));
        await token.connect(account).approve(ve.address, BigNumber.from(10).pow(24));
    }

    const st_deposits = randomArray(BigNumber.from(10).pow(21), BigNumber.from(10).pow(23), 3);
    const st_length = randomArray(52, 100, 3);
    const st_votes = randomMatrix(0, 5, 2, 3);

    return {
        accounts,
        three_gauges,
        token,
        ve,
        gc,
        st_deposits,
        st_length,
        st_votes,
    };
};

/**
 * Test that gauge weights correctly adjust over time.
 *
 * Strategies
 * ---------
 * st_deposits : [int, int, int]
 * Number of coins to be deposited per account
 * st_length : [int, int, int]
 * Policy duration in weeks
 * st_votes : [(int, int), (int, int), (int, int)]
 * (vote for gauge 0, vote for gauge 1) for each account, in units of 10%
 **/
describe("GaugeController", () => {
    beforeEach(async () => {
        await ethers.provider.send("hardhat_reset", []);
    });

    it("should gauge weights correctly", async () => {
        const { accounts, three_gauges, ve, gc, st_deposits, st_length, st_votes } = await setupTest();

        // Init 10 s before the week change
        const t0 = await getBlockTimestamp();
        const t1 = divf(t0 + 2 * INTERVAL, INTERVAL) * INTERVAL - 10;
        await sleep(t1 - t0);

        // Deposit for voting
        const timestamp = t1;
        for (let i = 0; i < 3; i++) {
            await ve.connect(accounts[i]).createLock(st_deposits[i], st_length[i].mul(INTERVAL));
        }

        // Place votes
        const votes: BigNumber[][] = [];
        for (let i = 0; i < 3; i++) {
            votes.push(st_votes[i].map(x => x.mul(1000)));
            votes[votes.length - 1].push(
                BigNumber.from(10000).sub(
                    votes[votes.length - 1].reduce((prev, current) => prev.add(current), constants.Zero)
                )
            ); // XXX what if votes are not used up to 100%?
            // Now votes are [[vote_gauge_0, vote_gauge_1, vote_gauge_2], ...]
            for (let x = 0; x < 3; x++) {
                await gc.connect(accounts[i]).voteForGaugeWeights(three_gauges[x], votes[votes.length - 1][x]);
            }
        }

        // Vote power assertions - everyone used all voting power
        for (let i = 0; i < 3; i++) {
            expect(await gc.voteUserPower(accounts[i].address)).to.be.equal(10000);
        }

        // Calculate slope data, build model functions
        const slope_data: { bias: BigNumber; duration: number }[] = [];
        for (let i = 0; i < 3; i++) {
            const bias = (await ve.getLastUserSlope(accounts[i].address)).mul(
                (await ve.unlockTime(accounts[i].address)).sub(timestamp)
            );
            const duration = st_length[i]
                .mul(INTERVAL)
                .add(timestamp)
                .div(INTERVAL)
                .mul(INTERVAL)
                .sub(timestamp)
                .toNumber(); // <- endtime rounded to whole weeks
            slope_data.push({ bias, duration });
        }

        const max_duration = slope_data.reduce((prev, current) => Math.max(current.duration, prev), 0);

        const models = (i: number, relative_time: number) => {
            const { bias, duration } = slope_data[i];
            const value = bias
                .mul(utils.parseEther((1 - (relative_time * max_duration) / duration).toFixed(18)))
                .div(constants.WeiPerEther);
            if (value.lt(0)) return constants.Zero;
            return value;
        };

        await sleep(INTERVAL * 4);
        await mine();

        // advance clock a month at a time and compare theoretical weight to actual weights
        let ts_last = await getBlockTimestamp();
        while (ts_last < timestamp + 1.5 * max_duration) {
            for (let i = 0; i < 3; i++) {
                await gc.connect(accounts[4]).checkpointGauge(three_gauges[i]);
            }

            const relative_time = (divf(ts_last, INTERVAL) * INTERVAL - timestamp) / max_duration;
            const weights = await Promise.all(array(3, i => gc["gaugeRelativeWeight(address)"](three_gauges[i])));

            let theoretical_weights: BigNumber[];
            if (relative_time < 1) {
                theoretical_weights = [
                    sum(array(3, i => votes[i][0].mul(models(i, relative_time)).div(10000))),
                    sum(array(3, i => votes[i][1].mul(models(i, relative_time)).div(10000))),
                    sum(array(3, i => votes[i][2].mul(models(i, relative_time)).div(10000))),
                ];

                const s = sum(theoretical_weights);
                theoretical_weights = theoretical_weights.map(w => w.mul(constants.WeiPerEther).div(s));
            } else {
                theoretical_weights = [constants.Zero, constants.Zero, constants.Zero];
            }

            console.log(
                relative_time,
                weights.map(w => utils.formatEther(w)),
                theoretical_weights.map(w => utils.formatEther(w))
            );

            if (relative_time != 1) {
                // XXX 1 is odd: let's look at it separately
                for (let i = 0; i < 3; i++) {
                    expect(Number(utils.formatEther(weights[i].sub(theoretical_weights[i]).abs()))).to.lessThanOrEqual(
                        (ts_last - timestamp) / INTERVAL + 1
                    );
                }
            }

            await sleep(INTERVAL * 4);
            await mine();
            ts_last = await getBlockTimestamp();
        }
    });
});
