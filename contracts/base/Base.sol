// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "../interfaces/IBase.sol";

abstract contract Base is IBase {
    function revertIfForbidden(bool success) internal pure {
        if (!success) revert Forbidden();
    }

    function revertIfExpired(bool success) internal pure {
        if (!success) revert Expired();
    }

    function revertIfExistent(bool success) internal pure {
        if (!success) revert Existent();
    }

    function revertIfNonExistent(bool success) internal pure {
        if (!success) revert NonExistent();
    }

    function revertIfTooLate(bool success) internal pure {
        if (!success) revert TooLate();
    }

    function revertIfTooEarly(bool success) internal pure {
        if (!success) revert TooEarly();
    }

    function revertIfInvalidAmount(bool success) internal pure {
        if (!success) revert InvalidAmount();
    }

    function revertIfInvalidPath(bool success) internal pure {
        if (!success) revert InvalidPath();
    }

    function revertIfOutOfRange(bool success) internal pure {
        if (!success) revert OutOfRange();
    }
}
