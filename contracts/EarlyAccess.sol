// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./interfaces/INFTGaugeFactory.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IVotingEscrow.sol";

contract EarlyAccess is Ownable {
    event AddCollection(address indexed collection);

    address public immutable factory;
    uint256 public immutable amount;
    address public immutable votingEscrow;
    uint256 public immutable maxDuration;

    uint256 public launchedAt;
    mapping(address => bool) public collections;
    mapping(address => mapping(uint256 => bool)) public whitelisted;
    mapping(address => mapping(uint256 => bool)) public claimed;

    constructor(address _factory, uint256 _amount) {
        factory = _factory;
        amount = _amount;

        votingEscrow = INFTGaugeFactory(_factory).votingEscrow();
        maxDuration = IVotingEscrow(_factory).maxDuration();
    }

    function launch() external onlyOwner {
        require(launchedAt == 0, "EA: LAUNCHED");

        launchedAt = block.timestamp;
    }

    function addCollections(address[] calldata _collections) external onlyOwner {
        require(launchedAt == 0, "EA: LAUNCHED");
        for (uint256 i; i < _collections.length; i++) {
            collections[_collections[i]] = true;
            emit AddCollection(_collections[i]);
        }
    }

    function whitelistNFTs(address collection, uint256[] calldata tokenIds) external {
        require(launchedAt == 0, "EA: LAUNCHED");
        require(collections[collection], "EA: COLLECTION_NOT_ALLOWED");
        for (uint256 i; i < tokenIds.length; i++) {
            require(IERC721(collection).ownerOf(tokenIds[i]) == msg.sender, "EA: FORBIDDEN");
            whitelisted[collection][tokenIds[i]] = true;
        }
    }

    function wrapNFT(
        address collection,
        uint256 tokenId,
        uint256 dividendRatio
    ) external {
        require(launchedAt > 0, "EA: NOT_LAUNCHED");
        require(whitelisted[collection][tokenId], "EA: NOT_WHITELISTED");

        IERC721(collection).safeTransferFrom(msg.sender, address(this), tokenId);

        address gauge = INFTGaugeFactory(factory).gauges(collection);
        INFTGauge(gauge).wrap(tokenId, dividendRatio, msg.sender, 0);

        IVotingEscrow(votingEscrow).createLockFor(msg.sender, amount, amount, maxDuration);
    }
}
