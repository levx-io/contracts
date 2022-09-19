// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./base/CloneFactory.sol";
import "./interfaces/INFTGaugeFactory.sol";
import "./libraries/Integers.sol";
import "./libraries/Tokens.sol";
import "./libraries/VotingEscrowHelper.sol";
import "./NFTGauge.sol";

contract NFTGaugeFactory is CloneFactory, Ownable, INFTGaugeFactory {
    using SafeERC20 for IERC20;
    using Integers for int128;
    using Integers for uint256;

    struct Fee {
        uint64 timestamp;
        uint192 amountPerShare;
    }

    address public immutable override weth;
    address public immutable override minter;
    address public immutable override votingEscrow;
    address public immutable override discountToken;

    address public _target;

    uint256 public override feeRatio;
    mapping(address => address) public override currencyConverter;
    mapping(address => address) public override gauges;
    mapping(address => bool) public override isGauge;

    mapping(address => Fee[]) public override fees;
    mapping(address => mapping(address => uint256)) public override lastFeeClaimed;

    constructor(
        address _weth,
        address _minter,
        address _discountToken,
        uint256 _feeRatio
    ) {
        weth = _weth;
        minter = _minter;
        address _controller = IMinter(_minter).controller();
        votingEscrow = IGaugeController(_controller).votingEscrow();
        discountToken = _discountToken;
        updateFeeRatio(_feeRatio);

        NFTGauge gauge = new NFTGauge();
        gauge.initialize(_controller, address(0));
        _target = address(gauge);
    }

    function feesLength(address token) external view override returns (uint256) {
        return fees[token].length;
    }

    /**
     * @notice Toggle the killed status of the gauge
     * @param addr Gauge address
     */
    function killGauge(address addr) external override onlyOwner {
        NFTGauge(addr).killMe();
    }

    function updateCurrencyConverter(address token, address converter) external override onlyOwner {
        currencyConverter[token] = converter;

        emit UpdateCurrencyConverter(token, converter);
    }

    function updateFeeRatio(uint256 _feeRatio) public override onlyOwner {
        require(_feeRatio < 10000, "NFTGF: INVALID_FEE_RATIO");

        feeRatio = _feeRatio;

        emit UpdateFeeRatio(_feeRatio);
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
        require(currencyConverter[currency] != address(0), "NFTGF: INVALID_TOKEN");

        IERC20(currency).safeTransferFrom(from, msg.sender, amount);
    }

    function distributeFeesETH() external payable override returns (uint256 amountFee) {
        amountFee = (msg.value * feeRatio) / 10000;
        _distributeFees(address(0), amountFee);
    }

    function distributeFees(address token, uint256 amount) external override returns (uint256 amountFee) {
        amountFee = (amount * feeRatio) / 10000;
        if (token == discountToken) {
            amountFee /= 2;
        }
        _distributeFees(token, amountFee);
    }

    function _distributeFees(address token, uint256 amount) internal {
        require(isGauge[msg.sender], "NFTGF: FORBIDDEN");

        address escrow = votingEscrow;
        IVotingEscrow(escrow).checkpoint();
        fees[token].push(Fee(uint64(block.timestamp), uint192((amount * 1e18) / IVotingEscrow(escrow).totalSupply())));

        emit DistributeFees(token, fees[token].length - 1, amount);
    }

    /**
     * @notice Claim accumulated fees
     * @param token In which currency fees were paid
     * @param to the last index of the fee (exclusive)
     */
    function claimFees(address token, uint256 to) external override {
        uint256 from = lastFeeClaimed[token][msg.sender];

        address escrow = votingEscrow;
        (int128 value, , uint256 start, ) = IVotingEscrow(escrow).locked(msg.sender);
        require(value > 0, "NFTGF: LOCK_NOT_FOUND");

        uint256 amount;
        for (uint256 i = from; i < to; ) {
            Fee memory fee = fees[token][i];
            if (start <= fee.timestamp) {
                uint256 balance = VotingEscrowHelper.balanceOf(escrow, msg.sender, fee.timestamp);
                if (balance > 0) amount += (balance * fee.amountPerShare) / 1e18;
            }
            unchecked {
                ++i;
            }
        }
        lastFeeClaimed[token][msg.sender] = to;

        emit ClaimFees(token, amount, msg.sender);
        Tokens.safeTransfer(token, msg.sender, amount, weth);
    }
}
