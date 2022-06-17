// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IVotingEscrow.sol";

function max(uint256 a, uint256 b) pure returns (uint256) {
    if (a > b) return a;
    return b;
}

/**
 * @title Gauge Controller
 * @author LevX (team@levx.io)
 * @notice Controls liquidity gauges and the issuance of coins through the gauges
 * @dev Ported from vyper (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/GaugeController.vy)
 */
contract GaugeController is Ownable, IGaugeController {
    struct Point {
        uint256 bias;
        uint256 slope;
    }

    struct VotedSlope {
        uint256 slope;
        uint256 power;
        uint256 end;
    }

    uint256 internal constant MULTIPLIER = 10**18;

    uint256 public immutable override interval;
    uint256 public immutable override weightVoteDelay;
    address public immutable override votingEscrow;

    // Gauge parameters
    // All numbers are "fixed point" on the basis of 1e18
    int128 public override gaugeTypesLength;
    int128 public override gaugesLength;
    mapping(int128 => string) public override gaugeTypeNames;

    // Needed for enumeration
    mapping(int128 => address) public override gauges;

    // we increment values by 1 prior to storing them here so we can rely on a value
    // of zero as meaning the gauge has not been set
    mapping(address => int128) internal _gaugeTypes;

    mapping(address => mapping(address => VotedSlope)) public override voteUserSlopes; // user -> gaugeAddr -> VotedSlope
    mapping(address => uint256) public override voteUserPower; // Total vote power used by user
    mapping(address => mapping(address => uint256)) public override lastUserVote; // Last user vote's timestamp for each gauge address

    // Past and scheduled points for gauge weight, sum of weights per type, total weight
    // Point is for bias+slope
    // changes_* are for changes in slope
    // time_* are for the last change timestamp
    // timestamps are rounded to whole weeks

    mapping(address => mapping(uint256 => Point)) public override pointsWeight; // gaugeAddr -> time -> Point
    mapping(address => mapping(uint256 => uint256)) internal _changesWeight; // gaugeAddr -> time -> slope
    mapping(address => uint256) public override timeWeight; // gaugeAddr -> last scheduled time (next week)

    mapping(int128 => mapping(uint256 => Point)) public override pointsSum; // gaugeType -> time -> Point
    mapping(int128 => mapping(uint256 => uint256)) internal _changesSum; // gaugeType -> time -> slope
    mapping(int128 => uint256) public override timeSum; // gaugeType -> last scheduled time (next week)

    mapping(uint256 => uint256) public override pointsTotal; // time -> total weight
    uint256 public override timeTotal; // last scheduled time

    mapping(int128 => mapping(uint256 => uint256)) public override pointsTypeWeight; // gaugeType -> time -> type weight
    mapping(int128 => uint256) public override timeTypeWeight; // gaugeType -> last scheduled time (next week)

    /**
     * @notice Contract constructor
     * @param _interval for how many seconds gauge weights will remain the same
     * @param _weightVoteDelay for how many seconds weight votes cannot be changed
     * @param _votingEscrow `VotingEscrow` contract address
     */
    constructor(
        uint256 _interval,
        uint256 _weightVoteDelay,
        address _votingEscrow
    ) {
        interval = _interval;
        weightVoteDelay = _weightVoteDelay;
        votingEscrow = _votingEscrow;
        timeTotal = (block.timestamp / interval) * interval;
    }

    /**
     * @notice Get gauge type for address
     * @param _addr Gauge address
     * @return Gauge type id
     */
    function gaugeTypes(address _addr) external view override returns (int128) {
        int128 gaugeType = _gaugeTypes[_addr];
        require(gaugeType != 0, "GC: INVALID_GAUGE_TYPE");

        return gaugeType - 1;
    }

    /**
     * @notice Get current gauge weight
     * @param addr Gauge address
     * @return Gauge weight
     */
    function getGaugeWeight(address addr) external view override returns (uint256) {
        return pointsWeight[addr][timeWeight[addr]].bias;
    }

    /**
     * @notice Get current type weight
     * @param gaugeType Type id
     * @return Type weight
     */
    function getTypeWeight(int128 gaugeType) external view override returns (uint256) {
        return pointsTypeWeight[gaugeType][timeTypeWeight[gaugeType]];
    }

    /**
     * @notice Get current total (type-weighted) weight
     * @return Total weight
     */
    function getTotalWeight() external view override returns (uint256) {
        return pointsTotal[timeTotal];
    }

    /**
     * @notice Get sum of gauge weights per type
     * @param gaugeType Type id
     * @return Sum of gauge weights
     */
    function getWeightsSumPerType(int128 gaugeType) external view override returns (uint256) {
        return pointsSum[gaugeType][timeSum[gaugeType]].bias;
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Gauge address
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeight(address addr) external view override returns (uint256) {
        return _gaugeRelativeWeight(addr, block.timestamp);
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Gauge address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeight(address addr, uint256 time) public view override returns (uint256) {
        return _gaugeRelativeWeight(addr, time);
    }

    /**
     * @notice Add gauge type with name `_name` and weight `weight`
     * @param _name Name of gauge type
     */
    function addType(string memory _name) external override {
        addType(_name, 0);
    }

    /**
     * @notice Add gauge type with name `_name` and weight `weight`
     * @param _name Name of gauge type
     * @param weight Weight of gauge type
     */
    function addType(string memory _name, uint256 weight) public onlyOwner {
        int128 gaugeType = gaugeTypesLength;
        gaugeTypeNames[gaugeType] = _name;
        gaugeTypesLength = gaugeType + 1;
        if (weight != 0) {
            _changeTypeWeight(gaugeType, weight);
            emit AddType(_name, gaugeType);
        }
    }

    /**
     * @notice Change gauge type `gaugeType` weight to `weight`
     * @param gaugeType Gauge type id
     * @param weight New Gauge weight
     */
    function changeTypeWeight(int128 gaugeType, uint256 weight) external override onlyOwner {
        _changeTypeWeight(gaugeType, weight);
    }

    /**
     * @notice Add gauge `addr` of type `gaugeType` with weight `weight`
     * @param addr Gauge address
     * @param gaugeType Gauge type
     */
    function addGauge(address addr, int128 gaugeType) external override {
        addGauge(addr, gaugeType, 0);
    }

    /**
     * @notice Add gauge `addr` of type `gaugeType` with weight `weight`
     * @param addr Gauge address
     * @param gaugeType Gauge type
     * @param weight Gauge weight
     */
    function addGauge(
        address addr,
        int128 gaugeType,
        uint256 weight
    ) public override onlyOwner {
        require((gaugeType >= 0) && (gaugeType < gaugeTypesLength), "GC: INVALID_GAUGE_TYPE");
        require(_gaugeTypes[addr] == 0, "GC: DUPLICATE_GAUGE");

        int128 n = gaugesLength;
        gaugesLength = n + 1;
        gauges[n] = addr;

        _gaugeTypes[addr] = gaugeType + 1;
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        if (weight > 0) {
            uint256 _type_weight = _getTypeWeight(gaugeType);
            uint256 _old_sum = _getSum(gaugeType);
            uint256 _old_total = _getTotal();

            pointsSum[gaugeType][next_time].bias = weight + _old_sum;
            timeSum[gaugeType] = next_time;
            pointsTotal[next_time] = _old_total + _type_weight * weight;
            timeTotal = next_time;

            pointsWeight[addr][next_time].bias = weight;
        }

        if (timeSum[gaugeType] == 0) timeSum[gaugeType] = next_time;
        timeWeight[addr] = next_time;

        emit NewGauge(addr, gaugeType, weight);
    }

    /**
     * @notice Change weight of gauge `addr` to `weight`
     * @param addr `GaugeController` contract address
     * @param weight New Gauge weight
     */
    function changeGaugeWeight(address addr, uint256 weight) external override onlyOwner {
        _changeGaugeWeight(addr, weight);
    }

    /**
     * @notice Checkpoint to fill data common for all gauges
     */
    function checkpoint() external override {
        _getTotal();
    }

    /**
     * @notice Checkpoint to fill data for both a specific gauge and common for all gauges
     * @param addr Gauge address
     */
    function checkpointGauge(address addr) external override {
        _getWeight(addr);
        _getTotal();
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param addr Gauge address
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeightWrite(address addr) external override returns (uint256) {
        return gaugeRelativeWeightWrite(addr, block.timestamp);
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param addr Gauge address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeightWrite(address addr, uint256 time) public override returns (uint256) {
        _getWeight(addr);
        _getTotal(); // Also calculates get_sum
        return gaugeRelativeWeight(addr, time);
    }

    /**
     * @notice Allocate voting power for changing pool weights
     * @param _gaugeAddr Gauge which `msg.sender` votes for
     * @param _userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function voteForGaugeWeights(address _gaugeAddr, uint256 _userWeight) external override {
        address escrow = votingEscrow;
        uint256 slope = uint256(uint128(IVotingEscrow(escrow).getLastUserSlope(msg.sender)));
        uint256 lock_end = IVotingEscrow(escrow).unlockTime(msg.sender);
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;
        require(lock_end > next_time, "GC: LOCK_EXPIRES_TOO_EARLY");
        require((_userWeight >= 0) && (_userWeight <= 10000), "GC: VOTING_POWER_ALL_USED");
        require(block.timestamp >= lastUserVote[msg.sender][_gaugeAddr] + weightVoteDelay, "GC: VOTED_TOO_EARLY");

        int128 gaugeType = _gaugeTypes[_gaugeAddr] - 1;
        require(gaugeType >= 0, "GC: GAUGE_NOT_ADDED");
        // Prepare slopes and biases in memory
        VotedSlope memory old_slope = voteUserSlopes[msg.sender][_gaugeAddr];
        uint256 old_dt;
        if (old_slope.end > next_time) old_dt = old_slope.end - next_time;
        uint256 old_bias = old_slope.slope * old_dt;
        VotedSlope memory new_slope = VotedSlope({
        slope: (slope * _userWeight) / 10000,
        end: lock_end,
        power: _userWeight
        });
        uint256 new_bias = new_slope.slope * (lock_end - next_time);

        // Check and update powers (weights) used
        uint256 power_used = voteUserPower[msg.sender];
        power_used = power_used + new_slope.power - old_slope.power;
        voteUserPower[msg.sender] = power_used;
        require((power_used >= 0) && (power_used <= 10000), "GC: USED_TOO_MUCH_POWER");

        /// Remove old and schedule new slope changes
        _updateSlopeChanges(_gaugeAddr, next_time, gaugeType, old_bias, new_bias, old_slope, new_slope);

        // Record last action time
        lastUserVote[msg.sender][_gaugeAddr] = block.timestamp;

        emit VoteForGauge(block.timestamp, msg.sender, _gaugeAddr, _userWeight);
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Gauge address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function _gaugeRelativeWeight(address addr, uint256 time) internal view returns (uint256) {
        uint256 t = (time / interval) * interval;
        uint256 _total_weight = pointsTotal[t];

        if (_total_weight > 0) {
            int128 gaugeType = _gaugeTypes[addr] - 1;
            uint256 _type_weight = pointsTypeWeight[gaugeType][t];
            uint256 _gauge_weight = pointsWeight[addr][t].bias;
            return (MULTIPLIER * _type_weight * _gauge_weight) / _total_weight;
        } else return 0;
    }

    /**
     * @notice Change type weight
     * @param gaugeType Type id
     * @param weight New type weight
     */
    function _changeTypeWeight(int128 gaugeType, uint256 weight) internal {
        uint256 old_weight = _getTypeWeight(gaugeType);
        uint256 old_sum = _getSum(gaugeType);
        uint256 _total_weight = _getTotal();
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        _total_weight = _total_weight + old_sum * weight - old_sum * old_weight;
        pointsTotal[next_time] = _total_weight;
        pointsTypeWeight[gaugeType][next_time] = weight;
        timeTotal = next_time;
        timeTypeWeight[gaugeType] = next_time;

        emit NewTypeWeight(gaugeType, next_time, weight, _total_weight);
    }

    function _changeGaugeWeight(address addr, uint256 weight) internal {
        // Change gauge weight
        // Only needed when testing in reality
        int128 gaugeType = _gaugeTypes[addr] - 1;
        uint256 old_gauge_weight = _getWeight(addr);
        uint256 type_weight = _getTypeWeight(gaugeType);
        uint256 old_sum = _getSum(gaugeType);
        uint256 _total_weight = _getTotal();
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        pointsWeight[addr][next_time].bias = weight;
        timeWeight[addr] = next_time;

        uint256 new_sum = old_sum + weight - old_gauge_weight;
        pointsSum[gaugeType][next_time].bias = new_sum;
        timeSum[gaugeType] = next_time;

        _total_weight = _total_weight + new_sum * type_weight - old_sum * type_weight;
        pointsTotal[next_time] = _total_weight;
        timeTotal = next_time;

        emit NewGaugeWeight(addr, block.timestamp, weight, _total_weight);
    }

    function _updateSlopeChanges(
        address _gaugeAddr,
        uint256 nextTime,
        int128 gaugeType,
        uint256 oldBias,
        uint256 newBias,
        VotedSlope memory oldSlope,
        VotedSlope memory newSlope
    ) internal {
        // Remove slope changes for old slopes
        // Schedule recording of initial slope for next_time
        pointsWeight[_gaugeAddr][nextTime].bias = max(_getWeight(_gaugeAddr) + newBias, oldBias) - oldBias;
        pointsSum[gaugeType][nextTime].bias = max(_getSum(gaugeType) + newBias, oldBias) - oldBias;
        if (oldSlope.end > nextTime) {
            pointsWeight[_gaugeAddr][nextTime].slope =
            max(pointsWeight[_gaugeAddr][nextTime].slope + newSlope.slope, oldSlope.slope) -
            oldSlope.slope;
            pointsSum[gaugeType][nextTime].slope =
            max(pointsSum[gaugeType][nextTime].slope + newSlope.slope, oldSlope.slope) -
            oldSlope.slope;
        } else {
            pointsWeight[_gaugeAddr][nextTime].slope += newSlope.slope;
            pointsSum[gaugeType][nextTime].slope += newSlope.slope;
        }
        if (oldSlope.end > block.timestamp) {
            // Cancel old slope changes if they still didn't happen
            _changesWeight[_gaugeAddr][oldSlope.end] -= oldSlope.slope;
            _changesSum[gaugeType][oldSlope.end] -= oldSlope.slope;
        }
        // Add slope changes for new slopes
        _changesWeight[_gaugeAddr][newSlope.end] += newSlope.slope;
        _changesSum[gaugeType][newSlope.end] += newSlope.slope;

        _getTotal();

        voteUserSlopes[msg.sender][_gaugeAddr] = newSlope;
    }

    /**
     * @notice Fill historic total weights week-over-week for missed checkins
     * and return the total for the future week
     * @return Total weight
     */
    function _getTotal() internal returns (uint256) {
        uint256 t = timeTotal;
        int128 _n_gaugeTypes = gaugeTypesLength;
        // If we have already checkpointed - still need to change the value
        if (t > block.timestamp) t -= interval;
        uint256 pt = pointsTotal[t];

        for (int128 gaugeType; gaugeType < 100; gaugeType++) {
            if (gaugeType == _n_gaugeTypes) break;
            _getSum(gaugeType);
            _getTypeWeight(gaugeType);
        }

        for (uint256 i; i < 500; i++) {
            if (t > block.timestamp) break;
            t += interval;
            pt = 0;
            // Scales as n_types * n_unchecked_weeks (hopefully 1 at most)
            for (int128 gaugeType; gaugeType < 100; gaugeType++) {
                if (gaugeType == _n_gaugeTypes) break;
                uint256 type_sum = pointsSum[gaugeType][t].bias;
                uint256 type_weight = pointsTypeWeight[gaugeType][t];
                pt += type_sum * type_weight;
            }
            pointsTotal[t] = pt;

            if (t > block.timestamp) timeTotal = t;
        }
        return pt;
    }

    /**
     * @notice Fill sum of gauge weights for the same type week-over-week for
     * missed checkins and return the sum for the future week
     * @param gaugeType Gauge type id
     * @return Sum of weights
     */
    function _getSum(int128 gaugeType) internal returns (uint256) {
        uint256 t = timeSum[gaugeType];
        if (t > 0) {
            Point memory pt = pointsSum[gaugeType][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                uint256 d_bias = pt.slope * interval;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = _changesSum[gaugeType][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                pointsSum[gaugeType][t] = pt;
                if (t > block.timestamp) timeSum[gaugeType] = t;
            }
            return pt.bias;
        } else return 0;
    }

    /**
     * @notice Fill historic type weights week-over-week for missed checkins
     * and return the type weight for the future week
     * @param gaugeType Gauge type id
     * @return Type weight
     */
    function _getTypeWeight(int128 gaugeType) internal returns (uint256) {
        uint256 t = timeTypeWeight[gaugeType];
        if (t > 0) {
            uint256 w = pointsTypeWeight[gaugeType][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                pointsTypeWeight[gaugeType][t] = w;
                if (t > block.timestamp) timeTypeWeight[gaugeType] = t;
            }
            return w;
        } else return 0;
    }

    /**
     * @notice Fill historic gauge weights week-over-week for missed checkins
     * and return the total for the future week
     * @param gaugeAddr Address of the gauge
     * @return Gauge weight
     */
    function _getWeight(address gaugeAddr) internal returns (uint256) {
        uint256 t = timeWeight[gaugeAddr];
        if (t > 0) {
            Point memory pt = pointsWeight[gaugeAddr][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                uint256 d_bias = pt.slope * interval;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = _changesWeight[gaugeAddr][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                pointsWeight[gaugeAddr][t] = pt;
                if (t > block.timestamp) timeWeight[gaugeAddr] = t;
            }
            return pt.bias;
        } else return 0;
    }
}
