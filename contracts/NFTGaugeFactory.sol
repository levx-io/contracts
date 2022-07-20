// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./base/CloneFactory.sol";
import "./interfaces/INFTGaugeFactory.sol";
import "./NFTGauge.sol";

contract NFTGaugeFactory is CloneFactory, Ownable, INFTGaugeFactory {
    using SafeERC20 for IERC20;

    address public immutable override tokenURIRenderer;
    address public immutable override controller;
    address internal immutable _target;

    uint256 public override fee;
    mapping(address => bool) public override tokenWhitelisted;
    mapping(address => address) public override gauges;
    mapping(address => bool) public override isGauge;

    constructor(
        address _tokenURIRenderer,
        address _controller,
        uint256 _fee
    ) {
        tokenURIRenderer = _tokenURIRenderer;
        controller = _controller;
        fee = _fee;

        emit UpdateFee(_fee);

        NFTGauge gauge = new NFTGauge();
        gauge.initialize(address(0), address(0), address(0));
        _target = address(gauge);
    }

    function whitelistToken(address token) external override onlyOwner {
        tokenWhitelisted[token] = true;

        emit WhitelistToken(token);
    }

    function updateFee(uint256 _fee) external override onlyOwner {
        fee = _fee;

        emit UpdateFee(_fee);
    }

    function createNFTGauge(address nftContract) external override returns (address gauge) {
        require(gauges[nftContract] == address(0), "NFTGA: GAUGE_CREATED");

        gauge = _createClone(_target);
        INFTGauge(gauge).initialize(nftContract, tokenURIRenderer, controller);

        gauges[nftContract] = gauge;
        isGauge[gauge] = true;

        emit CreateNFTGauge(nftContract, gauge);
    }

    function executePayment(
        address token,
        address from,
        uint256 amount
    ) external override {
        require(isGauge[msg.sender], "NFTGA: FORBIDDEN");
        require(tokenWhitelisted[token], "NFTGA: TOKEN_NOT_WHITELIST");

        IERC20(token).safeTransferFrom(from, msg.sender, amount);
    }
}
