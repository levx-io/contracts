// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVotingEscrow.sol";

contract BoostedVotingEscrowDelegate {
    using SafeERC20 for IERC20;

    uint256 internal constant BOOST_BASE = 1e12;

    address public token;
    address public ve;
    uint256 public minBoost;
    uint256 public maxBoost;
    uint256 public deadline;

    constructor(
        address _token,
        address _ve,
        uint256 _minBoost,
        uint256 _maxBoost,
        uint256 _deadline
    ) {
        token = _token;
        ve = _ve;
        minBoost = _minBoost;
        maxBoost = _maxBoost;
        deadline = _deadline;

        IERC20(_token).approve(_ve, type(uint256).max);
    }

    function boosted(uint256 amountToken, uint256 duration) public view returns (uint256 amountVE, uint256 unlockTime) {
        (uint256 interval, uint256 maxtime) = IVotingEscrow(ve).getTemporalParams();
        duration = (duration / interval) * interval; // rounded down to a multiple of interval

        uint256 boost = (maxBoost * duration) / maxtime;
        require(boost >= minBoost, "BVED: DURATION_TOO_SHORT");

        return ((amountToken * boost) / BOOST_BASE, block.timestamp + duration);
    }

    function createLock(uint256 amountToken, uint256 duration) external {
        require(block.timestamp < deadline, "BVED: EXPIRED");

        (uint256 amountVE, uint256 unlockTime) = boosted(amountToken, duration);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountToken);
        IVotingEscrow(ve).createLockFor(msg.sender, amountVE, amountVE - amountToken, unlockTime);
    }
}
