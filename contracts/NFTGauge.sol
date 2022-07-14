// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";

contract NFTGauge is WrappedERC721, INFTGauge {
    address public override controller;
    address public override ve;

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller
    ) external override initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);

        controller = _controller;
        ve = IGaugeController(_controller).votingEscrow();
    }

    /**
     * @notice Mint a wrapped NFT and commit gauge voting to this gauge addr
     * @param to The owner of the newly minted wrapped NFT
     * @param tokenId Token Id to deposit
     */
    function deposit(address to, uint256 tokenId) public override {
        _mint(to, tokenId);
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        emit Deposit(to, tokenId);
    }

    function withdraw(address to, uint256 tokenId) public override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        _cancelIfListed(tokenId, msg.sender);

        _burn(tokenId);
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);

        emit Withdraw(to, tokenId);
    }
}
