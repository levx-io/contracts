// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IBase.sol";

interface IFeeVault is IBase {
    event Checkpoint(address indexed token, uint256 id, uint256 amount);
    event ClaimFees(address indexed token, uint256 amountToken, uint256 amountReward, address indexed to);

    function weth() external view returns (address);

    function votingEscrow() external view returns (address);

    function rewardToken() external view returns (address);

    function swapRouter() external view returns (address);

    function balances(address token) external view returns (uint256);

    function fees(address token, uint256 id) external view returns (uint64 timestamp, uint192 amountPerShare);

    function lastFeeClaimed(address token, address user) external view returns (uint256);

    function feesLength(address token) external view returns (uint256);

    function claimableFees(address token, address user) external view returns (uint256 amount);

    function claimableFees(
        address token,
        address user,
        uint256 toIndex
    ) external view returns (uint256 amount);

    function checkpoint(address token) external;

    function claimFees(
        address token,
        uint256 toIndex,
        uint256 amountRewardMin,
        address[] calldata path,
        uint256 deadline
    ) external;
}
