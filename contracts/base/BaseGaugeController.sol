// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "../interfaces/IBaseGaugeController.sol";
import "../interfaces/IVotingEscrow.sol";

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
abstract contract BaseGaugeController is Initializable, IBaseGaugeController {
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

    uint256 public override interval;
    uint256 public override weightVoteDelay;
    address public override votingEscrow;

    // Gauge parameters
    // All numbers are "fixed point" on the basis of 1e18
    int128 public override gaugeTypesLength;
    int128 public override gaugesLength;
    mapping(int128 => string) public override gaugeTypeNames;

    // Needed for enumeration
    mapping(int128 => bytes32) public override gauges;

    // we increment values by 1 prior to storing them here so we can rely on a value
    // of zero as meaning the gauge has not been set
    mapping(bytes32 => int128) internal _gaugeTypes;

    mapping(address => mapping(bytes32 => VotedSlope)) public override voteUserSlopes; // user -> identifier -> VotedSlope
    mapping(address => uint256) public override voteUserPower; // Total vote power used by user
    mapping(address => mapping(bytes32 => uint256)) public override lastUserVote; // Last user vote's timestamp for each gauge address

    // Past and scheduled points for gauge weight, sum of weights per type, total weight
    // Point is for bias+slope
    // changes_* are for changes in slope
    // time_* are for the last change timestamp
    // timestamps are rounded to whole weeks

    mapping(bytes32 => mapping(uint256 => Point)) public override pointsWeight; // identifier -> time -> Point
    mapping(bytes32 => mapping(uint256 => uint256)) internal _changesWeight; // identifier -> time -> slope
    mapping(bytes32 => uint256) public override timeWeight; // identifier -> last scheduled time (next week)

    mapping(int128 => mapping(uint256 => Point)) public override pointsSum; // gaugeType -> time -> Point
    mapping(int128 => mapping(uint256 => uint256)) internal _changesSum; // gaugeType -> time -> slope
    mapping(int128 => uint256) public override timeSum; // gaugeType -> last scheduled time (next week)

    mapping(uint256 => uint256) public override pointsTotal; // time -> total weight
    uint256 public override timeTotal; // last scheduled time

    mapping(int128 => mapping(uint256 => uint256)) public override pointsTypeWeight; // gaugeType -> time -> type weight
    mapping(int128 => uint256) public override timeTypeWeight; // gaugeType -> last scheduled time (next week)

    /**
     * @notice Contract initializer
     * @param _interval for how many seconds gauge weights will remain the same
     * @param _weightVoteDelay for how many seconds weight votes cannot be changed
     * @param _votingEscrow `VotingEscrow` contract address
     */
    function __BaseGaugeController_init(
        uint256 _interval,
        uint256 _weightVoteDelay,
        address _votingEscrow
    ) internal initializer {
        interval = _interval;
        weightVoteDelay = _weightVoteDelay;
        votingEscrow = _votingEscrow;
        timeTotal = (block.timestamp / interval) * interval;
    }

    /**
     * @notice Get gauge type for id
     * @param id Gauge id
     * @return Gauge type id
     */
    function gaugeTypes(bytes32 id) public view virtual override returns (int128) {
        int128 gaugeType = _gaugeTypes[id];
        require(gaugeType != 0, "BGC: INVALID_GAUGE_TYPE");

        return gaugeType - 1;
    }

    /**
     * @notice Get current gauge weight
     * @param id Gauge id
     * @return Gauge weight
     */
    function getGaugeWeight(bytes32 id) public view virtual override returns (uint256) {
        return pointsWeight[id][timeWeight[id]].bias;
    }

    /**
     * @notice Get current type weight
     * @param gaugeType Type id
     * @return Type weight
     */
    function getTypeWeight(int128 gaugeType) public view virtual override returns (uint256) {
        return pointsTypeWeight[gaugeType][timeTypeWeight[gaugeType]];
    }

    /**
     * @notice Get current total (type-weighted) weight
     * @return Total weight
     */
    function getTotalWeight() public view virtual override returns (uint256) {
        return pointsTotal[timeTotal];
    }

    /**
     * @notice Get sum of gauge weights per type
     * @param gaugeType Type id
     * @return Sum of gauge weights
     */
    function getWeightsSumPerType(int128 gaugeType) public view virtual override returns (uint256) {
        return pointsSum[gaugeType][timeSum[gaugeType]].bias;
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param id Gauge id
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeight(bytes32 id) public view virtual override returns (uint256) {
        return _gaugeRelativeWeight(id, block.timestamp);
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param id Gauge id
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeight(bytes32 id, uint256 time) public view virtual override returns (uint256) {
        return _gaugeRelativeWeight(id, time);
    }

    /**
     * @notice Checkpoint to fill data common for all gauges
     */
    function checkpoint() public virtual override {
        _getTotal();
    }

    /**
     * @notice Checkpoint to fill data for both a specific gauge and common for all gauges
     * @param id Gauge id
     */
    function checkpointGauge(bytes32 id) public virtual override {
        _getWeight(id);
        _getTotal();
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param id Gauge id
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeightWrite(bytes32 id) public virtual override returns (uint256) {
        return gaugeRelativeWeightWrite(id, block.timestamp);
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param id Gauge id
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeightWrite(bytes32 id, uint256 time) public virtual override returns (uint256) {
        _getWeight(id);
        _getTotal(); // Also calculates get_sum
        return gaugeRelativeWeight(id, time);
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param id Gauge id
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function _gaugeRelativeWeight(bytes32 id, uint256 time) internal view returns (uint256) {
        uint256 t = (time / interval) * interval;
        uint256 _total_weight = pointsTotal[t];

        if (_total_weight > 0) {
            int128 gaugeType = _gaugeTypes[id] - 1;
            uint256 _type_weight = pointsTypeWeight[gaugeType][t];
            uint256 _gauge_weight = pointsWeight[id][t].bias;
            return (MULTIPLIER * _type_weight * _gauge_weight) / _total_weight;
        } else return 0;
    }

    /**
     * @notice Add gauge type with name `name` and weight `weight`
     * @param name Name of gauge type
     */
    function _addType(string memory name) internal virtual {
        _addType(name, 0);
    }

    /**
     * @notice Add gauge type with name `name` and weight `weight`
     * @param name Name of gauge type
     * @param weight Weight of gauge type
     */
    function _addType(string memory name, uint256 weight) internal virtual {
        int128 gaugeType = gaugeTypesLength;
        gaugeTypeNames[gaugeType] = name;
        gaugeTypesLength = gaugeType + 1;
        if (weight != 0) {
            _changeTypeWeight(gaugeType, weight);
        }
        emit AddType(name, gaugeType);
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

    /**
     * @notice Add gauge `id` of type `gaugeType` with weight `weight`
     * @param id Gauge id
     * @param gaugeType Gauge type
     */
    function _addGauge(bytes32 id, int128 gaugeType) internal virtual {
        _addGauge(id, gaugeType, 0);
    }

    /**
     * @notice Add gauge `id` of type `gaugeType` with weight `weight`
     * @param id Gauge id
     * @param gaugeType Gauge type
     * @param weight Gauge weight
     */
    function _addGauge(
        bytes32 id,
        int128 gaugeType,
        uint256 weight
    ) internal virtual {
        require((gaugeType >= 0) && (gaugeType < gaugeTypesLength), "BGC: INVALID_GAUGE_TYPE");
        require(_gaugeTypes[id] == 0, "BGC: DUPLICATE_GAUGE");

        int128 n = gaugesLength;
        gaugesLength = n + 1;
        gauges[n] = id;

        _gaugeTypes[id] = gaugeType + 1;
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        if (weight > 0) {
            uint256 _type_weight = _getTypeWeight(gaugeType);
            uint256 _old_sum = _getSum(gaugeType);
            uint256 _old_total = _getTotal();

            pointsSum[gaugeType][next_time].bias = weight + _old_sum;
            timeSum[gaugeType] = next_time;
            pointsTotal[next_time] = _old_total + _type_weight * weight;
            timeTotal = next_time;

            pointsWeight[id][next_time].bias = weight;
        }

        if (timeSum[gaugeType] == 0) timeSum[gaugeType] = next_time;
        timeWeight[id] = next_time;

        emit NewGauge(id, gaugeType, weight);
    }

    /**
     * @notice Change weight of gauge `id` to `weight`
     * @param id Gauge id
     * @param weight New Gauge weight
     */
    function _changeGaugeWeight(bytes32 id, uint256 weight) internal virtual {
        // Change gauge weight
        // Only needed when testing in reality
        int128 gaugeType = _gaugeTypes[id] - 1;
        uint256 old_gauge_weight = _getWeight(id);
        uint256 type_weight = _getTypeWeight(gaugeType);
        uint256 old_sum = _getSum(gaugeType);
        uint256 _total_weight = _getTotal();
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        pointsWeight[id][next_time].bias = weight;
        timeWeight[id] = next_time;

        uint256 new_sum = old_sum + weight - old_gauge_weight;
        pointsSum[gaugeType][next_time].bias = new_sum;
        timeSum[gaugeType] = next_time;

        _total_weight = _total_weight + new_sum * type_weight - old_sum * type_weight;
        pointsTotal[next_time] = _total_weight;
        timeTotal = next_time;

        emit NewGaugeWeight(id, block.timestamp, weight, _total_weight);
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
     * @param id Gauge id
     * @return Gauge weight
     */
    function _getWeight(bytes32 id) internal returns (uint256) {
        uint256 t = timeWeight[id];
        if (t > 0) {
            Point memory pt = pointsWeight[id][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                uint256 d_bias = pt.slope * interval;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = _changesWeight[id][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                pointsWeight[id][t] = pt;
                if (t > block.timestamp) timeWeight[id] = t;
            }
            return pt.bias;
        } else return 0;
    }

    /**
     * @notice Allocate voting power for changing pool weights on behalf of a user
     * @param id Gauge which `user` votes for
     * @param user User's wallet address
     * @param userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function _voteForGaugeWeights(
        bytes32 id,
        address user,
        uint256 userWeight
    ) internal virtual {
        address escrow = votingEscrow;
        uint256 slope = uint256(uint128(IVotingEscrow(escrow).getLastUserSlope(user)));
        uint256 lock_end = IVotingEscrow(escrow).unlockTime(user);
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;
        require(lock_end > next_time, "BGC: LOCK_EXPIRES_TOO_EARLY");
        require((userWeight >= 0) && (userWeight <= 10000), "BGC: VOTING_POWER_ALL_USED");
        require(block.timestamp >= lastUserVote[user][id] + weightVoteDelay, "BGC: VOTED_TOO_EARLY");

        // Avoid stack too deep error
        {
            int128 gaugeType = _gaugeTypes[id] - 1;
            require(gaugeType >= 0, "BGC: GAUGE_NOT_ADDED");
            // Prepare slopes and biases in memory
            VotedSlope memory old_slope = voteUserSlopes[user][id];
            uint256 old_dt;
            if (old_slope.end > next_time) old_dt = old_slope.end - next_time;
            uint256 old_bias = old_slope.slope * old_dt;
            VotedSlope memory new_slope = VotedSlope({
                slope: (slope * userWeight) / 10000,
                end: lock_end,
                power: userWeight
            });
            uint256 new_bias = new_slope.slope * (lock_end - next_time);

            // Check and update powers (weights) used
            uint256 power_used = voteUserPower[user];
            power_used = power_used + new_slope.power - old_slope.power;
            voteUserPower[user] = power_used;
            require((power_used >= 0) && (power_used <= 10000), "BGC: USED_TOO_MUCH_POWER");

            /// Remove old and schedule new slope changes
            _updateSlopeChanges(id, next_time, gaugeType, old_bias, new_bias, old_slope, new_slope);
        }

        // Record last action time
        lastUserVote[user][id] = block.timestamp;

        emit VoteForGauge(block.timestamp, user, id, userWeight);
    }

    function _updateSlopeChanges(
        bytes32 id,
        uint256 nextTime,
        int128 gaugeType,
        uint256 oldBias,
        uint256 newBias,
        VotedSlope memory oldSlope,
        VotedSlope memory newSlope
    ) internal {
        // Remove slope changes for old slopes
        // Schedule recording of initial slope for next_time
        pointsWeight[id][nextTime].bias = max(_getWeight(id) + newBias, oldBias) - oldBias;
        pointsSum[gaugeType][nextTime].bias = max(_getSum(gaugeType) + newBias, oldBias) - oldBias;
        if (oldSlope.end > nextTime) {
            pointsWeight[id][nextTime].slope =
                max(pointsWeight[id][nextTime].slope + newSlope.slope, oldSlope.slope) -
                oldSlope.slope;
            pointsSum[gaugeType][nextTime].slope =
                max(pointsSum[gaugeType][nextTime].slope + newSlope.slope, oldSlope.slope) -
                oldSlope.slope;
        } else {
            pointsWeight[id][nextTime].slope += newSlope.slope;
            pointsSum[gaugeType][nextTime].slope += newSlope.slope;
        }
        if (oldSlope.end > block.timestamp) {
            // Cancel old slope changes if they still didn't happen
            _changesWeight[id][oldSlope.end] -= oldSlope.slope;
            _changesSum[gaugeType][oldSlope.end] -= oldSlope.slope;
        }
        // Add slope changes for new slopes
        _changesWeight[id][newSlope.end] += newSlope.slope;
        _changesSum[gaugeType][newSlope.end] += newSlope.slope;

        _getTotal();

        voteUserSlopes[msg.sender][id] = newSlope;
    }
}
