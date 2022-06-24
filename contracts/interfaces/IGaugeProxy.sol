// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IGaugeProxy {
    event CreateGauge(address addr, address gauge);

    function controller() external view returns (address);

    function gaugeType() external view returns (int128);

    function addrs(address gauge) external view returns (address addr);

    function createGauge(address addr) external returns (address gauge);

    function voteForGaugeWeights(address user, uint256 userWeight) external;
}
