// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IBase {
    error Forbidden();
    error Expired();
    error Existent();
    error NonExistent();
    error TooLate();
    error TooEarly();
    error InvalidAmount();
    error InvalidPath();
}
