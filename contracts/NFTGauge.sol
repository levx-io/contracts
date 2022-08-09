// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IMinter.sol";
import "./interfaces/IVotingEscrow.sol";
import "./libraries/Tokens.sol";

contract NFTGauge is WrappedERC721, INFTGauge {
    struct Snapshot {
        uint64 timestamp;
        uint192 value;
    }

    struct Dividend {
        uint256 tokenId;
        uint64 timestamp;
        uint192 amountPerPoint;
    }

    address public override controller;
    address public override minter;
    address public override ve;

    mapping(uint256 => Snapshot[]) public override rewards;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public override rewardsClaimed;

    mapping(uint256 => uint256) public override dividendRatios;
    mapping(address => Dividend[]) public override dividends;
    mapping(address => mapping(uint256 => mapping(address => bool))) public override dividendsClaimed;

    uint256 public override futureEpochTime;

    uint256 public override integrateCheckpoint;
    uint256 public override integrateInvSupply;

    mapping(uint256 => uint256[]) public override integrateCheckpointsOf; // tokenId -> period -> time
    mapping(uint256 => mapping(uint256 => uint256)) public override integrateInvSuppliesOf; // tokenId -> time -> supply
    mapping(uint256 => mapping(uint256 => uint256)) public override integrateFractionsOf; // tokenId -> time -> fraction

    mapping(uint256 => mapping(address => uint256)) public override periodOfUser; // tokenId -> user -> period
    mapping(uint256 => mapping(address => uint256)) public override integrateFractionOfUser; // tokenId -> user -> fraction

    uint256 public override inflationRate;

    bool public override isKilled;

    uint256 internal _interval;

    mapping(uint256 => mapping(address => Snapshot[])) internal _points;
    mapping(uint256 => Snapshot[]) internal _pointsSum;
    Snapshot[] internal _pointsTotal;

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller,
        address _minter,
        address _ve
    ) external override initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);

        controller = _controller;
        minter = _minter;
        ve = _ve;

        _interval = IGaugeController(_controller).interval();
        integrateCheckpoint = ((block.timestamp + _interval) / _interval) * _interval;
        inflationRate = IMinter(_minter).rate();
        futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
    }

    function points(uint256 tokenId, address user) public view override returns (uint256) {
        if (!_exists(tokenId)) return 0;
        return _lastValue(_pointsSum[tokenId]) > 0 ? _lastValue(_points[tokenId][user]) : 0;
    }

    function pointsAt(
        uint256 tokenId,
        address user,
        uint256 timestamp
    ) public view override returns (uint256) {
        if (!_exists(tokenId)) return 0;
        return _getValueAt(_pointsSum[tokenId], timestamp) > 0 ? _getValueAt(_points[tokenId][user], timestamp) : 0;
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

    function dividendsLength(address token) external view override returns (uint256) {
        return dividends[token].length;
    }

    function periodOf(uint256 tokenId) external view override returns (uint256) {
        return integrateCheckpointsOf[tokenId].length;
    }

    /**
     * @notice Toggle the killed status of the gauge
     */
    function killMe() external override {
        require(msg.sender == controller, "NFTG: FORBIDDDEN");
        isKilled = !isKilled;
    }

    function _checkpoint() internal returns (uint256 _integrateCheckpoint, uint256 _integrateInvSupply) {
        address _minter = minter;
        address _controller = controller;

        _integrateCheckpoint = integrateCheckpoint;
        _integrateInvSupply = integrateInvSupply;
        uint256 rate = inflationRate;
        uint256 newRate = rate;
        uint256 prevFutureEpoch = futureEpochTime;
        if (prevFutureEpoch >= _integrateCheckpoint) {
            futureEpochTime = IMinter(_minter).futureEpochTimeWrite();
            newRate = IMinter(_minter).rate();
            inflationRate = newRate;
        }
        IGaugeController(_controller).checkpointGauge(address(this));

        uint256 total = _lastValue(_pointsTotal);

        if (isKilled) rate = 0; // Stop distributing inflation as soon as killed

        if (block.timestamp > _integrateCheckpoint) {
            uint256 interval = _interval;
            for (uint256 i; i < 120; ) {
                uint256 w = IGaugeController(_controller).gaugeRelativeWeight(address(this), _integrateCheckpoint);

                if (total > 0) {
                    if (prevFutureEpoch >= _integrateCheckpoint && prevFutureEpoch < _integrateCheckpoint + interval) {
                        _integrateInvSupply += (rate * w * (prevFutureEpoch - _integrateCheckpoint)) / total;
                        rate = newRate;
                        _integrateInvSupply += (rate * w * (_integrateCheckpoint + interval - prevFutureEpoch)) / total;
                    } else {
                        _integrateInvSupply += (rate * w * interval) / total;
                    }
                }
                if (_integrateCheckpoint + interval > block.timestamp) break;
                _integrateCheckpoint += interval;

                unchecked {
                    ++i;
                }
            }

            integrateCheckpoint = _integrateCheckpoint;
            integrateInvSupply = _integrateInvSupply;
        }
    }

    function _tokenCheckpoint(uint256 tokenId) internal {
        (uint256 _integrateCheckpoint, uint256 _integrateInvSupply) = _checkpoint();

        // Update token-specific integrals
        uint256[] storage checkpoints = integrateCheckpointsOf[tokenId];
        uint256 prevCheckpoint = checkpoints.length > 0 ? checkpoints[checkpoints.length - 1] : 0;
        if (prevCheckpoint < _integrateCheckpoint) {
            checkpoints.push(_integrateCheckpoint);

            uint256 sum = _lastValue(_pointsSum[tokenId]);
            uint256 fraction = (sum * (_integrateInvSupply - integrateInvSuppliesOf[tokenId][prevCheckpoint])) / 1e18;
            integrateFractionsOf[tokenId][_integrateCheckpoint] =
                integrateFractionsOf[tokenId][prevCheckpoint] +
                fraction;
            integrateInvSuppliesOf[tokenId][_integrateCheckpoint] = _integrateInvSupply;
        }
    }

    /**
     * @notice Checkpoint for a user for a specific token
     * @param tokenId Token Id
     * @param user User address
     */
    function userCheckpoint(uint256 tokenId, address user) external override {
        require(msg.sender == user || user == minter, "NFTG: FORBIDDEN");
        _tokenCheckpoint(tokenId);

        uint256 userPeriod = periodOfUser[tokenId][user] + 1;
        uint256 tokenPeriod = integrateCheckpointsOf[tokenId].length;
        if (userPeriod >= tokenPeriod) return;

        uint256 integrateFraction = integrateFractionOfUser[tokenId][user];

        for (uint256 i; i < 120; ) {
            uint256 time = integrateCheckpointsOf[tokenId][userPeriod + i];
            uint256 fraction = integrateFractionsOf[tokenId][time];

            integrateFraction += (fraction * pointsAt(tokenId, user, time)) / pointsSumAt(tokenId, time);

            if (userPeriod + i == tokenPeriod) break;

            unchecked {
                ++i;
            }
        }

        periodOfUser[tokenId][user] = tokenPeriod;
        integrateFractionOfUser[tokenId][user] = integrateFraction;
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

        _tokenCheckpoint(tokenId);

        dividendRatios[tokenId] = dividendRatio;

        _mint(to, tokenId);

        vote(tokenId, userWeight);

        emit Wrap(tokenId, to);

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function unwrap(uint256 tokenId, address to) public override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        _tokenCheckpoint(tokenId);

        dividendRatios[tokenId] = 0;

        _burn(tokenId);

        uint256 sum = _lastValue(_pointsSum[tokenId]);
        _updateValueAtNow(_pointsSum[tokenId], 0);
        _updateValueAtNow(_pointsTotal, _lastValue(_pointsTotal) - sum);

        emit Unwrap(tokenId, to);

        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function vote(uint256 tokenId, uint256 userWeight) public override {
        uint256 balance = IVotingEscrow(ve).balanceOf(msg.sender);
        uint256 pointNew = (balance * userWeight) / 10000;
        uint256 pointOld = points(tokenId, msg.sender);

        _updateValueAtNow(_points[tokenId][msg.sender], pointNew);
        _updateValueAtNow(_pointsSum[tokenId], _lastValue(_pointsSum[tokenId]) + pointNew - pointOld);
        _updateValueAtNow(_pointsTotal, _lastValue(_pointsTotal) + pointNew - pointOld);

        IGaugeController(controller).voteForGaugeWeights(msg.sender, userWeight);

        emit Vote(tokenId, msg.sender, userWeight);
    }

    function claimDividends(address token, uint256[] calldata ids) external override {
        uint256 amount;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            require(!dividendsClaimed[token][id][msg.sender], "NFTG: CLAIMED");
            dividendsClaimed[token][id][msg.sender] = true;

            Dividend memory dividend = dividends[token][id];
            uint256 pt = _getValueAt(_points[dividend.tokenId][msg.sender], dividend.timestamp);
            if (pt > 0) {
                amount += (pt * uint256(dividend.amountPerPoint)) / 1e18;
            }
        }
        emit ClaimDividends(token, amount, msg.sender);
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
            dividends[currency].push(
                Dividend(
                    tokenId,
                    uint64(((block.timestamp + _interval) / _interval) * _interval),
                    uint192((dividend * 1e18) / sum)
                )
            );
            emit DistributeDividend(currency, dividends[currency].length - 1, tokenId, dividend);
        }
        Tokens.transfer(currency, to, amount - fee - dividend);
    }
}
