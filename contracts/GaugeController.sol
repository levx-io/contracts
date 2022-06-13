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

    // 7 * 86400 seconds - all future times are rounded by week
    uint256 public constant WEEK = 604800;
    // Cannot change weight votes more often than once in 10 days
    uint256 public constant WEIGHT_VOTE_DELAY = 10 * 86400;
    uint256 internal constant MULTIPLIER = 10**18;

    address public token; // CRV token
    address public voting_escrow; // Voting escrow

    // Gauge parameters
    // All numbers are "fixed point" on the basis of 1e18
    int128 public n_gauge_types;
    int128 public n_gauges;
    mapping(int128 => string) public gauge_type_names;

    // Needed for enumeration
    mapping(int128 => address) public gauges;

    // we increment values by 1 prior to storing them here so we can rely on a value
    // of zero as meaning the gauge has not been set
    mapping(address => int128) internal gauge_types_;

    mapping(address => mapping(address => VotedSlope)) public vote_user_slopes; // user -> gauge_addr -> VotedSlope
    mapping(address => uint256) public vote_user_power; // Total vote power used by user
    mapping(address => mapping(address => uint256)) public last_user_vote; // Last user vote's timestamp for each gauge address

    // Past and scheduled points for gauge weight, sum of weights per type, total weight
    // Point is for bias+slope
    // changes_* are for changes in slope
    // time_* are for the last change timestamp
    // timestamps are rounded to whole weeks

    mapping(address => mapping(uint256 => Point)) public points_weight; // gauge_addr -> time -> Point
    mapping(address => mapping(uint256 => uint256)) internal changes_weight; // gauge_addr -> time -> slope
    mapping(address => uint256) internal time_weight; // gauge_addr -> last scheduled time (next week public time_weight;

    mapping(int128 => mapping(uint256 => Point)) public points_sum; // type_id -> time -> Point
    mapping(int128 => mapping(uint256 => uint256)) internal changes_sum; // type_id -> time -> slope
    mapping(int128 => uint256) public time_sum; // type_id -> last scheduled time (next week public time_sum;

    mapping(uint256 => uint256) public points_total; // time -> total weight
    uint256 public time_total; // last scheduled time

    mapping(int128 => mapping(uint256 => uint256)) public points_type_weight; // type_id -> time -> type weight
    mapping(int128 => uint256) public time_type_weight; // type_id -> last scheduled time (next week public time_type_weight;

    event AddType(string name, int128 type_id);
    event NewTypeWeight(int128 type_id, uint256 time, uint256 weight, uint256 total_weight);
    event NewGaugeWeight(address gauge_address, uint256 time, uint256 weight, uint256 total_weight);
    event VoteForGauge(uint256 time, address user, address gauge_addr, uint256 weight);
    event NewGauge(address addr, int128 gauge_type, uint256 weight);

    /**
     * @notice Contract constructor
     * @param _token `ERC20CRV` contract address
     * @param _voting_escrow `VotingEscrow` contract address
     */
    constructor(address _token, address _voting_escrow) {
        token = _token;
        voting_escrow = _voting_escrow;
        time_total = (block.timestamp / WEEK) * WEEK;
    }

    /**
     * @notice Get gauge type for address
     * @param _addr Gauge address
     * @return Gauge type id
     */
    function gauge_types(address _addr) external view returns (int128) {
        int128 gauge_type = gauge_types_[_addr];
        require(gauge_type != 0, "GC: INVALID_GAUGE_TYPE");

        return gauge_type - 1;
    }

    /**
     * @notice Fill historic type weights week-over-week for missed checkins
     * and return the type weight for the future week
     * @param gauge_type Gauge type id
     * @return Type weight
     */
    function _get_type_weight(int128 gauge_type) internal returns (uint256) {
        uint256 t = time_type_weight[gauge_type];
        if (t > 0) {
            uint256 w = points_type_weight[gauge_type][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += WEEK;
                points_type_weight[gauge_type][t] = w;
                if (t > block.timestamp) time_type_weight[gauge_type] = t;
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
    function _get_sum(int128 gauge_type) internal returns (uint256) {
        uint256 t = time_sum[gauge_type];
        if (t > 0) {
            Point memory pt = points_sum[gauge_type][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += WEEK;
                uint256 d_bias = pt.slope * WEEK;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = changes_sum[gauge_type][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                points_sum[gauge_type][t] = pt;
                if (t > block.timestamp) time_sum[gauge_type] = t;
            }
            return pt.bias;
        } else return 0;
    }

    /**
     * @notice Fill historic total weights week-over-week for missed checkins
     * and return the total for the future week
     * @return Total weight
     */
    function _get_total() internal returns (uint256) {
        uint256 t = time_total;
        int128 _n_gauge_types = n_gauge_types;
        // If we have already checkpointed - still need to change the value
        if (t > block.timestamp) t -= WEEK;
        uint256 pt = points_total[t];

        for (int128 gauge_type; gauge_type < 100; gauge_type++) {
            if (gauge_type == _n_gauge_types) break;
            _get_sum(gauge_type);
            _get_type_weight(gauge_type);
        }

        for (uint256 i; i < 500; i++) {
            if (t > block.timestamp) break;
            t += WEEK;
            pt = 0;
            // Scales as n_types * n_unchecked_weeks (hopefully 1 at most)
            for (int128 gauge_type; gauge_type < 100; gauge_type++) {
                if (gauge_type == _n_gauge_types) break;
                uint256 type_sum = points_sum[gauge_type][t].bias;
                uint256 type_weight = points_type_weight[gauge_type][t];
                pt += type_sum * type_weight;
            }
            points_total[t] = pt;

            if (t > block.timestamp) time_total = t;
        }
        return pt;
    }

    /**
     * @notice Fill historic gauge weights week-over-week for missed checkins
     * and return the total for the future week
     * @param gauge_addr Address of the gauge
     * @return Gauge weight
     */
    function _get_weight(address gauge_addr) internal returns (uint256) {
        uint256 t = time_weight[gauge_addr];
        if (t > 0) {
            Point memory pt = points_weight[gauge_addr][t];
            for (uint256 i; i < 500; i++) {
                if (t > block.timestamp) break;
                t += WEEK;
                uint256 d_bias = pt.slope * WEEK;
                if (pt.bias > d_bias) {
                    pt.bias -= d_bias;
                    uint256 d_slope = changes_weight[gauge_addr][t];
                    pt.slope -= d_slope;
                } else {
                    pt.bias = 0;
                    pt.slope = 0;
                }
                points_weight[gauge_addr][t] = pt;
                if (t > block.timestamp) time_weight[gauge_addr] = t;
            }
            return pt.bias;
        } else return 0;
    }

    /**
     * @notice Add gauge `addr` of type `gauge_type` with weight `weight`
     * @param addr Gauge address
     * @param gauge_type Gauge type
     */
    function add_gauge(address addr, int128 gauge_type) external {
        add_gauge(addr, gauge_type, 0);
    }

    /**
     * @notice Add gauge `addr` of type `gauge_type` with weight `weight`
     * @param addr Gauge address
     * @param gauge_type Gauge type
     * @param weight Gauge weight
     */
    function add_gauge(
        address addr,
        int128 gauge_type,
        uint256 weight
    ) public onlyOwner {
        require((gauge_type >= 0) && (gauge_type < n_gauge_types), "GC: INVALID_GAUGE_TYPE");
        require(gauge_types_[addr] == 0, "GC: DUPLICATE_GAUGE");

        int128 n = n_gauges;
        n_gauges = n + 1;
        gauges[n] = addr;

        gauge_types_[addr] = gauge_type + 1;
        uint256 next_time = ((block.timestamp + WEEK) / WEEK) * WEEK;

        if (weight > 0) {
            uint256 _type_weight = _get_type_weight(gauge_type);
            uint256 _old_sum = _get_sum(gauge_type);
            uint256 _old_total = _get_total();

            points_sum[gauge_type][next_time].bias = weight + _old_sum;
            time_sum[gauge_type] = next_time;
            points_total[next_time] = _old_total + _type_weight * weight;
            time_total = next_time;

            points_weight[addr][next_time].bias = weight;
        }

        if (time_sum[gauge_type] == 0) time_sum[gauge_type] = next_time;
        time_weight[addr] = next_time;

        emit NewGauge(addr, gauge_type, weight);
    }

    /**
     * @notice Checkpoint to fill data common for all gauges
     */
    function checkpoint() external {
        _get_total();
    }

    /**
     * @notice Checkpoint to fill data for both a specific gauge and common for all gauges
     * @param addr Gauge address
     */
    function checkpoint_gauge(address addr) external {
        _get_weight(addr);
        _get_total();
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Gauge address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function _gauge_relative_weight(address addr, uint256 time) internal view returns (uint256) {
        uint256 t = (time / WEEK) * WEEK;
        uint256 _total_weight = points_total[t];

        if (_total_weight > 0) {
            int128 gauge_type = gauge_types_[addr] - 1;
            uint256 _type_weight = points_type_weight[gauge_type][t];
            uint256 _gauge_weight = points_weight[addr][t].bias;
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
    function gauge_relative_weight(address addr) external view returns (uint256) {
        return _gauge_relative_weight(addr, block.timestamp);
    }

    /**
     * @notice Get Gauge relative weight (not more than 1.0) normalized to 1e18
     * (e.g. 1.0 == 1e18). Inflation which will be received by it is
     * inflation_rate * relative_weight / 1e18
     * @param addr Gauge address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function gauge_relative_weight(address addr, uint256 time) public view returns (uint256) {
        return _gauge_relative_weight(addr, time);
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param addr Gauge address
     * @return Value of relative weight normalized to 1e18
     */
    function gauge_relative_weight_write(address addr) external returns (uint256) {
        return gauge_relative_weight_write(addr, block.timestamp);
    }

    /**
     * @notice Get gauge weight normalized to 1e18 and also fill all the unfilled
    values for type and gauge records
     * @dev Any address can call, however nothing is recorded if the values are filled already
     * @param addr Gauge address
     * @param time Relative weight at the specified timestamp in the past or present
     * @return Value of relative weight normalized to 1e18
     */
    function gauge_relative_weight_write(address addr, uint256 time) public returns (uint256) {
        _get_weight(addr);
        _get_total(); // Also calculates get_sum
        return _gauge_relative_weight(addr, time);
    }

    /**
     * @notice Change type weight
     * @param type_id Type id
     * @param weight New type weight
     */
    function _change_type_weight(int128 type_id, uint256 weight) internal {
        uint256 old_weight = _get_type_weight(type_id);
        uint256 old_sum = _get_sum(type_id);
        uint256 _total_weight = _get_total();
        uint256 next_time = ((block.timestamp + WEEK) / WEEK) * WEEK;

        _total_weight = _total_weight + old_sum * weight - old_sum * old_weight;
        points_total[next_time] = _total_weight;
        points_type_weight[type_id][next_time] = weight;
        time_total = next_time;
        time_type_weight[type_id] = next_time;

        emit NewTypeWeight(type_id, next_time, weight, _total_weight);
    }

    /**
     * @notice Add gauge type with name `_name` and weight `weight`
     * @param _name Name of gauge type
     */
    function add_type(string memory _name) external {
        add_type(_name, 0);
    }

    /**
     * @notice Add gauge type with name `_name` and weight `weight`
     * @param _name Name of gauge type
     * @param weight Weight of gauge type
     */
    function add_type(string memory _name, uint256 weight) public onlyOwner {
        int128 type_id = n_gauge_types;
        gauge_type_names[type_id] = _name;
        n_gauge_types = type_id + 1;
        if (weight != 0) {
            _change_type_weight(type_id, weight);
            emit AddType(_name, type_id);
        }
    }

    /**
     * @notice Change gauge type `type_id` weight to `weight`
     * @param type_id Gauge type id
     * @param weight New Gauge weight
     */
    function change_type_weight(int128 type_id, uint256 weight) external onlyOwner {
        _change_type_weight(type_id, weight);
    }

    function _change_gauge_weight(address addr, uint256 weight) internal {
        // Change gauge weight
        // Only needed when testing in reality
        int128 gauge_type = gauge_types_[addr] - 1;
        uint256 old_gauge_weight = _get_weight(addr);
        uint256 type_weight = _get_type_weight(gauge_type);
        uint256 old_sum = _get_sum(gauge_type);
        uint256 _total_weight = _get_total();
        uint256 next_time = ((block.timestamp + WEEK) / WEEK) * WEEK;

        points_weight[addr][next_time].bias = weight;
        time_weight[addr] = next_time;

        uint256 new_sum = old_sum + weight - old_gauge_weight;
        points_sum[gauge_type][next_time].bias = new_sum;
        time_sum[gauge_type] = next_time;

        _total_weight = _total_weight + new_sum * type_weight - old_sum * type_weight;
        points_total[next_time] = _total_weight;
        time_total = next_time;

        emit NewGaugeWeight(addr, block.timestamp, weight, _total_weight);
    }

    /**
     * @notice Change weight of gauge `addr` to `weight`
     * @param addr `GaugeController` contract address
     * @param weight New Gauge weight
     */
    function change_gauge_weight(address addr, uint256 weight) external onlyOwner {
        _change_gauge_weight(addr, weight);
    }

    /**
     * @notice Allocate voting power for changing pool weights
     * @param _gauge_addr Gauge which `msg.sender` votes for
     * @param _user_weight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function vote_for_gauge_weights(address _gauge_addr, uint256 _user_weight) external {
        address escrow = voting_escrow;
        uint256 slope = uint256(uint128(IVotingEscrow(escrow).getLastUserSlope(msg.sender)));
        uint256 lock_end = IVotingEscrow(escrow).unlockTime(msg.sender);
        uint256 next_time = ((block.timestamp + WEEK) / WEEK) * WEEK;
        require(lock_end > next_time, "GC: LOCK_EXPIRES_TOO_EARLY");
        require((_user_weight >= 0) && (_user_weight <= 10000), "GC: VOTING_POWER_ALL_USED");
        require(block.timestamp >= last_user_vote[msg.sender][_gauge_addr] + WEIGHT_VOTE_DELAY, "GC: VOTED_TOO_EARLY");

        int128 gauge_type = gauge_types_[_gauge_addr] - 1;
        require(gauge_type >= 0, "GC: GAUGE_NOT_ADDED");
        // Prepare slopes and biases in memory
        VotedSlope memory old_slope = vote_user_slopes[msg.sender][_gauge_addr];
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
        uint256 power_used = vote_user_power[msg.sender];
        power_used = power_used + new_slope.power - old_slope.power;
        vote_user_power[msg.sender] = power_used;
        require((power_used >= 0) && (power_used <= 10000), "GC: USED_TOO_MUCH_POWER");

        /// Remove old and schedule new slope changes
        _update_slope_changes(_gauge_addr, next_time, gauge_type, old_bias, new_bias, old_slope, new_slope);

        // Record last action time
        last_user_vote[msg.sender][_gauge_addr] = block.timestamp;

        emit VoteForGauge(block.timestamp, msg.sender, _gauge_addr, _user_weight);
    }

    function _update_slope_changes(
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
        points_weight[_gauge_addr][next_time].bias = max(_get_weight(_gauge_addr) + new_bias, old_bias) - old_bias;
        points_sum[gauge_type][next_time].bias = max(_get_sum(gauge_type) + new_bias, old_bias) - old_bias;
        if (old_slope.end > next_time) {
            points_weight[_gauge_addr][next_time].slope =
                max(points_weight[_gauge_addr][next_time].slope + new_slope.slope, old_slope.slope) -
                old_slope.slope;
            points_sum[gauge_type][next_time].slope =
                max(points_sum[gauge_type][next_time].slope + new_slope.slope, old_slope.slope) -
                old_slope.slope;
        } else {
            points_weight[_gauge_addr][next_time].slope += new_slope.slope;
            points_sum[gauge_type][next_time].slope += new_slope.slope;
        }
        if (old_slope.end > block.timestamp) {
            // Cancel old slope changes if they still didn't happen
            changes_weight[_gauge_addr][old_slope.end] -= old_slope.slope;
            changes_sum[gauge_type][old_slope.end] -= old_slope.slope;
        }
        // Add slope changes for new slopes
        changes_weight[_gauge_addr][new_slope.end] += new_slope.slope;
        changes_sum[gauge_type][new_slope.end] += new_slope.slope;

        _get_total();

        vote_user_slopes[msg.sender][_gauge_addr] = new_slope;
    }

    /**
     * @notice Get current gauge weight
     * @param addr Gauge address
     * @return Gauge weight
     */
    function get_gauge_weight(address addr) external view returns (uint256) {
        return points_weight[addr][time_weight[addr]].bias;
    }

    /**
     * @notice Get current type weight
     * @param type_id Type id
     * @return Type weight
     */
    function get_type_weight(int128 type_id) external view returns (uint256) {
        return points_type_weight[type_id][time_type_weight[type_id]];
    }

    /**
     * @notice Get current total (type-weighted) weight
     * @return Total weight
     */
    function get_total_weight() external view returns (uint256) {
        return points_total[time_total];
    }

    /**
     * @notice Get sum of gauge weights per type
     * @param type_id Type id
     * @return Sum of gauge weights
     */
    function get_weights_sum_per_type(int128 type_id) external view returns (uint256) {
        return points_sum[type_id][time_sum[type_id]].bias;
    }
}
