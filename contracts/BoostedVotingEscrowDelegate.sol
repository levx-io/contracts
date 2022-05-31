// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVotingEscrow.sol";

contract BoostedVotingEscrowDelegate {
    using SafeERC20 for IERC20;

    uint256 internal constant BOOST_BASE = 1e12;

    address public immutable token;
    address public immutable ve;
    uint256 public immutable mintime;
    uint256 public immutable maxBoost;
    uint256 public immutable deadline;

    constructor(
        address _token,
        address _ve,
        uint256 _mintime,
        uint256 _maxBoost,
        uint256 _deadline
    ) {
        token = _token;
        ve = _ve;
        mintime = _mintime;
        maxBoost = _maxBoost;
        deadline = _deadline;
    }

    function boosted(uint256 amountToken, uint256 duration) public view returns (uint256 amountVE, uint256 unlockTime) {
        (uint256 interval, uint256 maxtime) = IVotingEscrow(ve).getTemporalParams();
        duration = (duration / interval) * interval; // rounded down to a multiple of interval
        require(duration >= mintime, "BVED: DURATION_TOO_SHORT");

        uint256 boost = (maxBoost * duration) / maxtime;
        return ((amountToken * boost) / BOOST_BASE, block.timestamp + duration);
    }

    function createLock(uint256 amountToken, uint256 duration) external {
        require(block.timestamp < deadline, "BVED: EXPIRED");

        (uint256 amountVE, uint256 unlockTime) = boosted(amountToken, duration);

        IVotingEscrow(ve).createLockFor(msg.sender, amountVE, amountVE - amountToken, unlockTime);
    }

    function increaseAmount(uint256 amountToken) external {
        require(block.timestamp < deadline, "BVED: EXPIRED");

        uint256 unlockTime = IVotingEscrow(ve).unlockTime(msg.sender);
        require(unlockTime > 0, "BVED: LOCK_NOT_FOUND");

        (uint256 amountVE, ) = boosted(amountToken, unlockTime - block.timestamp);

        IVotingEscrow(ve).increaseAmountFor(msg.sender, amountVE, amountVE - amountToken);
    }
}
