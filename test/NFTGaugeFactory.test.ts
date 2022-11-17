import { ethers } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { constants } from "ethers";
import { ERC20Mock, GaugeController, NFTGauge, NFTGaugeFactory, NFTMock, VotingEscrow } from "../typechain";

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR); // turn off warnings
chai.use(solidity);

const { AddressZero } = ethers.constants;
const INTERVAL = 7 * 24 * 3600;
const MAX_DURATION = 2 * 365 * 24 * 3600;

const setupTest = async () => {
    const signers = await ethers.getSigners();
    const [alice, bob] = signers;

    const NFT = await ethers.getContractFactory("NFTMock");
    const nft = (await NFT.deploy("NonFungible", "NFT")) as NFTMock;

    const Token = await ethers.getContractFactory("ERC20Mock");
    const token = (await Token.deploy("Token", "TOKEN", constants.WeiPerEther.mul(2100000))) as ERC20Mock;
    const weth = (await Token.deploy("Wrapped ETH", "WETH", 0)) as ERC20Mock;

    const Escrow = await ethers.getContractFactory("VotingEscrow");
    const votingEscrow = (await Escrow.deploy(
        token.address,
        "VotingEscrow",
        "VE",
        INTERVAL,
        MAX_DURATION,
        AddressZero
    )) as VotingEscrow;

    const Controller = await ethers.getContractFactory("GaugeController");
    const controller = (await Controller.deploy(INTERVAL, 0, votingEscrow.address)) as GaugeController;

    const MT = await ethers.getContractFactory("Minter");
    const minter = await MT.deploy(AddressZero, controller.address, 0, 0, 0, 0, AddressZero);

    const Factory = await ethers.getContractFactory("NFTGaugeFactory");
    const factory = (await Factory.deploy(
        weth.address,
        minter.address,
        AddressZero,
        AddressZero,
        AddressZero,
        0,
        0
    )) as NFTGaugeFactory;

    const Gauge = await ethers.getContractFactory("NFTGauge");
    const createNFTGauge = async nftAddress => {
        const tx = await factory.createNFTGauge(nftAddress);
        const receipt = await tx.wait();
        return Gauge.attach(receipt.events.find(e => e.event == "CreateNFTGauge").args.gauge) as NFTGauge;
    };

    return {
        alice,
        bob,
        nft,
        factory,
        createNFTGauge,
    };
};

describe.only("NFTGaugeFactory", () => {
    it("should createNFTGauge() multiple times", async () => {
        const { nft, createNFTGauge } = await setupTest();
        const gauge = await createNFTGauge(nft.address);
        expect(await gauge.isKilled()).to.be.equal(false);

        await createNFTGauge(nft.address);
        expect(await gauge.isKilled()).to.be.equal(true);
    });
});
