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

    struct Dividend {
        uint128 blockNumber;
        uint128 amount;
        address token;
        uint256 total;
    }

    address public immutable override tokenURIRenderer;
    address public immutable override controller;
    address public immutable override ve;

    address public override target;
    uint256 public override targetVersion;

    uint256 public override fee;
    mapping(address => bool) public override tokenWhitelisted;
    mapping(address => address) public override gauges;
    mapping(address => bool) public override isGauge;

    Dividend[] public override dividends;
    mapping(uint256 => mapping(address => bool)) public override dividendsClaimed;

    constructor(
        address _tokenURIRenderer,
        address _controller,
        uint256 _fee
    ) {
        tokenURIRenderer = _tokenURIRenderer;
        controller = _controller;
        ve = IGaugeController(_controller).votingEscrow();
        fee = _fee;

        emit UpdateFee(_fee);

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

    function updateFee(uint256 _fee) external override onlyOwner {
        fee = _fee;

        emit UpdateFee(_fee);
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

    function addDividend(address token, uint256 amount) external override returns (uint256 amountFee) {
        require(isGauge[msg.sender], "NFTGF: FORBIDDEN");

        amountFee = amount * fee;
        dividends.push(Dividend(uint128(block.timestamp), uint128(amountFee), token, IVotingEscrow(ve).totalSupply()));
        emit AddDividend(token, amount);
    }

    function claimDividends(uint256[] calldata ids) external override {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            require(!dividendsClaimed[id][msg.sender], "NFTGF: CLAIMED");
            dividendsClaimed[id][msg.sender] = true;

            Dividend memory dividend = dividends[id];
            uint256 amount = (dividend.amount * IVotingEscrow(ve).balanceOfAt(msg.sender, dividend.blockNumber)) /
                dividend.total;
            require(amount > 0, "NFTGF: INSUFFICIENT_AMOUNT");
            Tokens.transfer(dividend.token, msg.sender, amount);

            emit ClaimDividend(id, msg.sender, dividend.token, amount);
        }
    }
}
