// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IBase.sol";

interface IVotingEscrowDelegate is IBase {
    error NotEligible();
    error DurationTooLong();

    event Withdraw(address indexed addr, uint256 amount, uint256 penaltyRate);

    function withdraw(address addr, uint256 penaltyRate) external;
}
