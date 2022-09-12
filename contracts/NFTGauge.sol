// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/ICurrencyConverter.sol";
import "./libraries/Tokens.sol";
import "./libraries/Math.sol";
import "./libraries/NFTs.sol";

contract NFTGauge is WrappedERC721, INFTGauge {
    struct Dividend {
        uint64 timestamp;
        uint192 value;
    }

    struct VotedSlope {
        uint256 slope;
        uint256 power;
        uint256 end;
    }

    address public override minter;
    address public override controller;
    address public override votingEscrow;
    uint256 public override futureEpochTime;

    mapping(uint256 => uint256) public override dividendRatios;
    mapping(address => mapping(uint256 => Dividend[])) public override dividends; // currency -> tokenId -> Snapshot
    mapping(address => mapping(uint256 => mapping(address => uint256))) public override lastDividendClaimed; // currency -> tokenId -> user -> index

    int128 public override period;
    mapping(int128 => uint256) public override periodTimestamp;
    mapping(int128 => uint256) public override integrateInvSupply; // bump epoch when rate() changes

    mapping(uint256 => mapping(address => int128)) public override periodOf; // tokenId -> user -> period
    mapping(uint256 => mapping(address => uint256)) public override integrateFraction; // tokenId -> user -> fraction

    mapping(uint256 => mapping(address => VotedSlope)) public override voteUserSlopes; // user -> tokenId -> VotedSlope
    mapping(address => uint256) public override voteUserPower; // Total vote power used by user

    uint256 public override inflationRate;

    bool public override isKilled;

    uint256 internal _interval;

    function initialize(address _nftContract, address _minter) external override initializer {
        __WrappedERC721_init(_nftContract);

        minter = _minter;
        address _controller = IMinter(_minter).controller();
        controller = _controller;
        votingEscrow = IGaugeController(_controller).votingEscrow();
        periodTimestamp[0] = block.timestamp;
        inflationRate = IMinter(_minter).rate();
        futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
        _interval = IGaugeController(_controller).interval();
    }

    function integrateCheckpoint() external view override returns (uint256) {
        return periodTimestamp[period];
    }

    function dividendsLength(address token, uint256 tokenId) external view override returns (uint256) {
        return dividends[token][tokenId].length;
    }

    /**
     * @notice Toggle the killed status of the gauge
     */
    function killMe() external override {
        require(msg.sender == controller, "NFTG: FORBIDDDEN");
        isKilled = !isKilled;
    }

    function _checkpoint() internal returns (int128 _period, uint256 _integrateInvSupply) {
        address _minter = minter;
        address _controller = controller;
        _period = period;
        uint256 _periodTime = periodTimestamp[_period];
        _integrateInvSupply = integrateInvSupply[_period];
        uint256 rate = inflationRate;
        uint256 newRate = rate;
        uint256 prevFutureEpoch = futureEpochTime;
        if (prevFutureEpoch >= _periodTime) {
            futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
            newRate = IMinter(_minter).rate();
            inflationRate = newRate;
        }
        IGaugeController(_controller).checkpointGauge(address(this));

        if (isKilled) rate = 0; // Stop distributing inflation as soon as killed

        // Update integral of 1/total
        if (block.timestamp > _periodTime) {
            uint256 interval = _interval;
            uint256 prevTime = _periodTime;
            uint256 weekTime = Math.min(((_periodTime + interval) / interval) * interval, block.timestamp);
            for (uint256 i; i < 500; ) {
                uint256 prevWeekTime = (prevTime / interval) * interval;
                uint256 w = IGaugeController(_controller).gaugeRelativeWeight(address(this), prevWeekTime);
                (uint256 total, ) = IGaugeController(_controller).pointsWeight(address(this), prevWeekTime);

                uint256 dt = weekTime - prevTime;
                if (total > 0) {
                    if (prevFutureEpoch >= prevTime && prevFutureEpoch < weekTime) {
                        // If we went across one or multiple epochs, apply the rate
                        // of the first epoch until it ends, and then the rate of
                        // the last epoch.
                        // If more than one epoch is crossed - the gauge gets less,
                        // but that'd meen it wasn't called for more than 1 year
                        _integrateInvSupply += (rate * w * (prevFutureEpoch - prevTime)) / total;
                        rate = newRate;
                        _integrateInvSupply += (rate * w * (weekTime - prevFutureEpoch)) / total;
                    } else {
                        _integrateInvSupply += (rate * w * dt) / total;
                    }
                }

                if (weekTime == block.timestamp) break;
                prevTime = weekTime;
                weekTime = Math.min(weekTime + interval, block.timestamp);

                unchecked {
                    ++i;
                }
            }
        }

        ++_period;
        period = _period;
        periodTimestamp[_period] = block.timestamp;
        integrateInvSupply[_period] = _integrateInvSupply;
    }

    /**
     * @notice Checkpoint for a user for a specific token
     * @param tokenId Token Id
     * @param user User address
     */
    function userCheckpoint(uint256 tokenId, address user) public override {
        require(msg.sender == user || user == minter, "NFTG: FORBIDDEN");
        (int128 _period, uint256 _integrateInvSupply) = _checkpoint();

        // Update user-specific integrals
        int128 checkpoint = periodOf[tokenId][user];
        uint256 oldIntegrateInvSupply = integrateInvSupply[checkpoint];
        uint256 dIntegrate = _integrateInvSupply - oldIntegrateInvSupply;
        if (dIntegrate > 0) {
            VotedSlope memory slope = voteUserSlopes[tokenId][user];
            uint256 ts = periodTimestamp[checkpoint];
            if (ts >= slope.end) {
                uint256 bias;
                if (block.timestamp < slope.end) {
                    bias = (slope.slope * (block.timestamp - ts)) / 2; // average value from ts to now
                } else {
                    bias = (slope.slope * (slope.end - ts)) / 2; // average value from ts to lockEnd
                }
                integrateFraction[tokenId][user] += (bias * dIntegrate * 2) / 3 / 1e18; // 67% goes to voters
                integrateFraction[tokenId][ownerOf(tokenId)] += (bias * dIntegrate) / 3 / 1e18; // 33% goes to the owner
            }
        }
        periodOf[tokenId][user] = _period;
    }

    /**
     * @notice Mint a wrapped NFT and commit gauge voting to this tokenId
     * @param tokenId Token Id to deposit
     * @param dividendRatio Dividend ratio for the voters in bps (units of 0.01%)
     * @param to The owner of the newly minted wrapped NFT
     * @param userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function wrap(
        uint256 tokenId,
        uint256 dividendRatio,
        address to,
        uint256 userWeight
    ) public override {
        require(dividendRatio <= 10000, "NFTG: INVALID_RATIO");

        dividendRatios[tokenId] = dividendRatio;

        _mint(to, tokenId);

        vote(tokenId, userWeight);

        emit Wrap(tokenId, to);

        NFTs.safeTransferFrom(nftContract, msg.sender, address(this), tokenId);
    }

    function unwrap(uint256 tokenId, address to) public override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        dividendRatios[tokenId] = 0;

        _burn(tokenId);

        revoke(tokenId);

        emit Unwrap(tokenId, to);

        NFTs.safeTransferFrom(nftContract, address(this), to, tokenId);
    }

    function vote(uint256 tokenId, uint256 userWeight) public override {
        require(_exists(tokenId), "NFTG: NON_EXISTENT");

        userCheckpoint(tokenId, msg.sender);

        address escrow = votingEscrow;
        uint256 slope = uint256(uint128(IVotingEscrow(escrow).getLastUserSlope(msg.sender)));
        uint256 lockEnd = IVotingEscrow(escrow).unlockTime(msg.sender);

        uint256 powerUsed = _updateSlopes(tokenId, msg.sender, slope, lockEnd, userWeight);
        IGaugeController(controller).voteForGaugeWeights(msg.sender, powerUsed);

        emit Vote(tokenId, msg.sender, userWeight);
    }

    function revoke(uint256 tokenId) public override {
        require(!_exists(tokenId), "NFTG: EXISTENT");

        userCheckpoint(tokenId, msg.sender);

        uint256 powerUsed = _updateSlopes(tokenId, msg.sender, 0, 0, 0);
        IGaugeController(controller).voteForGaugeWeights(msg.sender, powerUsed);

        emit Vote(tokenId, msg.sender, 0);
    }

    function claimDividends(address token, uint256 tokenId) external override {
        uint256 amount;
        uint256 last = lastDividendClaimed[token][tokenId][msg.sender];
        uint256 i;
        while (i < 500) {
            uint256 id = last + i;
            if (id >= dividends[token][tokenId].length) break;

            Dividend memory dividend = dividends[token][tokenId][id];
            // TODO: sum up amount

            unchecked {
                ++i;
            }
        }

        require(i > 0, "NFTG: NO_AMOUNT_TO_CLAIM");
        lastDividendClaimed[token][tokenId][msg.sender] = last + i;

        emit ClaimDividends(token, tokenId, amount, msg.sender);
        Tokens.transfer(token, msg.sender, amount);
    }

    function _updateSlopes(
        uint256 tokenId,
        address user,
        uint256 slope,
        uint256 lockEnd,
        uint256 userWeight
    ) internal returns (uint256 powerUsed) {
        uint256 interval = _interval;
        uint256 nextTime = ((block.timestamp + interval) / interval) * interval;

        // Prepare slopes and biases in memory
        VotedSlope memory oldSlope = voteUserSlopes[tokenId][user];
        VotedSlope memory newSlope = VotedSlope({slope: (slope * userWeight) / 10000, end: lockEnd, power: userWeight});

        // Check and update powers (weights) used
        powerUsed = voteUserPower[user] + newSlope.power - oldSlope.power;
        voteUserPower[user] = powerUsed;
        voteUserSlopes[tokenId][user] = newSlope;
    }

    function _settle(
        uint256 tokenId,
        address currency,
        address to,
        uint256 amount
    ) internal override {
        address _factory = factory;
        address converter = INFTGaugeFactory(_factory).currencyConverter(currency);
        uint256 amountETH = ICurrencyConverter(converter).getAmountETH(amount);
        if (amountETH >= 1e18) {
            IGaugeController(controller).increaseGaugeWeight(amountETH / 1e18);
        }

        uint256 fee;
        if (currency == address(0)) {
            fee = INFTGaugeFactory(_factory).distributeFeesETH{value: amount}();
        } else {
            fee = INFTGaugeFactory(_factory).distributeFees(currency, amount);
        }

        uint256 dividend;
        uint256 sum; // TODO: get the sum of shares
        if (sum > 0) {
            dividend = ((amount - fee) * dividendRatios[tokenId]) / 10000;
            // TODO: add a dividend
            emit DistributeDividend(currency, tokenId, dividend);
        }
        Tokens.transfer(currency, to, amount - fee - dividend);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        super._beforeTokenTransfer(from, to, tokenId);

        userCheckpoint(tokenId, from);
    }
}
