// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./CloneFactory.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IGauge.sol";

contract GaugeProxy is CloneFactory, Ownable {
    address immutable controller;
    mapping(int128 => address) public templateOf;
    mapping(address => address) public gaugeOf;

    event UpgradeTypeTemplate(int128 indexed id, address indexed template);
    event CreateGauge(address addr, address gauge);

    constructor(address _controller) {
        controller = _controller;
    }

    function transferOwnershipOfController(address newOwner) external onlyOwner {
        Ownable(controller).transferOwnership(newOwner);
    }

    function addType(
        string memory name,
        uint256 weight,
        address template
    ) external onlyOwner {
        IGaugeController(controller).addType(name, weight);
        int128 typeId = IGaugeController(controller).gaugeTypesLength() - 1;
        templateOf[typeId] = template;

        emit UpgradeTypeTemplate(typeId, template);
    }

    function changeTypeWeight(int128 typeId, uint256 weight) external onlyOwner {
        IGaugeController(controller).changeTypeWeight(typeId, weight);
    }

    function upgradeTypeTemplate(int128 typeId, address template) external onlyOwner {
        require(templateOf[typeId] != address(0), "GP: TYPE_NOT_ADDED");

        templateOf[typeId] = template;

        emit UpgradeTypeTemplate(typeId, template);
    }

    function createGauge(
        address addr,
        int128 typeId,
        uint256 weight
    ) public returns (address gauge) {
        require(gaugeOf[addr] == address(0), "GP: GAUGE_EXISTENT");

        address template = templateOf[typeId];
        require(template != address(0), "GP: TEMPLATE_NOT_SET");

        gauge = _createClone(template);
        IGauge(gauge).initialize(addr);

        gaugeOf[addr] = gauge;

        IGaugeController(controller).addGauge(gauge, typeId, weight);

        emit CreateGauge(addr, gauge);
    }
}
