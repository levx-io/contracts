// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.0;

import "./IBaseGaugeController.sol";

interface IGaugeController is IBaseGaugeController {
    event AddProxy(address indexed proxy, int128 indexed gaugeType);
    event RemoveProxy(address indexed proxy, int128 indexed gaugeType);

    function proxies(address gauge) external view returns (int128 gaugeType);

    function addType(string memory name) external;

    function addType(string memory name, uint256 weight) external;

    function changeTypeWeight(int128 gaugeType, uint256 weight) external;

    function addGauge(bytes32 id, int128 gaugeType) external;

    function addGauge(
        bytes32 id,
        int128 gaugeType,
        uint256 weight
    ) external;

    function changeGaugeWeight(bytes32 id, uint256 weight) external;

    function addProxy(address proxy, int128 gaugeType) external;

    function removeProxy(address proxy) external;

    function voteForGaugeWeights(
        bytes32 id,
        address user,
        uint256 userWeight
    ) external;

    function voteForGaugeWeights(bytes32 id, uint256 _user_weight) external;
}
