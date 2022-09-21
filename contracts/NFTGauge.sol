// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/ICurrencyConverter.sol";
import "./libraries/Tokens.sol";
import "./libraries/Math.sol";
import "./libraries/NFTs.sol";
import "./libraries/VotingEscrowHelper.sol";
import "./libraries/Errors.sol";

contract NFTGauge is WrappedERC721, INFTGauge {
    struct Dividend {
        uint64 timestamp;
        uint192 amountPerShare;
    }

    struct Point {
        uint256 bias;
        uint256 slope;
    }

    struct VotedSlope {
        uint256 slope;
        uint256 power;
        uint64 end;
        uint64 timestamp;
    }

    struct Wrap_ {
        uint128 dividendRatio;
        uint64 start;
        uint64 end;
    }

    address public override minter;
    address public override controller;
    address public override votingEscrow;

    mapping(uint256 => Wrap_[]) internal _wraps;
    mapping(address => mapping(uint256 => Dividend[])) internal _dividends; // currency -> tokenId -> Dividend
    mapping(address => mapping(uint256 => mapping(address => uint256))) internal _lastDividendClaimed; // currency -> tokenId -> user -> index

    int128 public override period;
    mapping(int128 => uint256) public override periodTimestamp;
    mapping(int128 => uint256) public override integrateInvSupply; // bump epoch when rate() changes

    mapping(uint256 => mapping(address => int128)) public override periodOf; // tokenId -> user -> period
    mapping(uint256 => mapping(address => uint256)) public override integrateFraction; // tokenId -> user -> fraction

    mapping(uint256 => mapping(uint256 => Point)) public override pointsSum; // tokenId -> time -> Point
    mapping(uint256 => mapping(uint256 => uint256)) internal _changesSum; // tokenId -> time -> slope
    mapping(uint256 => uint256) public override timeSum; // tokenId -> last scheduled time (next week)

    mapping(uint256 => mapping(address => VotedSlope[])) public override voteUserSlopes; // tokenId -> user -> VotedSlopes
    mapping(address => uint256) public override voteUserPower; // Total vote power used by user
    mapping(uint256 => mapping(address => uint256)) public override lastUserVote; // Last user vote's timestamp

    bool public override isKilled;

    uint256 internal _futureEpochTime;
    uint256 internal _inflationRate;
    uint256 internal _interval;
    uint256 internal _weightVoteDelay;

    function initialize(address _nftContract, address _minter) external override initializer {
        __WrappedERC721_init(_nftContract);

        minter = _minter;
        address _controller = IMinter(_minter).controller();
        controller = _controller;
        votingEscrow = IGaugeController(_controller).votingEscrow();
        periodTimestamp[0] = block.timestamp;
        _inflationRate = IMinter(_minter).rate();
        _futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
        _interval = IGaugeController(_controller).interval();
        _weightVoteDelay = IGaugeController(_controller).weightVoteDelay();
    }

    function integrateCheckpoint() external view override returns (uint256) {
        return periodTimestamp[period];
    }

    function voteUserSlopesLength(uint256 tokenId, address user) external view override returns (uint256) {
        return voteUserSlopes[tokenId][user].length;
    }

    /**
     * @notice Toggle the killed status of the gauge
     */
    function killMe() external override {
        revertIfForbidden(msg.sender == factory);
        isKilled = !isKilled;
    }

    function _checkpoint() internal returns (int128 _period, uint256 _integrateInvSupply) {
        address _minter = minter;
        address _controller = controller;
        _period = period;
        uint256 _periodTime = periodTimestamp[_period];
        _integrateInvSupply = integrateInvSupply[_period];
        uint256 rate = _inflationRate;
        uint256 newRate = rate;
        uint256 prevFutureEpoch = _futureEpochTime;
        if (prevFutureEpoch >= _periodTime) {
            _futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
            newRate = IMinter(_minter).rate();
            _inflationRate = newRate;
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
        revertIfForbidden(msg.sender == user || user == minter);

        (int128 _period, uint256 _integrateInvSupply) = _checkpoint();

        // Update user-specific integrals
        int128 checkpoint = periodOf[tokenId][user];
        uint256 oldIntegrateInvSupply = integrateInvSupply[checkpoint];
        uint256 dIntegrate = _integrateInvSupply - oldIntegrateInvSupply;
        if (dIntegrate > 0) {
            VotedSlope memory slope = _lastValue(voteUserSlopes[tokenId][user]);
            uint256 ts = periodTimestamp[checkpoint];
            if (ts <= slope.end) {
                uint256 bias;
                if (block.timestamp < slope.end) {
                    bias = (slope.slope * (2 * slope.end - ts - block.timestamp)) / 2; // average value from ts to now
                } else {
                    bias = (slope.slope * (slope.end - ts)) / 2; // average value from ts to lockEnd
                }

                uint256 time = block.timestamp - ts;
                uint256 wrapped;
                uint256 length = _wraps[tokenId].length;
                for (uint256 i; i < 500 && i < length; ) {
                    Wrap_ memory _wrap = _wraps[tokenId][length - i - 1];
                    (uint256 start, uint256 end) = (_wrap.start, _wrap.end);
                    if (end == 0) end = block.timestamp;
                    if (start < ts) {
                        wrapped += (end - ts);
                        break;
                    } else wrapped += (end - start);

                    unchecked {
                        ++i;
                    }
                }

                integrateFraction[tokenId][user] += (bias * dIntegrate * wrapped * 2) / time / 3 / 1e18; // 67% goes to voters
                integrateFraction[tokenId][ownerOf(tokenId)] += (bias * dIntegrate * wrapped) / time / 3 / 1e18; // 33% goes to the owner
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
    ) external override {
        revertIfInvalidDividendRatio(dividendRatio <= 10000);

        _wraps[tokenId].push(Wrap_(uint128(dividendRatio), uint64(block.timestamp), 0));

        _mint(to, tokenId);

        if (timeSum[tokenId] == 0) {
            uint256 interval = _interval;
            timeSum[tokenId] = ((block.timestamp + interval) / interval) * interval;
        }
        vote(tokenId, userWeight);

        emit Wrap(tokenId, to);

        NFTs.transferFrom(nftContract, msg.sender, address(this), tokenId);
    }

    function unwrap(uint256 tokenId, address to) external override {
        revertIfForbidden(ownerOf(tokenId) == msg.sender);

        _wraps[tokenId][_wraps[tokenId].length - 1].end = uint64(block.timestamp);

        _burn(tokenId);

        revoke(tokenId);

        emit Unwrap(tokenId, to);

        NFTs.transferFrom(nftContract, address(this), to, tokenId);
    }

    function vote(uint256 tokenId, uint256 userWeight) public override {
        revertIfNonExistent(_exists(tokenId));
        revertIfVotedTooEarly(block.timestamp >= lastUserVote[tokenId][msg.sender] + _weightVoteDelay);

        userCheckpoint(tokenId, msg.sender);

        address escrow = votingEscrow;
        uint256 slope = uint256(uint128(IVotingEscrow(escrow).getLastUserSlope(msg.sender)));
        uint256 lockEnd = IVotingEscrow(escrow).unlockTime(msg.sender);

        uint256 powerUsed = _updateSlopes(tokenId, msg.sender, slope, lockEnd, userWeight);
        IGaugeController(controller).voteForGaugeWeights(msg.sender, powerUsed);

        // Record last action time
        lastUserVote[tokenId][msg.sender] = block.timestamp;

        emit Vote(tokenId, msg.sender, userWeight);
    }

    function revoke(uint256 tokenId) public override {
        revertIfExistent(!_exists(tokenId));
        revertIfVotedTooEarly(block.timestamp >= lastUserVote[tokenId][msg.sender] + _weightVoteDelay);

        userCheckpoint(tokenId, msg.sender);

        uint256 powerUsed = _updateSlopes(tokenId, msg.sender, 0, 0, 0);
        IGaugeController(controller).voteForGaugeWeights(msg.sender, powerUsed);

        // Record last action time
        lastUserVote[tokenId][msg.sender] = block.timestamp;

        emit Vote(tokenId, msg.sender, 0);
    }

    function claimDividends(
        address token,
        uint256 tokenId,
        uint256 to
    ) external override {
        require(to < _dividends[token][tokenId].length, "NFTGF: INDEX_OUT_OF_RANGE");

        uint256 from = _lastDividendClaimed[token][tokenId][msg.sender];

        uint256 amount;
        for (uint256 i = from; i < to; ) {
            Dividend memory dividend = _dividends[token][tokenId][i];
            uint256 balance = VotingEscrowHelper.balanceOf(votingEscrow, msg.sender, dividend.timestamp);
            if (balance > 0) {
                uint256 userWeight = _getValueAt(voteUserSlopes[tokenId][msg.sender], dividend.timestamp).power;
                amount += (balance * userWeight * dividend.amountPerShare) / 10000 / 1e18;
            }
            unchecked {
                ++i;
            }
        }
        _lastDividendClaimed[token][tokenId][msg.sender] = to;

        emit ClaimDividends(token, tokenId, amount, msg.sender);
        Tokens.safeTransfer(token, msg.sender, amount, _weth);
    }

    /**
     * @dev `_getValueAt` retrieves VotedSlope at a given time
     * @param snapshots The history of values being queried
     * @param timestamp The block timestamp to retrieve the value at
     * @return VotedSlope at `timestamp`
     */
    function _getValueAt(VotedSlope[] storage snapshots, uint256 timestamp) internal view returns (VotedSlope memory) {
        if (snapshots.length == 0) return VotedSlope(0, 0, 0, 0);

        // Shortcut for the actual value
        VotedSlope storage last = snapshots[snapshots.length - 1];
        if (timestamp >= last.timestamp) return last;
        if (timestamp < snapshots[0].timestamp) return VotedSlope(0, 0, 0, 0);

        // Binary search of the value in the array
        uint256 min = 0;
        uint256 max = snapshots.length - 1;
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (snapshots[mid].timestamp <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return snapshots[min];
    }

    /**
     * @param snapshots The history of data being updated
     * @return the last snapshot
     */
    function _lastValue(VotedSlope[] storage snapshots) internal view returns (VotedSlope memory) {
        uint256 length = snapshots.length;
        return length > 0 ? snapshots[length - 1] : VotedSlope(0, 0, 0, 0);
    }

    function _getSum(uint256 tokenId) internal returns (uint256) {
        uint256 t = timeSum[tokenId];
        if (t > 0) {
            Point memory pt = pointsSum[tokenId][t];
            uint256 interval = _interval;
            for (uint256 i; i < 500; ) {
                if (t > block.timestamp) break;
                t += interval;
                uint256 dBias = pt.slope * interval;
                if (pt.bias > dBias) {
                    pt.bias -= dBias;
                    uint256 dSlope = _changesSum[tokenId][t];
                    pt.slope -= dSlope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                pointsSum[tokenId][t] = pt;
                if (t > block.timestamp) timeSum[tokenId] = t;

                unchecked {
                    ++i;
                }
            }
            return pt.bias;
        } else return 0;
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
        VotedSlope memory oldSlope = _lastValue(voteUserSlopes[tokenId][user]);
        uint256 oldDt;
        if (oldSlope.end > nextTime) oldDt = oldSlope.end - nextTime;
        VotedSlope memory newSlope = VotedSlope(
            (slope * userWeight) / 10000,
            userWeight,
            uint64(lockEnd),
            uint64(block.timestamp)
        );

        // Check and update powers (weights) used
        powerUsed = voteUserPower[user] + newSlope.power - oldSlope.power;
        voteUserPower[user] = powerUsed;
        voteUserSlopes[tokenId][user].push(newSlope);

        /// Remove old and schedule new slope changes
        uint256 oldBias = oldSlope.slope * oldDt;
        uint256 newBias = newSlope.slope * (lockEnd - nextTime);
        pointsSum[tokenId][nextTime].bias = Math.max(_getSum(tokenId) + newBias, oldBias) - oldBias;
        if (oldSlope.end > nextTime) {
            pointsSum[tokenId][nextTime].slope =
                Math.max(pointsSum[tokenId][nextTime].slope + newSlope.slope, oldSlope.slope) -
                oldSlope.slope;
        } else {
            pointsSum[tokenId][nextTime].slope += newSlope.slope;
        }
        if (oldSlope.end > block.timestamp) {
            // Cancel old slope changes if they still didn't happen
            _changesSum[tokenId][oldSlope.end] -= oldSlope.slope;
        }
        // Add slope changes for new slopes
        _changesSum[tokenId][newSlope.end] += newSlope.slope;
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

        uint256 fee = INFTGaugeFactory(_factory).distributeFees(currency, amount);
        Tokens.safeTransfer(currency, _factory, fee, _weth);

        uint256 dividend;
        uint256 sum = _getSum(tokenId);
        if (sum > 0) {
            uint256 interval = _interval;
            dividend = ((amount - fee) * _wraps[tokenId][_wraps[tokenId].length - 1].dividendRatio) / 10000;
            _dividends[currency][tokenId].push(
                Dividend(uint64((block.timestamp / interval) * interval), uint192((dividend * 1e18) / sum))
            );
            emit DistributeDividend(currency, tokenId, dividend);
        }
        Tokens.safeTransfer(currency, to, amount - fee - dividend, _weth);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal override {
        super._beforeTokenTransfer(from, to, tokenId);

        if (from != address(0) && to != address(0)) userCheckpoint(tokenId, from);
    }
}
