// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGaugeAdmin {
    event WhitelistToken(address indexed token);
    event CreateNFTGauge(address indexed nftContract, address indexed gauge);
    event UpdateFee(uint256 fee);

    function tokenURIRenderer() external view returns (address);

    function controller() external view returns (address);

    function fee() external view returns (uint256);

    function tokenWhitelisted(address token) external view returns (bool);

    function gauges(address nftContract) external view returns (address);

    function isGauge(address addr) external view returns (bool);

    function whitelistToken(address token) external;

    function updateFee(uint256 _fee) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address token,
        address from,
        uint256 amount
    ) external;
}
