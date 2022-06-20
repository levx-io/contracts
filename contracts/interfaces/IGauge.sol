// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.0;

interface IGauge {
    function initialize(address addr) external;

    function vote(bytes32 id, uint256 weight) external;
}
