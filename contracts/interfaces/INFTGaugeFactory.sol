// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGaugeFactory {
    event UpgradeTarget(address target, uint256 indexed version);
    event WhitelistToken(address indexed token);
    event CreateNFTGauge(address indexed nftContract, address indexed gauge);
    event UpdateFee(uint256 fee);
    event AddDividend(address indexed token, uint256 amount);
    event ClaimDividend(uint256 indexed dividendId, address indexed to, address indexed token, uint256 amount);

    function tokenURIRenderer() external view returns (address);

    function controller() external view returns (address);

    function ve() external view returns (address);

    function target() external view returns (address);

    function targetVersion() external view returns (uint256);

    function fee() external view returns (uint256);

    function tokenWhitelisted(address token) external view returns (bool);

    function gauges(address nftContract) external view returns (address);

    function isGauge(address addr) external view returns (bool);

    function dividends(uint256 id)
        external
        view
        returns (
            uint128 blockNumber,
            uint128 amount,
            address currency,
            uint256 total
        );

    function dividendsClaimed(uint256 id, address user) external view returns (bool);

    function upgradeTarget(address target) external;

    function whitelistToken(address token) external;

    function updateFee(uint256 fee) external;

    function createNFTGauge(address nftContract) external returns (address gauge);

    function executePayment(
        address token,
        address from,
        uint256 amount
    ) external;

    function addDividend(address token, uint256 amount) external returns (uint256 amountFee);

    function claimDividends(uint256[] calldata ids) external;
}
