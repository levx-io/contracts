// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.0;

interface IGaugeController {
    event AddType(string name, int128 gaugeType);
    event NewTypeWeight(int128 gaugeType, uint256 time, uint256 weight, uint256 total_weight);
    event NewGaugeWeight(address gauge_address, uint256 time, uint256 weight, uint256 total_weight);
    event VoteForGauge(uint256 time, address user, address gauge_addr, uint256 weight);
    event NewGauge(address addr, int128 gaugeType, uint256 weight);

    function interval() external view returns (uint256);

    function weightVoteDelay() external view returns (uint256);

    function votingEscrow() external view returns (address);

    function gaugeTypesLength() external view returns (int128);

    function gaugesLength() external view returns (int128);

    function gaugeTypeNames(int128 gaugeType) external view returns (string memory);

    function gauges(int128 gaugeType) external view returns (address);

    function voteUserSlopes(address user, address gauge_addr)
        external
        view
        returns (
            uint256 slope,
            uint256 power,
            uint256 end
        );

    function voteUserPower(address user) external view returns (uint256 total_vote_power);

    function lastUserVote(address user, address gauge_addr) external view returns (uint256 time);

    function pointsWeight(address user, uint256 time) external view returns (uint256 bias, uint256 slope);

    function timeWeight(address user) external view returns (uint256 last_scheduled_time);

    function pointsSum(int128 gaugeType, uint256 time) external view returns (uint256 bias, uint256 slope);

    function timeSum(int128 gaugeType) external view returns (uint256 last_scheduled_time);

    function pointsTotal(uint256 time) external view returns (uint256 total_weight);

    function timeTotal() external view returns (uint256 last_scheduled_time);

    function pointsTypeWeight(int128 gaugeType, uint256 time) external view returns (uint256 type_weight);

    function timeTypeWeight(int128 gaugeType) external view returns (uint256 last_scheduled_time);

    function gaugeTypes(address _addr) external view returns (int128);

    function getGaugeWeight(address addr) external view returns (uint256);

    function getTypeWeight(int128 gaugeType) external view returns (uint256);

    function getTotalWeight() external view returns (uint256);

    function getWeightsSumPerType(int128 gaugeType) external view returns (uint256);

    function addGauge(address addr, int128 gaugeType) external;

    function addGauge(
        address addr,
        int128 gaugeType,
        uint256 weight
    ) external;

    function checkpoint() external;

    function checkpointGauge(address addr) external;

    function gaugeRelativeWeight(address addr) external view returns (uint256);

    function gaugeRelativeWeight(address addr, uint256 time) external view returns (uint256);

    function gaugeRelativeWeightWrite(address addr) external returns (uint256);

    function gaugeRelativeWeightWrite(address addr, uint256 time) external returns (uint256);

    function addType(string memory _name) external;

    function addType(string memory _name, uint256 weight) external;

    function changeTypeWeight(int128 gaugeType, uint256 weight) external;

    function changeGaugeWeight(address addr, uint256 weight) external;

    function voteForGaugeWeights(address _gauge_addr, uint256 _user_weight) external;
}
