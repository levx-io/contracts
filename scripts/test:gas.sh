#!/bin/sh

cp -r node_modules/@sushiswap/core/contracts/uniswapv2 contracts/uniswapv2
cross-env REPORT_GAS=true yarn test
rm -rf contracts/uniswapv2
