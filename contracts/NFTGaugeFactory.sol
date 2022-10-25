// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./base/CloneFactory.sol";
import "./interfaces/INFTGaugeFactory.sol";
import "./libraries/Integers.sol";
import "./NFTGauge.sol";

contract NFTGaugeFactory is CloneFactory, Ownable, INFTGaugeFactory {
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

    function updateCurrencyWhitelisted(address token, bool whitelisted) external override onlyOwner {
        currencyWhitelisted[token] = whitelisted;

        emit UpdateCurrencyWhitelisted(token, whitelisted);
    }

    function updateFeeRatio(uint256 ratio) public override onlyOwner {
        require(ratio < 10000, "NFTGF: INVALID_FEE_RATIO");

        feeRatio = ratio;

        emit UpdateFeeRatio(ratio);
    }

    function updateOwnerAdvantageRatio(uint256 ratio) public override onlyOwner {
        require(ratio < 10000, "NFTGF: INVALID_FEE_RATIO");

        ownerAdvantageRatio = ratio;

        emit UpdateOwnerAdvantageRatio(ratio);
    }

    function createNFTGauge(address nftContract) external override returns (address gauge) {
        require(gauges[nftContract] == address(0), "NFTGF: GAUGE_CREATED");

        gauge = _createClone(_target);
        INFTGauge(gauge).initialize(nftContract, minter);

        gauges[nftContract] = gauge;
        isGauge[gauge] = true;

        emit CreateNFTGauge(nftContract, gauge);
    }

    function executePayment(
        address currency,
        address from,
        uint256 amount
    ) external override {
        require(isGauge[msg.sender], "NFTGF: FORBIDDEN");
        require(currencyWhitelisted[currency], "NFTGF: INVALID_TOKEN");

        IERC20(currency).safeTransferFrom(from, msg.sender, amount);
    }
}
