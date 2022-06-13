// SPDX-License-Identifier: WTFPL
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
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
contract GaugeController is Ownable {
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

    uint256 public immutable interval;
    uint256 public immutable weightVoteDelay;
    address public immutable token;
    address public immutable veToken;

    // Gauge parameters
    // All numbers are "fixed point" on the basis of 1e18
    int128 public gaugeTypeLength;
    int128 public gaugeLength;
    mapping(int128 => string) public gaugeTypeNames;

    // Needed for enumeration
    mapping(int128 => address) public gauges;

    // we increment values by 1 prior to storing them here so we can rely on a value
    // of zero as meaning the gauge has not been set
    mapping(address => int128) internal _gaugeTypes;

    mapping(address => mapping(address => VotedSlope)) public voteUserSlopes; // user -> gauge_addr -> VotedSlope
    mapping(address => uint256) public voteUserPower; // Total vote power used by user
    mapping(address => mapping(address => uint256)) public lastUserVote; // Last user vote's timestamp for each gauge address

    // Past and scheduled points for gauge weight, sum of weights per type, total weight
    // Point is for bias+slope
    // changes_* are for changes in slope
    // time_* are for the last change timestamp
    // timestamps are rounded to whole weeks

    mapping(address => mapping(uint256 => Point)) public pointsWeight; // gauge_addr -> time -> Point
    mapping(address => mapping(uint256 => uint256)) internal changesWeight; // gauge_addr -> time -> slope
    mapping(address => uint256) internal timeWeight; // gauge_addr -> last scheduled time (next week public time_weight;

    mapping(int128 => mapping(uint256 => Point)) public pointsSum; // type_id -> time -> Point
    mapping(int128 => mapping(uint256 => uint256)) internal changesSum; // type_id -> time -> slope
    mapping(int128 => uint256) public timeSum; // type_id -> last scheduled time (next week public time_sum;

    mapping(uint256 => uint256) public pointsTotal; // time -> total weight
    uint256 public timeTotal; // last scheduled time

    mapping(int128 => mapping(uint256 => uint256)) public pointsTypeWeight; // type_id -> time -> type weight
    mapping(int128 => uint256) public timeTypeWeight; // type_id -> last scheduled time (next week public time_type_weight;

    event AddType(string name, int128 type_id);
    event NewTypeWeight(int128 type_id, uint256 time, uint256 weight, uint256 total_weight);
    event NewGaugeWeight(address gauge_address, uint256 time, uint256 weight, uint256 total_weight);
    event VoteForGauge(uint256 time, address user, address gauge_addr, uint256 weight);
    event NewGauge(address addr, int128 gauge_type, uint256 weight);

    /**
     * @notice Contract constructor
     * @param _interval for how many seconds gauge weights will remain the same
     * @param _weightVoteDelay for how many seconds weight votes cannot be changed
     * @param _token `ERC20CRV` contract address
     * @param _veToken `VotingEscrow` contract address
     */
    constructor(uint256 _interval, uint256 _weightVoteDelay, address _token, address _veToken) {
        interval = _interval;
        weightVoteDelay = _weightVoteDelay;
        token = _token;
        veToken = _veToken;
        timeTotal = (block.timestamp / interval) * interval;
    }

    /**
     * @notice Get gauge type for address
     * @param _addr Gauge address
     * @return Gauge type id
     */
    function gaugeTypes(address _addr) external view returns (int128) {
        int128 gauge_type = _gaugeTypes[_addr];
        require(gauge_type != 0, "GC: INVALID_GAUGE_TYPE");

        return gauge_type - 1;
    }

    /**
     * @notice Get current gauge weight
     * @param addr Gauge address
     * @return Gauge weight
     */
    function getGaugeWeight(address addr) external view returns (uint256) {
        return pointsWeight[addr][timeWeight[addr]].bias;
    }

    /**
     * @notice Get current type weight
     * @param type_id Type id
     * @return Type weight
     */
    function getTypeWeight(int128 type_id) external view returns (uint256) {
        return pointsTypeWeight[type_id][timeTypeWeight[type_id]];
    }

    /**
     * @notice Get current total (type-weighted) weight
     * @return Total weight
     */
    function getTotalWeight() external view returns (uint256) {
        return pointsTotal[timeTotal];
    }

    /**
     * @notice Get sum of gauge weights per type
     * @param type_id Type id
     * @return Sum of gauge weights
     */
    function getWeightsSumPerType(int128 type_id) external view returns (uint256) {
        return pointsSum[type_id][timeSum[type_id]].bias;
    }

    /**
     * @notice Fill historic type weights week-over-week for missed checkins
     * and return the type weight for the future week
     * @param gauge_type Gauge type id
     * @return Type weight
     */
    function _getTypeWeight(int128 gauge_type) internal returns (uint256) {
        uint256 t = timeTypeWeight[gauge_type];
        if (t > 0) {
            uint256 w = pointsTypeWeight[gauge_type][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                pointsTypeWeight[gauge_type][t] = w;
                if (t > block.timestamp) timeTypeWeight[gauge_type] = t;
            }
            return w;
        } else return 0;
    }

    /**
     * @notice Fill sum of gauge weights for the same type week-over-week for
     * missed checkins and return the sum for the future week
     * @param gauge_type Gauge type id
     * @return Sum of weights
     */
    function _getSum(int128 gauge_type) internal returns (uint256) {
        uint256 t = timeSum[gauge_type];
        if (t > 0) {
            Point memory pt = pointsSum[gauge_type][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                uint256 d_bias = pt.slope * interval;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = changesSum[gauge_type][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                pointsSum[gauge_type][t] = pt;
                if (t > block.timestamp) timeSum[gauge_type] = t;
            }
            return pt.bias;
        } else return 0;
    }

    /**
     * @notice Fill historic total weights week-over-week for missed checkins
     * and return the total for the future week
     * @return Total weight
     */
    function _getTotal() internal returns (uint256) {
        uint256 t = timeTotal;
        int128 _n_gauge_types = gaugeTypeLength;
        // If we have already checkpointed - still need to change the value
        if (t > block.timestamp) t -= interval;
        uint256 pt = pointsTotal[t];

        for (int128 gauge_type; gauge_type < 100; gauge_type++) {
            if (gauge_type == _n_gauge_types) break;
            _getSum(gauge_type);
            _getTypeWeight(gauge_type);
        }

        for (uint256 i; i < 500; i++) {
            if (t > block.timestamp) break;
            t += interval;
            pt = 0;
            // Scales as n_types * n_unchecked_weeks (hopefully 1 at most)
            for (int128 gauge_type; gauge_type < 100; gauge_type++) {
                if (gauge_type == _n_gauge_types) break;
                uint256 type_sum = pointsSum[gauge_type][t].bias;
                uint256 type_weight = pointsTypeWeight[gauge_type][t];
                pt += type_sum * type_weight;
            }
            pointsTotal[t] = pt;

            if (t > block.timestamp) timeTotal = t;
        }
        return pt;
    }

    /**
     * @notice Fill historic gauge weights week-over-week for missed checkins
     * and return the total for the future week
     * @param gauge_addr Address of the gauge
     * @return Gauge weight
     */
    function _getWeight(address gauge_addr) internal returns (uint256) {
        uint256 t = timeWeight[gauge_addr];
        if (t > 0) {
            Point memory pt = pointsWeight[gauge_addr][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += interval;
                uint256 d_bias = pt.slope * interval;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = changesWeight[gauge_addr][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                pointsWeight[gauge_addr][t] = pt;
                if (t > block.timestamp) timeWeight[gauge_addr] = t;
            }
            return pt.bias;
        } else return 0;
    }

    /**
     * @notice Add gauge `addr` of type `gauge_type` with weight `weight`
     * @param addr Gauge address
     * @param gauge_type Gauge type
     */
    function addGauge(address addr, int128 gauge_type) external {
        addGauge(addr, gauge_type, 0);
    }

    /**
     * @notice Add gauge `addr` of type `gauge_type` with weight `weight`
     * @param addr Gauge address
     * @param gauge_type Gauge type
     * @param weight Gauge weight
     */
    function addGauge(
        address addr,
        int128 gauge_type,
        uint256 weight
    ) public onlyOwner {
        require((gauge_type >= 0) && (gauge_type < gaugeTypeLength), "GC: INVALID_GAUGE_TYPE");
        require(_gaugeTypes[addr] == 0, "GC: DUPLICATE_GAUGE");

        int128 n = gaugeLength;
        gaugeLength = n + 1;
        gauges[n] = addr;

        _gaugeTypes[addr] = gauge_type + 1;
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        if (weight > 0) {
            uint256 _type_weight = _getTypeWeight(gauge_type);
            uint256 _old_sum = _getSum(gauge_type);
            uint256 _old_total = _getTotal();

            pointsSum[gauge_type][next_time].bias = weight + _old_sum;
            timeSum[gauge_type] = next_time;
            pointsTotal[next_time] = _old_total + _type_weight * weight;
            timeTotal = next_time;

            pointsWeight[addr][next_time].bias = weight;
        }

        if (timeSum[gauge_type] == 0) timeSum[gauge_type] = next_time;
        timeWeight[addr] = next_time;

        emit NewGauge(addr, gauge_type, weight);
    }

    /**
     * @notice Checkpoint to fill data common for all gauges
     */
    function checkpoint() external {
        _getTotal();
    }

    /**
     * @notice Checkpoint to fill data for both a specific gauge and common for all gauges
     * @param addr Gauge address
     */
    function checkpointGauge(address addr) external {
        _getWeight(addr);
        _getTotal();
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
            int128 gauge_type = _gaugeTypes[addr] - 1;
            uint256 _type_weight = pointsTypeWeight[gauge_type][t];
            uint256 _gauge_weight = pointsWeight[addr][t].bias;
            return (MULTIPLIER * _type_weight * _gauge_weight) / _total_weight;
        } else return 0;
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Gauge address
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeight(address addr) external view returns (uint256) {
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
    function gaugeRelativeWeight(address addr, uint256 time) public view returns (uint256) {
        return _gaugeRelativeWeight(addr, time);
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param addr Gauge address
     * @return Value of relative weight normalized to 1e18
     */
    function gaugeRelativeWeightWrite(address addr) external returns (uint256) {
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
    function gaugeRelativeWeightWrite(address addr, uint256 time) public returns (uint256) {
        _getWeight(addr);
        _getTotal(); // Also calculates get_sum
        return gaugeRelativeWeight(addr, time);
    }

    /**
     * @notice Change type weight
     * @param type_id Type id
     * @param weight New type weight
     */
    function _changeTypeWeight(int128 type_id, uint256 weight) internal {
        uint256 old_weight = _getTypeWeight(type_id);
        uint256 old_sum = _getSum(type_id);
        uint256 _total_weight = _getTotal();
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        _total_weight = _total_weight + old_sum * weight - old_sum * old_weight;
        pointsTotal[next_time] = _total_weight;
        pointsTypeWeight[type_id][next_time] = weight;
        timeTotal = next_time;
        timeTypeWeight[type_id] = next_time;

        emit NewTypeWeight(type_id, next_time, weight, _total_weight);
    }

    /**
     * @notice Add gauge type with name `_name` and weight `weight`
     * @param _name Name of gauge type
     */
    function addType(string memory _name) external {
        addType(_name, 0);
    }

    /**
     * @notice Add gauge type with name `_name` and weight `weight`
     * @param _name Name of gauge type
     * @param weight Weight of gauge type
     */
    function addType(string memory _name, uint256 weight) public onlyOwner {
        int128 type_id = gaugeTypeLength;
        gaugeTypeNames[type_id] = _name;
        gaugeTypeLength = type_id + 1;
        if (weight != 0) {
            _changeTypeWeight(type_id, weight);
            emit AddType(_name, type_id);
        }
    }

    /**
     * @notice Change gauge type `type_id` weight to `weight`
     * @param type_id Gauge type id
     * @param weight New Gauge weight
     */
    function changeTypeWeight(int128 type_id, uint256 weight) external onlyOwner {
        _changeTypeWeight(type_id, weight);
    }

    function _changeGaugeWeight(address addr, uint256 weight) internal {
        // Change gauge weight
        // Only needed when testing in reality
        int128 gauge_type = _gaugeTypes[addr] - 1;
        uint256 old_gauge_weight = _getWeight(addr);
        uint256 type_weight = _getTypeWeight(gauge_type);
        uint256 old_sum = _getSum(gauge_type);
        uint256 _total_weight = _getTotal();
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;

        pointsWeight[addr][next_time].bias = weight;
        timeWeight[addr] = next_time;

        uint256 new_sum = old_sum + weight - old_gauge_weight;
        pointsSum[gauge_type][next_time].bias = new_sum;
        timeSum[gauge_type] = next_time;

        _total_weight = _total_weight + new_sum * type_weight - old_sum * type_weight;
        pointsTotal[next_time] = _total_weight;
        timeTotal = next_time;

        emit NewGaugeWeight(addr, block.timestamp, weight, _total_weight);
    }

    /**
     * @notice Change weight of gauge `addr` to `weight`
     * @param addr `GaugeController` contract address
     * @param weight New Gauge weight
     */
    function changeGaugeWeight(address addr, uint256 weight) external onlyOwner {
        _changeGaugeWeight(addr, weight);
    }

    /**
     * @notice Allocate voting power for changing pool weights
     * @param _gauge_addr Gauge which `msg.sender` votes for
     * @param _user_weight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function voteForGaugeWeights(address _gauge_addr, uint256 _user_weight) external {
        address escrow = veToken;
        uint256 slope = uint256(uint128(IVotingEscrow(escrow).getLastUserSlope(msg.sender)));
        uint256 lock_end = IVotingEscrow(escrow).unlockTime(msg.sender);
        uint256 next_time = ((block.timestamp + interval) / interval) * interval;
        require(lock_end > next_time, "GC: LOCK_EXPIRES_TOO_EARLY");
        require((_user_weight >= 0) && (_user_weight <= 10000), "GC: VOTING_POWER_ALL_USED");
        require(block.timestamp >= lastUserVote[msg.sender][_gauge_addr] + weightVoteDelay, "GC: VOTED_TOO_EARLY");

        int128 gauge_type = _gaugeTypes[_gauge_addr] - 1;
        require(gauge_type >= 0, "GC: GAUGE_NOT_ADDED");
        // Prepare slopes and biases in memory
        VotedSlope memory old_slope = voteUserSlopes[msg.sender][_gauge_addr];
        uint256 old_dt;
        if (old_slope.end > next_time) old_dt = old_slope.end - next_time;
        uint256 old_bias = old_slope.slope * old_dt;
        VotedSlope memory new_slope = VotedSlope({
            slope: (slope * _user_weight) / 10000,
            end: lock_end,
            power: _user_weight
        });
        uint256 new_bias = new_slope.slope * (lock_end - next_time);

        // Check and update powers (weights) used
        uint256 power_used = voteUserPower[msg.sender];
        power_used = power_used + new_slope.power - old_slope.power;
        voteUserPower[msg.sender] = power_used;
        require((power_used >= 0) && (power_used <= 10000), "GC: USED_TOO_MUCH_POWER");

        /// Remove old and schedule new slope changes
        _updateSlopeChanges(_gauge_addr, next_time, gauge_type, old_bias, new_bias, old_slope, new_slope);

        // Record last action time
        lastUserVote[msg.sender][_gauge_addr] = block.timestamp;

        emit VoteForGauge(block.timestamp, msg.sender, _gauge_addr, _user_weight);
    }

    function _updateSlopeChanges(
        address _gauge_addr,
        uint256 next_time,
        int128 gauge_type,
        uint256 old_bias,
        uint256 new_bias,
        VotedSlope memory old_slope,
        VotedSlope memory new_slope
    ) internal {
        // Remove slope changes for old slopes
        // Schedule recording of initial slope for next_time
        pointsWeight[_gauge_addr][next_time].bias = max(_getWeight(_gauge_addr) + new_bias, old_bias) - old_bias;
        pointsSum[gauge_type][next_time].bias = max(_getSum(gauge_type) + new_bias, old_bias) - old_bias;
        if (old_slope.end > next_time) {
            pointsWeight[_gauge_addr][next_time].slope =
                max(pointsWeight[_gauge_addr][next_time].slope + new_slope.slope, old_slope.slope) -
                old_slope.slope;
            pointsSum[gauge_type][next_time].slope =
                max(pointsSum[gauge_type][next_time].slope + new_slope.slope, old_slope.slope) -
                old_slope.slope;
        } else {
            pointsWeight[_gauge_addr][next_time].slope += new_slope.slope;
            pointsSum[gauge_type][next_time].slope += new_slope.slope;
        }
        if (old_slope.end > block.timestamp) {
            // Cancel old slope changes if they still didn't happen
            changesWeight[_gauge_addr][old_slope.end] -= old_slope.slope;
            changesSum[gauge_type][old_slope.end] -= old_slope.slope;
        }
        // Add slope changes for new slopes
        changesWeight[_gauge_addr][new_slope.end] += new_slope.slope;
        changesSum[gauge_type][new_slope.end] += new_slope.slope;

        _getTotal();

        voteUserSlopes[msg.sender][_gauge_addr] = new_slope;
    }
}
