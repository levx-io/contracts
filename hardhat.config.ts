import "dotenv/config";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-solhint";
import "@nomiclabs/hardhat-waffle";
import "hardhat-abi-exporter";
import "hardhat-deploy";
import "hardhat-gas-reporter";
import "hardhat-spdx-license-identifier";
import "hardhat-watcher";
import "solidity-coverage";
import "@typechain/hardhat";
import "@tenderly/hardhat-tenderly";

import { HardhatUserConfig, task } from "hardhat/config";

import { removeConsoleLog } from "hardhat-preprocessor";

const accounts = [process.env.PRIVATE_KEY || "0000000000000000000000000000000000000000000000000000000000000000"];

// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task("accounts", "Prints the list of accounts", async (args, { ethers }) => {
    const accounts = await ethers.getSigners();

    for (const account of accounts) {
        console.log(await account.address);
    }
});

const config: HardhatUserConfig = {
    abiExporter: {
        path: "./abis",
        runOnCompile: process.env.EXPORT_ABI === "true",
        clear: true,
        flat: true,
        spacing: 2,
    },
    defaultNetwork: "hardhat",
    etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY,
    },
    gasReporter: {
        coinmarketcap: process.env.COINMARKETCAP_API_KEY,
        currency: "USD",
        enabled: process.env.REPORT_GAS === "true",
    },
    namedAccounts: {
        deployer: {
            default: 0,
        },
        alice: {
            default: 1,
        },
        bob: {
            default: 2,
        },
        carol: {
            default: 3,
        },
    },
    networks: {
        localhost: {
            live: false,
            saveDeployments: true,
            tags: ["local"],
        },
        hardhat: {
            // Seems to be a bug with this, even when false it complains about being unauthenticated.
            // Reported to HardHat team and fix is incoming
            forking: {
                enabled: process.env.FORKING === "true",
                url: `https://eth-mainnet.alchemyapi.io/v2/${process.env.ALCHEMY_API_KEY}`,
            },
            live: false,
            saveDeployments: true,
            tags: ["test", "local"],
        },
        mainnet: {
            url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 1,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        ropsten: {
            url: `https://ropsten.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 3,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        goerli: {
            url: `https://goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 5,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        kovan: {
            url: `https://kovan.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 42,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        moonbase: {
            url: "https://rpc.testnet.moonbeam.network",
            accounts,
            chainId: 1287,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        arbitrum: {
            url: "https://kovan3.arbitrum.io/rpc",
            accounts,
            chainId: 79377087078960,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        fantom: {
            url: "https://rpcapi.fantom.network",
            accounts,
            chainId: 250,
            live: true,
            saveDeployments: true,
        },
        fantom_testnet: {
            url: "https://rpc.testnet.fantom.network",
            accounts,
            chainId: 4002,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        matic: {
            url: "https://rpc-mainnet.maticvigil.com",
            accounts,
            chainId: 137,
            live: true,
            saveDeployments: true,
        },
        xdai: {
            url: "https://rpc.xdaichain.com",
            accounts,
            chainId: 100,
            live: true,
            saveDeployments: true,
        },
        bsc: {
            url: "https://bsc-dataseed.binance.org",
            accounts,
            chainId: 56,
            live: true,
            saveDeployments: true,
        },
        bsc_testnet: {
            url: "https://data-seed-prebsc-2-s3.binance.org:8545",
            accounts,
            chainId: 97,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
    },
    preprocess: {
        eachLine: removeConsoleLog(bre => bre.network.name !== "hardhat" && bre.network.name !== "localhost"),
    },
    solidity: {
        compilers: [
            {
                version: "0.8.15",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                    viaIR: true,
                },
            },
        ],
    },
    tenderly: {
        project: process.env.TENDERLY_PROJECT,
        username: process.env.TENDERLY_USERNAME,
    },
    watcher: {
        compile: {
            tasks: ["compile"],
            files: ["./contracts"],
            verbose: true,
        },
    },
    mocha: {
        timeout: 600000,
    },
};

// You need to export an object to set up your config
// Go to https://hardhat.org/config/ to learn more
export default config;
