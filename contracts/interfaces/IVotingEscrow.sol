// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IBase.sol";

interface IVotingEscrow is IBase {
    error NotExpired();
    error NotPastBlock();

    event SetWhitelistedContract(address indexed account, bool isWhitelisted);
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed unlockTime,
        int128 indexed _type,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);

    function token() external view returns (address);

    function supply() external view returns (uint256);

    function locked(address account) external view returns (int128 amount, uint256 end);

    function epoch() external view returns (uint256);

    function pointHistory(uint256 epoch) external view returns (int128 bias, int128 slope, uint256 ts, uint256 blk);

    function userPointHistory(
        address account,
        uint256 epoch
    ) external view returns (int128 bias, int128 slope, uint256 ts, uint256 blk);

    function userPointEpoch(address account) external view returns (uint256);

    function slopeChanges(uint256 epoch) external view returns (int128);

    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    function isWhitelistedContract(address account) external view returns (bool);

    function getLastUserSlope(address addr) external view returns (int128);

    function getCheckpointTime(address _addr, uint256 _idx) external view returns (uint256);

    function unlockTime(address _addr) external view returns (uint256);

    function setWhitelistedContract(address account, bool isWhitelisted) external;

    function checkpoint() external;

    function depositFor(address _addr, uint256 _value) external;

    function createLock(uint256 _value, uint256 _duration) external;

    function increaseAmount(uint256 _value) external;

    function increaseUnlockTime(uint256 _duration) external;

    function withdraw() external;

    function balanceOf(address addr) external view returns (uint256);

    function balanceOf(address addr, uint256 _t) external view returns (uint256);

    function balanceOfAt(address addr, uint256 _block) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function totalSupply(uint256 t) external view returns (uint256);

    function totalSupplyAt(uint256 _block) external view returns (uint256);
}
