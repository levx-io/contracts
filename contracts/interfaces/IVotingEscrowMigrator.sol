// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IBase.sol";

interface IVotingEscrowMigrator is IBase {
    error NotPreMigrated();

    function migrate(
        address account,
        int128 amount,
        int128 discount,
        uint256 start,
        uint256 end,
        address[] calldata delegates
    ) external;
}
