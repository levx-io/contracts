const TOKEN = "0xf474E526ADe9aD2CC2B66ffCE528B1A51B91FCdC";
const DAY = 86400;
const INTERVAL = 3 * DAY;
const MAXTIME = Math.floor((2 * 365 * DAY) / INTERVAL) * INTERVAL;

export default async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    await deploy("VotingEscrow", {
        from: deployer,
        args: [TOKEN, "Voting-escrowed LEVX", "THANO$", INTERVAL, MAXTIME],
        log: true,
    });
};
