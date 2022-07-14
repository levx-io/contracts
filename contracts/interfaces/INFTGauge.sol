// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IWrappedERC721.sol";

interface INFTGauge is IWrappedERC721 {
    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller
    ) external;

    function controller() external view returns (address);

    function ve() external view returns (address);

    function deposit(address to, uint256 tokenId) external;

    function withdraw(address to, uint256 tokenId) external;

    event Deposit(address indexed to, uint256 indexed tokenId);
    event Withdraw(address indexed to, uint256 indexed tokenId);
}
