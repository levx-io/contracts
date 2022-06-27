// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./base/WrappedERC721.sol";

contract NFTGauge is WrappedERC721 {
    mapping(uint256 => bool) public withdrawn;

    function initialize(address _nftContract, address _tokenURIRenderer) external initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);
    }

    function deposit(address to, uint256 tokenId) public {
        withdrawn[tokenId] = false;

        _mint(to, tokenId);
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function withdraw(address to, uint256 tokenId) public {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        withdrawn[tokenId] = true;

        _burn(tokenId);
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }
}
