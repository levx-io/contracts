const TOKEN = "0xf474E526ADe9aD2CC2B66ffCE528B1A51B91FCdC";
const DAY = 86400;
const MIN_DURATION = 219 * DAY;
const DISCOUNT_TOKEN = "0xb8b07d0f2990ddd5b99b6db59dd8356ca2b1302d";
const MAX_BOOST = 10;

export default async ({ getNamedAccounts, deployments }) => {
    const { deploy, get, execute } = deployments;
    const { deployer } = await getNamedAccounts();

    const ve = await get("VotingEscrow");

    const { address } = await deploy("BoostedVotingEscrowDelegate", {
        from: deployer,
        args: [ve.address, TOKEN, DISCOUNT_TOKEN, MIN_DURATION, MAX_BOOST, 1655510400],
        log: true,
    });
    await execute("VotingEscrow", { from: deployer, log: true }, "setDelegate", address, true);
};
