// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IDividendVault {
    event Checkpoint(address indexed token, address indexed gauge, uint256 indexed tokenId, uint256 id, uint256 amount);
    event ClaimDividends(address indexed token, uint256 amountToken, uint256 amountReward, address indexed to);

    function weth() external view returns (address);

    function votingEscrow() external view returns (address);

    function rewardToken() external view returns (address);

    function swapRouter() external view returns (address);

    function balances(address token) external view returns (uint256);

    function dividends(
        address token,
        address gauge,
        uint256 id
    )
        external
        view
        returns (
            uint256 tokenId,
            uint64 timestamp,
            uint192 amountPerShare
        );

    function lastDividendClaimed(
        address token,
        address gauge,
        address user
    ) external view returns (uint256);

    function dividendsLength(address token, address gauge) external view returns (uint256);

    function claimableDividends(
        address token,
        address user,
        address[] memory gauges
    ) external view returns (uint256 amount);

    function claimableDividends(
        address token,
        address user,
        address[] memory gauges,
        uint256[] memory toIndices
    ) external view returns (uint256 amount);

    function checkpoint(
        address token,
        address gauge,
        uint256 tokenId
    ) external;

    function claimDividends(
        address token,
        address[] calldata gauges,
        uint256[] calldata toIndices,
        uint256 amountRewardMin,
        address[] calldata path,
        uint256 deadline
    ) external;
}
