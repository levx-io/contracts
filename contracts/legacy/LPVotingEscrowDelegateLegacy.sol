// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../base/Base.sol";
import "../base/VotingEscrowDelegate.sol";
import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IVotingEscrowMigrator.sol";

contract LPVotingEscrowDelegateLegacy is Base, VotingEscrowDelegate {
    using SafeERC20 for IERC20;

    struct LockedBalance {
        uint256 amount;
        uint256 end;
    }

    bool internal immutable isToken1;
    uint256 public immutable minAmount;
    uint256 public immutable maxBoost;

    uint256 public lockedTotal;
    mapping(address => uint256) public locked;

    constructor(
        address _ve,
        address _lpToken,
        address _discountToken,
        bool _isToken1,
        uint256 _minAmount,
        uint256 _maxBoost
    ) VotingEscrowDelegate(_ve, _lpToken, _discountToken) {
        isToken1 = _isToken1;
        minAmount = _minAmount;
        maxBoost = _maxBoost;
    }

    function _createLock(
        uint256 amount,
        uint256 duration,
        bool discounted
    ) internal override {
        revertIfInvalidAmount(amount >= minAmount);

        super._createLock(amount, duration, discounted);

        lockedTotal += amount;
        locked[msg.sender] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _increaseAmount(uint256 amount, bool discounted) internal override {
        revertIfInvalidAmount(amount >= minAmount);

        super._increaseAmount(amount, discounted);

        lockedTotal += amount;
        locked[msg.sender] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _getAmounts(uint256 amount, uint256)
        internal
        view
        override
        returns (uint256 amountVE, uint256 amountToken)
    {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(token).getReserves();
        uint256 reserve = isToken1 ? uint256(reserve1) : uint256(reserve0);

        uint256 totalSupply = IUniswapV2Pair(token).totalSupply();
        uint256 _amountToken = (amount * reserve) / totalSupply;

        amountVE = _amountToken + (_amountToken * maxBoost * (totalSupply - lockedTotal)) / totalSupply / totalSupply;
        uint256 upperBound = (_amountToken * 333) / 10;
        if (amountVE > upperBound) {
            amountVE = upperBound;
        }
        amountToken = 0;
    }

    function withdraw(address addr, uint256 penaltyRate) external override {
        revertIfForbidden(msg.sender == ve);

        uint256 amount = locked[addr];
        revertIfNonExistent(amount > 0);

        lockedTotal -= amount;
        locked[addr] = 0;
        IERC20(token).safeTransfer(addr, (amount * (1e18 - penaltyRate)) / 1e18);

        emit Withdraw(addr, amount, penaltyRate);
    }
}
