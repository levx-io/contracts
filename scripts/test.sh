#!/bin/sh

cp -r node_modules/@sushiswap/core/contracts/uniswapv2 contracts/uniswapv2
cross-env TS_NODE_TRANSPILE_ONLY=1 hardhat test
rm -rf contracts/uniswapv2
