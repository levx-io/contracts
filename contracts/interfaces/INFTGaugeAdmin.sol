// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGaugeAdmin {
    event WhitelistToken(address indexed token);
    event CreateNFTGauge(address indexed nftContract);
    event UpdateFee(uint256 fee);

    function tokenURIRenderer() external view returns (address);

    function fee() external view returns (uint256);

    function tokenWhitelisted(address token) external view returns (bool);

    function whitelistToken(address token) external;

    function updateFee(uint256 _fee) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address token,
        address from,
        address to,
        uint256 amount
    ) external;
}
