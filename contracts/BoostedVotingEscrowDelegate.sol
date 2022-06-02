// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/INFT.sol";

contract BoostedVotingEscrowDelegate {
    using SafeERC20 for IERC20;

    address public immutable token;
    address public immutable ve;
    address public immutable discountToken;
    uint256 public immutable minDuration;
    uint256 public immutable maxBoost;
    uint256 public immutable deadline;

    constructor(
        address _token,
        address _ve,
        address _discountToken,
        uint256 _minDuration,
        uint256 _maxBoost,
        uint256 _deadline
    ) {
        token = _token;
        ve = _ve;
        discountToken = _discountToken;
        minDuration = _minDuration;
        maxBoost = _maxBoost;
        deadline = _deadline;
    }

    modifier eligibleForDiscount {
        require(INFT(discountToken).balanceOf(msg.sender) > 0, "BVED: DISCOUNT_TOKEN_NOT_OWNED");
        _;
    }

    function createLockDiscounted(uint256 amountToken, uint256 duration) external eligibleForDiscount {
        _createLock(amountToken, duration, true);
    }

    function createLock(uint256 amountToken, uint256 duration) external {
        _createLock(amountToken, duration, false);
    }

    function _createLock(
        uint256 amountToken,
        uint256 duration,
        bool discounted
    ) internal {
        require(block.timestamp < deadline, "BVED: EXPIRED");

        uint256 interval = IVotingEscrow(ve).interval();
        uint256 unlockTime = ((block.timestamp + duration) / interval) * interval; // rounded down to a multiple of interval
        uint256 amountVE = _amountVE(amountToken, unlockTime - block.timestamp, discounted);

        IVotingEscrow(ve).createLockFor(msg.sender, amountVE, amountVE - amountToken, unlockTime);
    }

    function increaseAmountDiscounted(uint256 amountToken) external eligibleForDiscount {
        _increaseAmount(amountToken, true);
    }

    function increaseAmount(uint256 amountToken) external {
        _increaseAmount(amountToken, false);
    }

    function _increaseAmount(uint256 amountToken, bool discounted) internal {
        require(block.timestamp < deadline, "BVED: EXPIRED");

        uint256 unlockTime = IVotingEscrow(ve).unlockTime(msg.sender);
        require(unlockTime > 0, "BVED: LOCK_NOT_FOUND");

        uint256 amountVE = _amountVE(amountToken, unlockTime - block.timestamp, discounted);

        IVotingEscrow(ve).increaseAmountFor(msg.sender, amountVE, amountVE - amountToken);
    }

    function _amountVE(
        uint256 amountToken,
        uint256 duration,
        bool discounted
    ) internal view returns (uint256 amountVE) {
        uint256 maxDuration = IVotingEscrow(ve).maxDuration();
        require(duration >= minDuration, "BVED: DURATION_TOO_SHORT");
        require(duration <= maxDuration, "BVED: DURATION_TOO_LONG");

        amountVE = (amountToken * maxBoost * duration) / maxDuration;
        if (discounted) {
            amountVE = (amountVE * 100) / 90;
        }
    }
}
