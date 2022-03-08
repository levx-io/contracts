// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0;

interface ISmartWalletChecker {
    function check(address addr) external returns (bool);
}
