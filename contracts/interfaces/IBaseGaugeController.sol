// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.0;

interface IBaseGaugeController {
    event AddType(string name, int128 gaugeType);
    event NewTypeWeight(int128 gaugeType, uint256 time, uint256 weight, uint256 totalWeight);
    event NewGaugeWeight(bytes32 id, uint256 time, uint256 weight, uint256 totalWeight);
    event VoteForGauge(uint256 time, address user, bytes32 id, uint256 weight);
    event NewGauge(bytes32 id, int128 gaugeType, uint256 weight);

    function initialize(
        uint256 interval,
        uint256 weightVoteDelay,
        address votingEscrow
    ) external;

    function interval() external view returns (uint256);

    function weightVoteDelay() external view returns (uint256);

    function votingEscrow() external view returns (address);

    function gaugeTypesLength() external view returns (int128);

    function gaugesLength() external view returns (int128);

    function gaugeTypeNames(int128 gaugeType) external view returns (string memory);

    function gauges(int128 gaugeType) external view returns (bytes32);

    function voteUserSlopes(address user, bytes32 id)
        external
        view
        returns (
            uint256 slope,
            uint256 power,
            uint256 end
        );

    function voteUserPower(address user) external view returns (uint256 totalVotePower);

    function lastUserVote(address user, bytes32 id) external view returns (uint256 time);

    function pointsWeight(bytes32 id, uint256 time) external view returns (uint256 bias, uint256 slope);

    function timeWeight(bytes32 id) external view returns (uint256 lastScheduledTime);

    function pointsSum(int128 gaugeType, uint256 time) external view returns (uint256 bias, uint256 slope);

    function timeSum(int128 gaugeType) external view returns (uint256 lastScheduledTime);

    function pointsTotal(uint256 time) external view returns (uint256 totalWeight);

    function timeTotal() external view returns (uint256 lastScheduledTime);

    function pointsTypeWeight(int128 gaugeType, uint256 time) external view returns (uint256 typeWeight);

    function timeTypeWeight(int128 gaugeType) external view returns (uint256 lastScheduledTime);

    function gaugeTypes(bytes32 id) external view returns (int128);

    function getGaugeWeight(bytes32 id) external view returns (uint256);

    function getTypeWeight(int128 gaugeType) external view returns (uint256);

    function getTotalWeight() external view returns (uint256);

    function getWeightsSumPerType(int128 gaugeType) external view returns (uint256);

    function gaugeRelativeWeight(bytes32 id) external view returns (uint256);

    function gaugeRelativeWeight(bytes32 id, uint256 time) external view returns (uint256);

    function checkpoint() external;

    function checkpointGauge(bytes32 id) external;

    function gaugeRelativeWeightWrite(bytes32 id) external returns (uint256);

    function gaugeRelativeWeightWrite(bytes32 id, uint256 time) external returns (uint256);
}
