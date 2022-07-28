// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./base/CloneFactory.sol";
import "./interfaces/INFTGaugeFactory.sol";
import "./libraries/Tokens.sol";
import "./NFTGauge.sol";

contract NFTGaugeFactory is CloneFactory, Ownable, INFTGaugeFactory {
    using SafeERC20 for IERC20;

    struct Fee {
        uint64 timestamp;
        uint192 amountPerShare;
    }

    address public immutable override tokenURIRenderer;
    address public immutable override controller;
    address public immutable override ve;

    address public override target;
    uint256 public override targetVersion;

    uint256 public override feeRatio;
    mapping(address => bool) public override tokenWhitelisted;
    mapping(address => address) public override gauges;
    mapping(address => bool) public override isGauge;

    mapping(address => Fee[]) public override fees;
    mapping(address => mapping(address => uint256)) public override feesClaimed;

    constructor(
        address _tokenURIRenderer,
        address _controller,
        uint256 _feeRatio
    ) {
        tokenURIRenderer = _tokenURIRenderer;
        controller = _controller;
        ve = IGaugeController(_controller).votingEscrow();
        feeRatio = _feeRatio;

        emit UpdateFeeRatio(_feeRatio);

        NFTGauge gauge = new NFTGauge();
        gauge.initialize(address(0), address(0), address(0));
        target = address(gauge);
    }

    function upgradeTarget(address _target) external override onlyOwner {
        target = _target;

        uint256 version = targetVersion + 1;
        targetVersion = version;

        emit UpgradeTarget(_target, version);
    }

    function whitelistToken(address token) external override onlyOwner {
        tokenWhitelisted[token] = true;

        emit WhitelistToken(token);
    }

    function updateFeeRatio(uint256 _feeRatio) external override onlyOwner {
        feeRatio = _feeRatio;

        emit UpdateFeeRatio(_feeRatio);
    }

    function createNFTGauge(address nftContract) external override returns (address gauge) {
        require(gauges[nftContract] == address(0), "NFTGF: GAUGE_CREATED");

        gauge = _createClone(target);
        INFTGauge(gauge).initialize(nftContract, tokenURIRenderer, controller);

        gauges[nftContract] = gauge;
        isGauge[gauge] = true;

        emit CreateNFTGauge(nftContract, gauge);
    }

    function executePayment(
        address token,
        address from,
        uint256 amount
    ) external override {
        require(isGauge[msg.sender], "NFTGF: FORBIDDEN");
        require(tokenWhitelisted[token], "NFTGF: TOKEN_NOT_WHITELIST");

        IERC20(token).safeTransferFrom(from, msg.sender, amount);
    }

    function distributeFeesETH() external payable override returns (uint256 amountFee) {
        amountFee = (msg.value * feeRatio) / 10000;
        _distributeFees(address(0), amountFee);
    }

    function distributeFees(address token, uint256 amount) external override returns (uint256 amountFee) {
        amountFee = (amount * feeRatio) / 10000;
        _distributeFees(token, amountFee);
    }

    function _distributeFees(address token, uint256 amount) internal {
        require(isGauge[msg.sender], "NFTGF: FORBIDDEN");

        fees[token].push(Fee(uint64(block.timestamp), uint192((amount * 1e18) / IVotingEscrow(ve).totalSupply())));

        emit DistributeFees(token, fees[token].length - 1, amount);
    }

    function claimFees(
        address token,
        uint256 from,
        uint256 to
    ) external override {
        (int128 value, , uint256 start, uint256 end) = IVotingEscrow(ve).locked(msg.sender);
        require(value > 0, "NFTGF: LOCK_NOT_FOUND");
        require(block.timestamp < end, "NFTGF: LOCK_EXPIRED");

        uint256 i = from;
        uint256 claimed = feesClaimed[token][msg.sender];
        if (i <= claimed) i = claimed + 1;

        while (i <= to) {
            Fee memory fee = fees[token][i];
            require(start <= fee.timestamp, "NFTGF: INVALID_FROM");
            require(fee.timestamp <= end, "NFTGF: INVALID_TO");

            uint256 amount = (IVotingEscrow(ve).balanceOf(msg.sender, fee.timestamp) * uint256(fee.amountPerShare)) /
                1e18;
            if (amount > 0) {
                Tokens.transfer(token, msg.sender, amount);
                emit ClaimFees(token, i, amount, msg.sender);
            }
            unchecked {
                ++i;
            }
        }
        feesClaimed[token][msg.sender] = to;
    }
}
