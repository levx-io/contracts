// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IWrappedERC721.sol";

interface INFTGauge is IWrappedERC721 {
    event Wrap(uint256 indexed tokenId, address indexed to);
    event Unwrap(uint256 indexed tokenId, address indexed to);
    event Vote(uint256 indexed tokenId, address indexed user, uint256 weight);
    event DistributeDividend(address indexed token, uint256 indexed id, uint256 indexed tokenId, uint256 amount);
    event ClaimDividends(address indexed token, uint256 amount, address indexed to);

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller,
        address _minter,
        address _ve
    ) external;

    function controller() external view returns (address);

    function minter() external view returns (address);

    function ve() external view returns (address);

    function rewards(uint256 tokenId, uint256 id) external view returns (uint64 blockNumber, uint192 amountPerShare);

    function rewardsClaimed(
        uint256 tokenId,
        uint256 id,
        address user
    ) external view returns (bool);

    function dividendRatios(uint256 tokenId) external view returns (uint256);

    function dividends(address token, uint256 id)
        external
        view
        returns (
            uint256 tokenId,
            uint64 blockNumber,
            uint192 amountPerShare
        );

    function dividendsClaimed(
        address token,
        uint256 id,
        address user
    ) external view returns (bool);

    function isKilled() external view returns (bool);

    function points(uint256 tokenId, address user) external view returns (uint256);

    function pointsAt(
        uint256 tokenId,
        address user,
        uint256 _block
    ) external view returns (uint256);

    function pointsSum(uint256 tokenId) external view returns (uint256);

    function pointsSumAt(uint256 tokenId, uint256 _block) external view returns (uint256);

    function pointsTotal() external view returns (uint256);

    function pointsTotalAt(uint256 _block) external view returns (uint256);

    function dividendsLength(address token) external view returns (uint256);

    function killMe() external;

    function checkpoint(uint256 tokenId) external returns (uint256 amountToMint);

    function wrap(
        uint256 tokenId,
        uint256 ratio,
        address to
    ) external;

    function wrap(
        uint256 tokenId,
        uint256 ratio,
        address to,
        uint256 userWeight
    ) external;

    function unwrap(uint256 tokenId, address to) external;

    function vote(uint256 tokenId, uint256 userWeight) external;

    function claimDividends(address token, uint256[] calldata ids) external;
}
