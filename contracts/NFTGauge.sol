// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/IGauge.sol";
import "./interfaces/IGaugeProxy.sol";
import "./interfaces/IGaugeController.sol";
import "./base/BaseGaugeController.sol";

contract NFTGauge is Initializable, BaseGaugeController, IGauge {
    address public proxy;
    address public controller;
    address public nftContract;

    function initialize(address _nftContract) external initializer {
        proxy = msg.sender;
        controller = IGaugeProxy(proxy).controller();
        nftContract = _nftContract;
    }

    function vote(bytes32 id, uint256 weight) public override {
        uint256 tokenId = uint256(id);
        require(IERC721(nftContract).ownerOf(tokenId) != address(0), "NFTG: NFT_NOT_MINTED");

        IGaugeProxy(proxy).voteForGaugeWeights(msg.sender, weight);
        _voteForGaugeWeights(id, msg.sender, weight);
    }
}
