// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IVotingEscrow.sol";

interface IVotingEscrowLegacy is IVotingEscrow {
    event SetMigrator(address indexed account);
    event Cancel(address indexed provider, uint256 value, uint256 discount, uint256 penaltyRate, uint256 ts);
    event Migrate(address indexed provider, uint256 value, uint256 discount, uint256 ts);

    function migrator() external view returns (address);

    function migrated(address account) external view returns (bool);

    function setMigrator(address _migrator) external;

    function cancel() external;

    function migrate() external;
}
