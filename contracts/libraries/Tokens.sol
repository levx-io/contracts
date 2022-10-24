// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IWETH.sol";

library Tokens {
    using SafeERC20 for IERC20;

    function balanceOf(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    function safeTransfer(
        address token,
        address to,
        uint256 amount,
        address weth
    ) internal {
        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount, gas: 30000}("");
            if (!success) {
                IWETH(weth).deposit{value: amount}();
                IERC20(weth).safeTransfer(to, amount);
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
