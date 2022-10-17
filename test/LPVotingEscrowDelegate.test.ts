import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { divf, expectApproxEqual, expectZero, getBlockTimestamp, mine, sleep } from "./utils";
import { BigNumber, BigNumberish, constants, Signer } from "ethers";
import {
    ERC20Mock,
    LPVotingEscrowDelegate,
    NFTMock,
    UniswapV2Factory,
    UniswapV2Pair,
    VotingEscrow,
    VotingEscrowLegacy,
} from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signers";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const DAY = 86400;
const NUMBER_OF_DAYS = 7;
const INTERVAL_LEGACY = 3 * DAY;
const INTERVAL = NUMBER_OF_DAYS * DAY;
const MAX_DURATION_LEGACY = 729 * DAY;
const MAX_DURATION = 4 * 365 * DAY;

const ONE = constants.WeiPerEther;
const MIN_AMOUNT = BigNumber.from(10).pow(15).mul(333);
const MAX_BOOST = BigNumber.from(10).pow(18).mul(1000);
const MINIMUM_LIQUIDITY = 1000;

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

    const VELegacy = await ethers.getContractFactory("VotingEscrowLegacy");
    const veLegacy = (await VELegacy.deploy(
        token.address,
        "veToken",
        "VE",
        INTERVAL_LEGACY,
        MAX_DURATION_LEGACY
    )) as VotingEscrowLegacy;

    const VE = await ethers.getContractFactory("VotingEscrow");
    const ve = (await VE.deploy(
        token.address,
        "veToken",
        "VE",
        INTERVAL,
        MAX_DURATION,
        veLegacy.address
    )) as VotingEscrow;
    await veLegacy.setMigrator(ve.address);

    const DiscountToken = await ethers.getContractFactory("NFTMock");
    const discountToken = (await DiscountToken.deploy("Discount", "DISC")) as NFTMock;

    const DelegateLegacy = await ethers.getContractFactory("LPVotingEscrowDelegateLegacy");
    const delegateLegacy = (await DelegateLegacy.deploy(
        veLegacy.address,
        pair.address,
        discountToken.address,
        isToken1,
        MIN_AMOUNT,
        MAX_BOOST
    )) as LPVotingEscrowDelegate;
    await veLegacy.setDelegate(delegateLegacy.address, true);

    const Delegate = await ethers.getContractFactory("LPVotingEscrowDelegate");
    const delegate = (await Delegate.deploy(
        ve.address,
        pair.address,
        discountToken.address,
        isToken1,
        MIN_AMOUNT,
        MAX_BOOST,
        delegateLegacy.address
    )) as LPVotingEscrowDelegate;
    await ve.setDelegate(delegate.address, true);
    await ve.setDelegateOfLegacy(delegateLegacy.address, delegate.address);

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
        veLegacy,
        ve,
        delegateLegacy,
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

describe.only("LPVotingEscrowDelegate", () => {
    beforeEach(async () => {
        await ethers.provider.send("hardhat_reset", []);
    });

    it("should migrate()", async () => {
        const { veLegacy, ve, pair, delegateLegacy, delegate, alice, totalSupply, balanceOf, mintLPToken } =
            await setupTest();

        await pair.connect(alice).approve(delegateLegacy.address, ONE.mul(1000));

        expectZero(await totalSupply());
        expectZero(await balanceOf(alice));
        expectZero(await pair.balanceOf(delegateLegacy.address));

        await mintLPToken(alice, ONE);
        const lpTotal = await pair.totalSupply();
        const amountLP = ONE.sub(MINIMUM_LIQUIDITY);
        expect(lpTotal).to.be.equal(ONE);
        expect(await pair.balanceOf(alice.address)).to.be.equal(amountLP);
        expectZero(await pair.balanceOf(delegateLegacy.address));

        // Move to timing which is good for testing - beginning of a UTC week
        const ts = await getBlockTimestamp();
        await sleep((divf(ts, INTERVAL_LEGACY) + 1) * INTERVAL_LEGACY - ts);
        await mine();

        await delegateLegacy.connect(alice).createLock(amountLP, INTERVAL_LEGACY * 3);
        expectZero(await pair.balanceOf(alice.address));
        expect(await pair.balanceOf(delegateLegacy.address)).to.be.equal(amountLP);

        const balanceVE = await veLegacy["balanceOf(address)"](alice.address);
        const {
            amount: amountLegacy,
            discount: discountLegacy,
            start: startLegacy,
            end: endLegacy,
        } = await veLegacy.locked(alice.address);

        await expect(delegate.connect(alice).migrate(alice.address, 0, 0, 0, 0, [])).to.be.revertedWith(
            "LPVED: FORBIDDEN"
        );
        await expect(veLegacy.connect(alice).migrate()).to.be.revertedWith("LPVED: PRE_MIGRATE_FIRST");
        await delegate.connect(alice).preMigrate();

        await expect(veLegacy.connect(alice).migrate()).to.be.revertedWith("ds-math-sub-underflow");
        await pair.connect(alice).approve(delegate.address, amountLP);
        await veLegacy.connect(alice).migrate();

        expectZero(await veLegacy.unlockTime(alice.address));
        expectZero(await veLegacy["balanceOf(address)"](alice.address));
        expectZero(await pair.balanceOf(delegateLegacy.address));

        const { amount, discount, start, end } = await ve.locked(alice.address);
        expect(amount).to.be.equal(amountLegacy);
        expect(discount).to.be.equal(discountLegacy);

        const newStart = startLegacy.add(INTERVAL).div(INTERVAL).mul(INTERVAL);
        let newEnd = endLegacy.div(INTERVAL).mul(INTERVAL);
        if (newStart.gte(newEnd)) newEnd = newEnd.add(INTERVAL);
        expect(start).to.be.equal(newStart);
        expect(end).to.be.equal(newEnd);
        expectApproxEqual((await ve["balanceOf(address)"](alice.address)).mul(2), balanceVE, ONE);
        expect(await pair.balanceOf(delegate.address)).to.be.equal(amountLP);

        await sleep(INTERVAL_LEGACY * 3);
        expectZero(await pair.balanceOf(alice.address));

        await veLegacy.connect(alice).withdraw();
        expectZero(await pair.balanceOf(alice.address));

        await ve.connect(alice).withdraw();
        expect(await pair.balanceOf(alice.address)).to.be.equal(amountLP);
    });
});
