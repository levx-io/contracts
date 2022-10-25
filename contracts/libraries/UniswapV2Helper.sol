// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IUniswapV2Router02.sol";

library UniswapV2Helper {
    function swap(
        address swapRouter,
        address token,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        uint256 deadline
    ) internal returns (uint256[] memory amountsOut) {
        if (token == address(0)) {
            amountsOut = IUniswapV2Router02(swapRouter).swapExactETHForTokens{value: amountIn}(
                amountOutMin,
                path,
                msg.sender,
                deadline
            );
        } else {
            IERC20(token).approve(swapRouter, amountIn);
            amountsOut = IUniswapV2Router02(swapRouter).swapExactTokensForTokens(
                amountIn,
                amountOutMin,
                path,
                msg.sender,
                deadline
            );
        }
    }
}
