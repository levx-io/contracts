// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGaugeController.sol";
import "./base/BaseGaugeController.sol";

contract GaugeController is Ownable, BaseGaugeController, IGaugeController {
    mapping(address => int128) public override proxies;

    modifier onlyProxy(int128 gaugeType) {
        require(proxies[msg.sender] == gaugeType, "GC: FORBIDDEN");
        _;
    }

    /**
     * @notice Contract initializer
     * @param _interval for how many seconds gauge weights will remain the same
     * @param _weightVoteDelay for how many seconds weight votes cannot be changed
     * @param _votingEscrow `VotingEscrow` contract address
     */
    function initialize(
        uint256 _interval,
        uint256 _weightVoteDelay,
        address _votingEscrow
    ) public override initializer {
        __BaseGaugeController_init(_interval, _weightVoteDelay, _votingEscrow);
    }

    function addProxy(address proxy, int128 gaugeType) external override {
        proxies[proxy] = gaugeType;

        emit AddProxy(proxy, gaugeType);
    }

    function removeProxy(address proxy) external override {
        int128 gaugeType = proxies[proxy];
        require(gaugeType != 0, "GC: INVALID_PROXY");
        proxies[proxy] = 0;

        emit RemoveProxy(proxy, gaugeType);
    }

    /**
     * @notice Add gauge type with name `name` and weight `weight`
     * @param name Name of gauge type
     */
    function addType(string memory name) public override {
        _addType(name);
    }

    /**
     * @notice Add gauge type with name `name` and weight `weight`
     * @param name Name of gauge type
     * @param weight Weight of gauge type
     */
    function addType(string memory name, uint256 weight) public override onlyOwner {
        _addType(name, weight);
    }

    /**
     * @notice Change gauge type `gaugeType` weight to `weight`
     * @param gaugeType Gauge type id
     * @param weight New Gauge weight
     */
    function changeTypeWeight(int128 gaugeType, uint256 weight) public override onlyOwner {
        _changeTypeWeight(gaugeType, weight);
    }

    /**
     * @notice Add gauge `id` of type `gaugeType` with weight `weight`
     * @param id Gauge id
     * @param gaugeType Gauge type
     */
    function addGauge(bytes32 id, int128 gaugeType) public virtual override onlyProxy(gaugeType) {
        _addGauge(id, gaugeType);
    }

    /**
     * @notice Add gauge `id` of type `gaugeType` with weight `weight`
     * @param id Gauge id
     * @param gaugeType Gauge type
     * @param weight Gauge weight
     */
    function addGauge(
        bytes32 id,
        int128 gaugeType,
        uint256 weight
    ) public virtual override onlyProxy(gaugeType) {
        _addGauge(id, gaugeType, weight);
    }

    /**
     * @notice Change weight of gauge `id` to `weight`
     * @param id Gauge id
     * @param weight New Gauge weight
     */
    function changeGaugeWeight(bytes32 id, uint256 weight) public virtual override onlyProxy(_gaugeTypes[id] - 1) {
        _changeGaugeWeight(id, weight);
    }

    /**
     * @notice Allocate voting power for changing pool weights on behalf of a user
     * @param id Gauge which `user` votes for
     * @param user User's wallet address
     * @param userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function voteForGaugeWeights(
        bytes32 id,
        address user,
        uint256 userWeight
    ) external virtual override onlyProxy(_gaugeTypes[id] - 1) {
        _voteForGaugeWeights(id, user, userWeight);
    }

    /**
     * @notice Allocate voting power for changing pool weights
     * @param id Gauge which `user` votes for
     * @param userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function voteForGaugeWeights(bytes32 id, uint256 userWeight) external virtual override {
        _voteForGaugeWeights(id, msg.sender, userWeight);
    }
}
