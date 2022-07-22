// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IWrappedERC721.sol";

interface INFTGauge is IWrappedERC721 {
    event Wrap(uint256 indexed tokenId, address indexed to);
    event Unwrap(uint256 indexed tokenId, address indexed to);
    event Vote(uint256 indexed tokenId, address indexed user, uint256 weight);
    event AddDividend(uint256 indexed tokenId, address indexed token, uint256 amount);
    event ClaimDividend(uint256 indexed dividendId, address indexed to, address indexed token, uint256 amount);

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller
    ) external;

    function controller() external view returns (address);

    function ve() external view returns (address);

    function dividendRatios(uint256 tokenId) external view returns (uint256);

    function dividends(uint256 id)
        external
        view
        returns (
            uint256 tokenId,
            uint128 blockNumber,
            uint128 amount,
            address token,
            uint256 total
        );

    function dividendsClaimed(uint256 id, address user) external view returns (bool);

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

    function claimDividends(uint256[] calldata ids) external;
}
