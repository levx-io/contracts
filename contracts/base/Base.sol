// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

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
}
