// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./base/CloneFactory.sol";
import "./NFTGauge.sol";
import "./interfaces/IGaugeProxy.sol";
import "./interfaces/IGaugeController.sol";

contract NFTGaugeProxy is CloneFactory, Ownable, IGaugeProxy {
    address public immutable override controller;
    int128 public immutable override gaugeType;
    address public immutable tokenURIRenderer;
    address internal immutable _target;

    mapping(address => address) public override addrs;

    constructor(
        address _controller,
        int128 _gaugeType,
        address _tokenURIRenderer
    ) {
        controller = _controller;
        gaugeType = _gaugeType;
        tokenURIRenderer = _tokenURIRenderer;

        NFTGauge gauge = new NFTGauge();
        gauge.initialize(address(0), address(0));
        _target = address(gauge);
    }

    function createGauge(address addr) external override onlyOwner returns (address gauge) {
        gauge = _createClone(_target);
        NFTGauge(gauge).initialize(addr, tokenURIRenderer);

        require(addrs[gauge] == address(0), "GP: GAUGE_CREATED");
        addrs[gauge] = addr;

        bytes32 id = bytes32(bytes20(addr));
        IGaugeController(controller).addGauge(id, gaugeType);

        emit CreateGauge(addr, gauge);
    }

    function voteForGaugeWeights(address user, uint256 userWeight) external override {
        address gauge = msg.sender;
        require(addrs[gauge] != address(0), "GP: FORBIDDEN");

        bytes32 id = bytes32(bytes20(gauge));
        IGaugeController(controller).voteForGaugeWeights(id, user, userWeight);
    }
}
