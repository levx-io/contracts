// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IVotingEscrow.sol";
import "./libraries/Tokens.sol";

function _min(uint256 a, uint256 b) pure returns (uint256) {
    if (a < b) return a;
    return b;
}

contract NFTGauge is WrappedERC721, INFTGauge {
    struct Snapshot {
        uint64 timestamp;
        uint192 value;
    }

    address public override minter;
    address public override controller;
    address public override votingEscrow;
    uint256 public override futureEpochTime;

    mapping(uint256 => uint256) public override dividendRatios;
    mapping(address => mapping(uint256 => Snapshot[])) public override dividends; // currency -> tokenId -> Snapshot
    mapping(address => mapping(uint256 => mapping(address => uint256))) public override lastDividendClaimed; // currency -> tokenId -> user -> index

    int128 public override period;
    mapping(int128 => uint256) public override periodTimestamp;
    mapping(int128 => uint256) public override integrateInvSupply; // bump epoch when rate() changes

    mapping(uint256 => mapping(address => int128)) public override periodOf; // tokenId -> user -> period
    mapping(uint256 => mapping(address => uint256)) public override integrateFraction; // tokenId -> user -> fraction

    uint256 public override inflationRate;

    bool public override isKilled;

    uint256 internal _interval;

    mapping(uint256 => mapping(address => Snapshot[])) internal _points;
    mapping(uint256 => Snapshot[]) internal _pointsSum;
    Snapshot[] internal _pointsTotal;

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _minter
    ) external override initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);

        minter = _minter;
        address _controller = IMinter(_minter).controller();
        controller = _controller;
        votingEscrow = IGaugeController(_controller).votingEscrow();
        periodTimestamp[0] = block.timestamp;
        inflationRate = IMinter(_minter).rate();
        futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
        _interval = IGaugeController(_controller).interval();
    }

    function points(uint256 tokenId, address user) public view override returns (uint256) {
        return _lastValue(_points[tokenId][user]);
    }

    function pointsAt(
        uint256 tokenId,
        address user,
        uint256 timestamp
    ) public view override returns (uint256) {
        return _getValueAt(_points[tokenId][user], timestamp);
    }

    function pointsSum(uint256 tokenId) external view override returns (uint256) {
        return _lastValue(_pointsSum[tokenId]);
    }

    function pointsSumAt(uint256 tokenId, uint256 timestamp) public view override returns (uint256) {
        return _getValueAt(_pointsSum[tokenId], timestamp);
    }

    function pointsTotal() external view override returns (uint256) {
        return _lastValue(_pointsTotal);
    }

    function pointsTotalAt(uint256 timestamp) external view override returns (uint256) {
        return _getValueAt(_pointsTotal, timestamp);
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

        uint256 total = _lastValue(_pointsTotal);

        if (isKilled) rate = 0; // Stop distributing inflation as soon as killed

        // Update integral of 1/total
        if (block.timestamp > _periodTime) {
            uint256 interval = _interval;
            uint256 prevWeekTime = _periodTime;
            uint256 weekTime = _min(((_periodTime + interval) / interval) * interval, block.timestamp);
            for (uint256 i; i < 250; ) {
                uint256 dt = weekTime - prevWeekTime;
                uint256 w = IGaugeController(_controller).gaugeRelativeWeight(
                    address(this),
                    (prevWeekTime / interval) * interval
                );

                if (total > 0) {
                    if (prevFutureEpoch >= prevWeekTime && prevFutureEpoch < weekTime) {
                        // If we went across one or multiple epochs, apply the rate
                        // of the first epoch until it ends, and then the rate of
                        // the last epoch.
                        // If more than one epoch is crossed - the gauge gets less,
                        // but that'd meen it wasn't called for more than 1 year
                        _integrateInvSupply += (rate * w * (prevFutureEpoch - prevWeekTime)) / total;
                        rate = newRate;
                        _integrateInvSupply += (rate * w * (weekTime - prevFutureEpoch)) / total;
                    } else {
                        _integrateInvSupply += (rate * w * dt) / total;
                    }
                }

                if (weekTime == block.timestamp) break;
                prevWeekTime = weekTime;
                weekTime = _min(weekTime + interval, block.timestamp);

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
        int128 userPeriod = periodOf[tokenId][user];
        uint256 oldIntegrateInvSupply = integrateInvSupply[userPeriod];
        uint256 dIntegrate = _integrateInvSupply - oldIntegrateInvSupply;
        if (dIntegrate > 0) {
            uint256 sum = _lastValue(_pointsSum[tokenId]);
            uint256 pt = _lastValue(_points[tokenId][user]);
            integrateFraction[tokenId][user] += (pt * dIntegrate * 2) / 3 / 1e18; // 67% goes to voters
            if (ownerOf(tokenId) == user) {
                integrateFraction[tokenId][user] += (sum * dIntegrate) / 3 / 1e18; // 33% goes to the owner
            }
        }
        periodOf[tokenId][user] = _period;
    }

    /**
     * @notice Mint a wrapped NFT
     * @param tokenId Token Id to deposit
     * @param dividendRatio Dividend ratio for the voters in bps (units of 0.01%)
     * @param to The owner of the newly minted wrapped NFT
     */
    function wrap(
        uint256 tokenId,
        uint256 dividendRatio,
        address to
    ) external override {
        wrap(tokenId, dividendRatio, to, 0);
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

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function unwrap(uint256 tokenId, address to) public override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        dividendRatios[tokenId] = 0;

        vote(tokenId, 0);

        _burn(tokenId);

        emit Unwrap(tokenId, to);

        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function vote(uint256 tokenId, uint256 userWeight) public override {
        require(_exists(tokenId), "NFTG: NON_EXISTENT");

        uint256 balance = IVotingEscrow(votingEscrow).balanceOf(msg.sender);
        uint256 pointNew = (balance * userWeight) / 10000;
        uint256 pointOld = points(tokenId, msg.sender);

        userCheckpoint(tokenId, msg.sender);

        _updateValueAtNow(_points[tokenId][msg.sender], pointNew);
        _updateValueAtNow(_pointsSum[tokenId], _lastValue(_pointsSum[tokenId]) + pointNew - pointOld);
        _updateValueAtNow(_pointsTotal, _lastValue(_pointsTotal) + pointNew - pointOld);

        IGaugeController(controller).voteForGaugeWeights(msg.sender, userWeight);

        emit Vote(tokenId, msg.sender, userWeight);
    }

    function claimDividends(address token, uint256 tokenId) external override {
        uint256 amount;
        uint256 _last = lastDividendClaimed[token][tokenId][msg.sender];
        uint256 i;
        while (i < 250) {
            uint256 id = _last + i;
            if (id >= dividends[token][tokenId].length) break;

            Snapshot memory dividend = dividends[token][tokenId][id];
            uint256 pt = _getValueAt(_points[tokenId][msg.sender], dividend.timestamp);
            if (pt > 0) {
                amount += (pt * uint256(dividend.value)) / 1e18;
            }

            unchecked {
                ++i;
            }
        }

        require(i > 0, "NFTG: NO_AMOUNT_TO_CLAIM");
        lastDividendClaimed[token][tokenId][msg.sender] = _last + i;

        emit ClaimDividends(token, tokenId, amount, msg.sender);
        Tokens.transfer(token, msg.sender, amount);
    }

    /**
     * @dev `_getValueAt` retrieves the number of tokens at a given time
     * @param snapshots The history of values being queried
     * @param timestamp The block timestamp to retrieve the value at
     * @return The weight at `timestamp`
     */
    function _getValueAt(Snapshot[] storage snapshots, uint256 timestamp) internal view returns (uint256) {
        if (snapshots.length == 0) return 0;

        // Shortcut for the actual value
        Snapshot storage last = snapshots[snapshots.length - 1];
        if (timestamp >= last.timestamp) return last.value;
        if (timestamp < snapshots[0].timestamp) return 0;

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
        return snapshots[min].value;
    }

    function _lastValue(Snapshot[] storage snapshots) internal view returns (uint256) {
        uint256 length = snapshots.length;
        return length > 0 ? uint256(snapshots[length - 1].value) : 0;
    }

    /**
     * @dev `_updateValueAtNow` is used to update snapshots
     * @param snapshots The history of data being updated
     * @param _value The new number of weight
     */
    function _updateValueAtNow(Snapshot[] storage snapshots, uint256 _value) internal {
        if ((snapshots.length == 0) || (snapshots[snapshots.length - 1].timestamp < block.timestamp)) {
            Snapshot storage newCheckPoint = snapshots.push();
            newCheckPoint.timestamp = uint64(block.timestamp);
            newCheckPoint.value = uint192(_value);
        } else {
            Snapshot storage oldCheckPoint = snapshots[snapshots.length - 1];
            oldCheckPoint.value = uint192(_value);
        }
    }

    function _settle(
        uint256 tokenId,
        address currency,
        address to,
        uint256 amount
    ) internal override {
        uint256 fee;
        if (currency == address(0)) {
            fee = INFTGaugeFactory(factory).distributeFeesETH{value: amount}();
        } else {
            fee = INFTGaugeFactory(factory).distributeFees(currency, amount);
        }

        uint256 dividend;
        uint256 sum = _lastValue(_pointsSum[tokenId]);
        if (sum > 0) {
            dividend = ((amount - fee) * dividendRatios[tokenId]) / 10000;
            dividends[currency][tokenId].push(Snapshot(uint64(block.timestamp), uint192((dividend * 1e18) / sum)));
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
