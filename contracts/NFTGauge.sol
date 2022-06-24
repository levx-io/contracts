// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./interfaces/IGaugeProxy.sol";
import "./base/BaseGaugeController.sol";
import "./base/WrappedERC721.sol";

contract NFTGauge is BaseGaugeController, WrappedERC721 {
    address public proxy;
    address public controller;

    mapping(uint256 => bool) public withdrawn;

    function initialize(address _nftContract) external initializer {
        proxy = msg.sender;
        controller = IGaugeProxy(msg.sender).controller();

        __WrappedERC721_init(_nftContract);
        __BaseGaugeController_init(
            IBaseGaugeController(controller).interval(),
            IBaseGaugeController(controller).weightVoteDelay(),
            IBaseGaugeController(controller).votingEscrow()
        );

        _addType("NFTs", 10**18);
    }

    function deposit(address to, uint256 tokenId) public {
        bytes32 id = bytes32(tokenId);
        if (_gaugeTypes[id] == 0) {
            _addGauge(id, 0);
        }
        withdrawn[tokenId] = false;

        _mint(to, tokenId);
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function withdraw(address to, uint256 tokenId) public {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        _changeGaugeWeight(bytes32(tokenId), 0);
        withdrawn[tokenId] = true;

        _burn(tokenId);
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function voteForGaugeWeights(uint256 tokenId, uint256 userWeight) external {
        require(!withdrawn[tokenId], "NFTG: WITHDRAWN");

        _voteForGaugeWeights(bytes32(tokenId), msg.sender, userWeight);
    }
}
