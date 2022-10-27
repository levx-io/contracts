// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IBase.sol";

interface INFTGaugeFactory is IBase {
    error InvalidFeeRatio();
    error InvalidOwnerAdvantageRatio();
    error NonWhitelistedCurrency();

    event CreateNFTGauge(address indexed nftContract, address indexed gauge);
    event UpdateCurrencyWhitelisted(address indexed token, bool whitelisted);
    event UpdateFeeRatio(uint256 ratio);
    event UpdateOwnerAdvantageRatio(uint256 ratio);
    event SetDelegate(address indexed account, bool isDelegate);

    function weth() external view returns (address);

    function minter() external view returns (address);

    function votingEscrow() external view returns (address);

    function discountToken() external view returns (address);

    function feeVault() external view returns (address);

    function dividendVault() external view returns (address);

    function feeRatio() external view returns (uint256);

    function ownerAdvantageRatio() external view returns (uint256);

    function currencyWhitelisted(address currency) external view returns (bool);

    function gauges(address nftContract) external view returns (address);

    function isGauge(address addr) external view returns (bool);

    function isDelegate(address account) external view returns (bool);

    function calculateFee(address token, uint256 amount) external view returns (uint256);

    function killGauge(address addr) external;

    function updateCurrencyWhitelisted(address token, bool whitelisted) external;

    function updateFeeRatio(uint256 ratio) external;

    function updateOwnerAdvantageRatio(uint256 ratio) external;

    function setDelegate(address account, bool _isDelegate) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address currency,
        address from,
        uint256 amount
    ) external;
}
