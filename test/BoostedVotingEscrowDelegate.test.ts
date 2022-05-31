import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { divf, expectApproxEqual, expectZero, getBlockTimestamp, mine, PRECISION_BASE, sleep } from "./utils";
import { BigNumber, constants, Signer, utils } from "ethers";
import { BoostedVotingEscrowDelegate, ERC20Mock, VotingEscrow } from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signers";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const H = 3600;
const DAY = 86400;
const NUMBER_OF_DAYS = 3;
const INTERVAL = NUMBER_OF_DAYS * DAY;
const MAXTIME = Math.floor((2 * 365 * DAY) / INTERVAL) * INTERVAL;
const MINTIME = 219 * DAY;
const TOL = PRECISION_BASE.mul(120).div(INTERVAL);

const BOOST_BASE = BigNumber.from(10).pow(12);
const MAX_BOOST = BOOST_BASE.mul(10);

const setupTest = async () => {
    const signers = await ethers.getSigners();
    const [alice, bob] = signers;

    const Token = await ethers.getContractFactory("ERC20Mock");
    const token = (await Token.deploy("Token", "TOKEN", constants.WeiPerEther.mul(2100000))) as ERC20Mock;

    const VE = await ethers.getContractFactory("VotingEscrow");
    const ve = (await VE.deploy(token.address, "veToken", "VE", INTERVAL, MAXTIME)) as VotingEscrow;

    const Delegate = await ethers.getContractFactory("BoostedVotingEscrowDelegate");
    const delegate = (await Delegate.deploy(
        token.address,
        ve.address,
        MINTIME,
        MAX_BOOST,
        constants.MaxUint256
    )) as BoostedVotingEscrowDelegate;
    await ve.setMiddleman(delegate.address, true);

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

describe.only("BoostedVotingEscrowDelegate", () => {
    beforeEach(async () => {
        await ethers.provider.send("hardhat_reset", []);
    });

    it("should properly increase and decrease voting power", async () => {
        const { token, ve, delegate, alice, bob, totalSupply, totalSupplyAt, balanceOf, balanceOfAt } =
            await setupTest();

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

        await expect(delegate.createLock(amount, MINTIME - 1)).to.be.revertedWith("BVED: DURATION_TOO_SHORT");
        await delegate.createLock(amount, MINTIME);

        await sleep(H);
        await mine();

        let amountBoosted = amount.mul(MAX_BOOST).mul(MINTIME).div(MAXTIME).div(BOOST_BASE);
        expectApproxEqual(await balanceOf(alice), amountBoosted.div(MAXTIME).mul(MINTIME - 2 * H), TOL);

        await sleep(MINTIME - 2 * H);

        await ve.connect(alice).withdraw();
        expectZero(await balanceOf(alice));

        await delegate.createLock(amount, MAXTIME);

        await sleep(H);
        await mine();

        amountBoosted = amount.mul(MAX_BOOST).div(BOOST_BASE);
        expectApproxEqual(await balanceOf(alice), amountBoosted.div(MAXTIME).mul(MAXTIME - H), TOL);
    });
});
