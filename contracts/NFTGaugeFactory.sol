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
        uint128 blockNumber;
        uint128 amountPerShare;
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
    mapping(address => mapping(uint256 => mapping(address => bool))) public override feesClaimed;

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

    function distributeFee(address token, uint256 amount) external override returns (uint256 amountFee) {
        require(isGauge[msg.sender], "NFTGF: FORBIDDEN");

        amountFee = (amount * feeRatio) / 10000;
        fees[token].push(Fee(uint128(block.number), uint128((amountFee * 1e18) / IVotingEscrow(ve).totalSupply())));

        emit DistributeFee(token, fees[token].length - 1, amountFee, block.number);
    }

    function claimFees(address token, uint256[] calldata ids) external override {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            Fee memory fee = fees[token][id];

            require(!feesClaimed[token][id][msg.sender], "NFTGF: CLAIMED");
            feesClaimed[token][id][msg.sender] = true;

            uint256 amount = (IVotingEscrow(ve).balanceOfAt(msg.sender, fee.blockNumber) * fee.amountPerShare) / 1e18;
            require(amount > 0, "NFTGF: INSUFFICIENT_AMOUNT");
            Tokens.transfer(token, msg.sender, amount);

            emit ClaimFee(token, id, amount, msg.sender);
        }
    }
}
