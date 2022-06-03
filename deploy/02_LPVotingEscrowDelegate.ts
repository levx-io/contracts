import { BigNumber } from "ethers";

const LP_TOKEN = "0xdE0C1dC7f2b67705Cca50039418715F9C7F8D53B";
const DISCOUNT_TOKEN = "0xb8b07d0f2990ddd5b99b6db59dd8356ca2b1302d";
const MIN_AMOUNT = BigNumber.from(10).pow(15).mul(333);
const MAX_BOOST = BigNumber.from(10).pow(18).mul(1000);

export default async ({ getNamedAccounts, deployments }) => {
    const { deploy, get, execute } = deployments;
    const { deployer } = await getNamedAccounts();

    const ve = await get("VotingEscrow");

    const { address } = await deploy("LPVotingEscrowDelegate", {
        from: deployer,
        args: [LP_TOKEN, ve.address, DISCOUNT_TOKEN, true, MIN_AMOUNT, MAX_BOOST],
        log: true,
    });
    await execute("VotingEscrow", { from: deployer, log: true }, "setDelegate", address, true);
};
