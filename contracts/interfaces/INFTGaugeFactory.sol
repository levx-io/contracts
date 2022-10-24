// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGaugeFactory {
    event UpgradeTarget(address target, uint256 indexed version);
    event CreateNFTGauge(address indexed nftContract, address indexed gauge);
    event UpdateCurrencyWhitelisted(address indexed token, bool whitelisted);
    event UpdateFeeRatio(uint256 ratio);
    event UpdateOwnerAdvantageRatio(uint256 ratio);

    function weth() external view returns (address);

    function minter() external view returns (address);

    function votingEscrow() external view returns (address);

    function discountToken() external view returns (address);

    function feeVault() external view returns (address);

    function feeRatio() external view returns (uint256);

    function ownerAdvantageRatio() external view returns (uint256);

    function currencyWhitelisted(address currency) external view returns (bool);

    function gauges(address nftContract) external view returns (address);

    function isGauge(address addr) external view returns (bool);

    function calculateFee(address token, uint256 amount) external view returns (uint256);

    function killGauge(address addr) external;

    function updateCurrencyWhitelisted(address token, bool whitelisted) external;

    function updateFeeRatio(uint256 ratio) external;

    function updateOwnerAdvantageRatio(uint256 ratio) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address currency,
        address from,
        uint256 amount
    ) external;
}
