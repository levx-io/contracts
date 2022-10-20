// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGaugeFactory {
    event UpgradeTarget(address target, uint256 indexed version);
    event CreateNFTGauge(address indexed nftContract, address indexed gauge);
    event UpdateCurrencyWhitelisted(address indexed token, bool whitelisted);
    event UpdateFeeRatio(uint256 feeRatio);
    event DistributeFees(address indexed token, uint256 indexed id, uint256 amount);
    event ClaimFees(address indexed token, uint256 amount, address indexed to);

    function weth() external view returns (address);

    function minter() external view returns (address);

    function votingEscrow() external view returns (address);

    function discountToken() external view returns (address);

    function feeRatio() external view returns (uint256);

    function currencyWhitelisted(address currency) external view returns (bool);

    function gauges(address nftContract) external view returns (address);

    function isGauge(address addr) external view returns (bool);

    function fees(address token, uint256 id) external view returns (uint64 timestamp, uint192 amountPerShare);

    function lastFeeClaimed(address token, address user) external view returns (uint256);

    function feesLength(address token) external view returns (uint256);

    function killGauge(address addr) external;

    function updateCurrencyWhitelisted(address token, bool whitelisted) external;

    function updateFeeRatio(uint256 feeRatio) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address currency,
        address from,
        uint256 amount
    ) external;

    function distributeFees(address token, uint256 amount) external returns (uint256 amountFee);

    function claimFees(address token, uint256 to) external;
}
