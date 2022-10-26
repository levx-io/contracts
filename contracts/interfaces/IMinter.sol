// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IBase.sol";

interface IMinter is IBase {
    error InvalidTimeRange();
    error TooLate();
    error TooSoon();
    error NoAmountToMint();

    event UpdateMiningParameters(uint256 time, uint256 rate, uint256 supply);
    event UpdateTreasury(address treasury);
    event Minted(address indexed recipient, address indexed gaugeAddr, uint256 indexed tokenId, uint256 minted);
    event MintedForTreasury(address indexed treasury, uint256 minted);

    function token() external view returns (address);

    function controller() external view returns (address);

    function initialSupply() external view returns (uint256);

    function initialRate() external view returns (uint256);

    function rateReductionTime() external view returns (uint256);

    function rateReductionCoefficient() external view returns (uint256);

    function treasury() external view returns (address);

    function miningEpoch() external view returns (int128);

    function startEpochTime() external view returns (uint256);

    function rate() external view returns (uint256);

    function availableSupply() external view returns (uint256);

    function mintableInTimeframe(uint256 start, uint256 end) external view returns (uint256);

    function mintedTotal() external view returns (uint256);

    function mintedForTreasury() external view returns (uint256);

    function minted(
        address gaugeAddr,
        uint256 tokenId,
        address user
    ) external view returns (uint256);

    function updateTreasury(address newTreasury) external;

    function updateMiningParameters() external;

    function startEpochTimeWrite() external returns (uint256);

    function futureEpochTimeWrite() external returns (uint256);

    function mint(address gaugeAddr, uint256 tokenId) external;

    function mintForTreasury() external;
}
