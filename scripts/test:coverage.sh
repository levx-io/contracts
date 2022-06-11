#!/bin/sh

cp -r node_modules/@sushiswap/core/contracts/uniswapv2 contracts/uniswapv2
cross-env NODE_OPTIONS=\"--max-old-space-size=4096\" hardhat coverage --testfiles \"test/*.test.ts\"
rm -rf contracts/uniswapv2
