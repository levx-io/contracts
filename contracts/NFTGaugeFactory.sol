// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./base/CloneFactory.sol";
import "./base/Base.sol";
import "./interfaces/INFTGaugeFactory.sol";
import "./libraries/Integers.sol";
import "./NFTGauge.sol";

/**
 * @title Factory for creating gauges that wrap NFTs
 * @author LevX (team@levx.io)
 */
contract NFTGaugeFactory is CloneFactory, Ownable, Base, INFTGaugeFactory {
    using SafeERC20 for IERC20;

    address public immutable override weth;
    address public immutable override minter;
    address public immutable override votingEscrow;
    address public immutable override discountToken;
    address public immutable override feeVault;
    address public immutable override dividendVault;

    address public _target;

    uint256 public override feeRatio;
    uint256 public override ownerAdvantageRatio;
    mapping(address => bool) public override currencyWhitelisted;
    mapping(address => address) public override gauges;
    mapping(address => bool) public override isGauge;

    constructor(
        address _weth,
        address _minter,
        address _discountToken,
        address _feeVault,
        address _dividendVault,
        uint256 _feeRatio,
        uint256 _ownerAdvantageRatio
    ) {
        weth = _weth;
        minter = _minter;
        address _controller = IMinter(_minter).controller();
        votingEscrow = IGaugeController(_controller).votingEscrow();
        discountToken = _discountToken;
        feeVault = _feeVault;
        dividendVault = _dividendVault;
        feeRatio = _feeRatio;
        ownerAdvantageRatio = _ownerAdvantageRatio;

        NFTGauge gauge = new NFTGauge();
        gauge.initialize(_controller, address(0));
        _target = address(gauge);

        emit UpdateFeeRatio(_feeRatio);
        emit UpdateOwnerAdvantageRatio(_ownerAdvantageRatio);
    }

    receive() external payable {
        // Empty
    }

    function revertIfInvalidFeeRatio(bool success) internal pure {
        if (!success) revert InvalidFeeRatio();
    }

    function revertIfInvalidOwnerAdvantageRatio(bool success) internal pure {
        if (!success) revert InvalidOwnerAdvantageRatio();
    }

    function revertIfNonWhitelistedCurrency(bool success) internal pure {
        if (!success) revert NonWhitelistedCurrency();
    }

    /**
     * @notice Calculate fee to be paid
     * @param token In which token the fee will be paid
     * @param amount Entire amount of the trade
     */
    function calculateFee(address token, uint256 amount) external view returns (uint256 fee) {
        fee = (amount * feeRatio) / 10000;
        if (token == discountToken) {
            fee /= 2;
        }
    }

    /**
     * @notice Toggle the killed status of the gauge
     * @param addr Gauge address
     */
    function killGauge(address addr) external override onlyOwner {
        NFTGauge(addr).killMe();
    }

    /**
     * @notice Update whether to whitelist `token` or not
     * @param token Token contract address
     * @param whitelisted To whitelist it or not
     */
    function updateCurrencyWhitelisted(address token, bool whitelisted) external override onlyOwner {
        currencyWhitelisted[token] = whitelisted;

        emit UpdateCurrencyWhitelisted(token, whitelisted);
    }

    /**
     * @notice Update fee ratio (Fee is charged for every trade)
     * @param ratio New ratio
     */
    function updateFeeRatio(uint256 ratio) public override onlyOwner {
        revertIfInvalidFeeRatio(ratio < 10000);

        feeRatio = ratio;

        emit UpdateFeeRatio(ratio);
    }

    /**
     * @notice Update owner advantage ratio (Owner advantage goes to the owner of the NFT out of the emissions)
     * @param ratio New ratio
     */
    function updateOwnerAdvantageRatio(uint256 ratio) public override onlyOwner {
        revertIfInvalidOwnerAdvantageRatio(ratio < 10000);

        ownerAdvantageRatio = ratio;

        emit UpdateOwnerAdvantageRatio(ratio);
    }

    /**
     * @notice Create a new gauge that wraps `nftContract`
     * @param nftContract NFT contract address
     */
    function createNFTGauge(address nftContract) external override returns (address gauge) {
        revertIfExistent(gauges[nftContract] == address(0));

        gauge = _createClone(_target);
        INFTGauge(gauge).initialize(nftContract, minter);

        gauges[nftContract] = gauge;
        isGauge[gauge] = true;

        emit CreateNFTGauge(nftContract, gauge);
    }

    /**
     * @notice Transfer `amount` of `currency` from `from` to the caller
     * @dev Caller must be a gauge
     * @param currency Token address
     */
    function executePayment(
        address currency,
        address from,
        uint256 amount
    ) external override {
        revertIfForbidden(isGauge[msg.sender]);
        revertIfNonWhitelistedCurrency(currencyWhitelisted[currency]);

        IERC20(currency).safeTransferFrom(from, msg.sender, amount);
    }
}
