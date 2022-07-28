// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGaugeFactory {
    event UpgradeTarget(address target, uint256 indexed version);
    event WhitelistToken(address indexed token);
    event CreateNFTGauge(address indexed nftContract, address indexed gauge);
    event UpdateFeeRatio(uint256 feeRatio);
    event DistributeFee(address indexed token, uint256 indexed id, uint256 amount, uint256 blockNumber);
    event ClaimFee(address indexed token, uint256 indexed id, uint256 amount, address indexed to);

    function tokenURIRenderer() external view returns (address);

    function controller() external view returns (address);

    function ve() external view returns (address);

    function target() external view returns (address);

    function targetVersion() external view returns (uint256);

    function feeRatio() external view returns (uint256);

    function tokenWhitelisted(address token) external view returns (bool);

    function gauges(address nftContract) external view returns (address);

    function isGauge(address addr) external view returns (bool);

    function fees(address token, uint256 id) external view returns (uint128 blockNumber, uint128 amountPerShare);

    function feesClaimed(
        address token,
        uint256 id,
        address user
    ) external view returns (bool);

    function upgradeTarget(address target) external;

    function whitelistToken(address token) external;

    function updateFeeRatio(uint256 feeRatio) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address token,
        address from,
        uint256 amount
    ) external;

    function distributeFee(address token, uint256 amount) external returns (uint256 amountFee);

    function claimFees(address token, uint256[] calldata ids) external;
}
