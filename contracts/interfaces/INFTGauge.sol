// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IWrappedERC721.sol";

interface INFTGauge is IWrappedERC721 {
    event Wrap(uint256 indexed tokenId, address indexed to);
    event Unwrap(uint256 indexed tokenId, address indexed to);
    event Vote(uint256 indexed tokenId, address indexed user, uint256 weight);
    event DistributeDividend(address indexed token, uint256 indexed tokenId, uint256 amount);
    event ClaimDividends(address indexed token, uint256 indexed tokenId, uint256 amount, address indexed to);

    function initialize(address _nftContract, address _minter) external;

    function controller() external view returns (address);

    function minter() external view returns (address);

    function votingEscrow() external view returns (address);

    function integrateCheckpoint() external view returns (uint256);

    function period() external view returns (int128);

    function periodTimestamp(int128 period) external view returns (uint256);

    function integrateInvSupply(int128 period) external view returns (uint256);

    function periodOf(uint256 tokenId, address user) external view returns (int128);

    function integrateFraction(uint256 tokenId, address user) external view returns (uint256);

    function pointsSum(uint256 tokenId, uint256 time) external view returns (uint256 bias, uint256 slope);

    function timeSum(uint256 tokenId) external view returns (uint256 lastScheduledTime);

    function voteUserSlopes(
        uint256 tokenId,
        address user,
        uint256 index
    )
        external
        view
        returns (
            uint256 slope,
            uint256 power,
            uint64 end,
            uint64 timestamp
        );

    function voteUserPower(address user) external view returns (uint256);

    function lastUserVote(uint256 tokenId, address user) external view returns (uint256 time);

    function isKilled() external view returns (bool);

    function voteUserSlopesLength(uint256 tokenId, address user) external view returns (uint256);

    function killMe() external;

    function userCheckpoint(uint256 tokenId, address user) external;

    function wrap(
        uint256 tokenId,
        uint256 dividendRatio,
        address to,
        uint256 userWeight
    ) external;

    function unwrap(uint256 tokenId, address to) external;

    function vote(uint256 tokenId, uint256 userWeight) external;

    function revoke(uint256 tokenId) external;

    function claimDividends(address token, uint256 tokenId) external;
}
