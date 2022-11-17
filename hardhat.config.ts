import "dotenv/config";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-solhint";
import "@nomiclabs/hardhat-waffle";
import "hardhat-abi-exporter";
import "hardhat-deploy";
import "hardhat-gas-reporter";
import "hardhat-spdx-license-identifier";
import "hardhat-tracer";
import "hardhat-watcher";
import "solidity-coverage";
import "@primitivefi/hardhat-dodoc";
import "@typechain/hardhat";

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
    dodoc: {
        exclude: ["hardhat/", "@openzeppelin/", "contracts/mocks"],
    },
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
        goerli: {
            url: `https://goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 5,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        bsc: {
            url: `https://bsc-dataseed1.binance.org`,
            accounts,
            chainId: 56,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        "bsc-testnet": {
            url: `https://data-seed-prebsc-2-s1.binance.org:8545`,
            accounts,
            chainId: 97,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        polygon: {
            url: `https://polygon-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 137,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        mumbai: {
            url: `https://polygon-mumbai.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 80001,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        avalanche: {
            url: `https://avalanche-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 43114,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        fuji: {
            url: `https://avalanche-fuji.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 43113,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        optimism: {
            url: `https://optimism-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 10,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        "optimism-goerli": {
            url: `https://optimism-goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 420,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        arbitrum: {
            url: `https://arbitrum-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 42161,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        "arbitrum-goerli": {
            url: `https://arbitrum-goerli.infura.io/v3/${process.env.INFURA_API_KEY}`,
            accounts,
            chainId: 421613,
            live: true,
            saveDeployments: true,
            tags: ["staging"],
        },
        fantom: {
            url: `https://rpc.testnet.fantom.network/`,
            accounts,
            chainId: 250,
            live: true,
            saveDeployments: true,
            tags: ["production"],
        },
        "fantom-testnet": {
            url: `https://rpc.testnet.fantom.network/`,
            accounts,
            chainId: 4002,
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
                version: "0.6.12",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                },
            },
            {
                version: "0.8.17",
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
