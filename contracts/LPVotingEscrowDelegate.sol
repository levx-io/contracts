// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./legacy/LPVotingEscrowDelegateLegacy.sol";
import "./base/Base.sol";
import "./libraries/Integers.sol";

contract LPVotingEscrowDelegate is Base, LPVotingEscrowDelegateLegacy, IVotingEscrowMigrator {
    using SafeERC20 for IERC20;
    using Integers for int128;

    event Migrate(address indexed account, uint256 amount);

    mapping(address => uint256) public lockedLegacy;
    address public legacy;

    constructor(
        address _ve,
        address _lpToken,
        address _discountToken,
        bool _isToken1,
        uint256 _minAmount,
        uint256 _maxBoost,
        address _legacy
    ) LPVotingEscrowDelegateLegacy(_ve, _lpToken, _discountToken, _isToken1, _minAmount, _maxBoost) {
        legacy = _legacy;
    }

    function revertIfNotPreMigrated(bool success) internal pure {
        if (!success) revert NotPreMigrated();
    }

    function preMigrate() external {
        lockedLegacy[msg.sender] = LPVotingEscrowDelegateLegacy(legacy).locked(msg.sender);
    }

    function migrate(
        address account,
        int128 amountVE,
        int128 discount,
        uint256,
        uint256 end,
        address[] calldata
    ) external {
        revertIfForbidden(msg.sender == ve);

        uint256 amount = lockedLegacy[account];
        revertIfNotPreMigrated(amount > 0);

        lockedLegacy[account] = 0;

        lockedTotal += amount;
        locked[account] += amount;
        IERC20(token).safeTransferFrom(account, address(this), amount);

        emit CreateLock(account, amountVE.toUint256(), discount.toUint256(), end);
        emit Migrate(account, amount);
    }
}
