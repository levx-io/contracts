// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./base/Base.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IVotingEscrowMigrator.sol";
import "./interfaces/IVotingEscrowDelegate.sol";
import "./libraries/Integers.sol";

/**
 * @title Voting Escrow
 * @author LevX (team@levx.io)
 * @notice Votes have a weight depending on time, so that users are
 *         committed to the future of (whatever they are voting for)
 * @dev Vote weight decays linearly over time. Lock time cannot be
 *      more than `MAXTIME`.
 * @dev Ported from vyper (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
 */

// Voting escrow to have time-weighted votes
// Votes have a weight depending on time, so that users are committed
// to the future of (whatever they are voting for).
// The weight in this implementation is linear, and lock cannot be more than maxtime:
// w ^
// 1 +        /
//   |      /
//   |    /
//   |  /
//   |/
// 0 +--------+------> time
//       maxtime

contract VotingEscrow is Ownable, ReentrancyGuard, Base, IVotingEscrow, IVotingEscrowMigrator {
    using SafeERC20 for IERC20;
    using Integers for int128;
    using Integers for uint256;

    event SetDelegateOfLegacy(address indexed legacy, address indexed delegate);
    event Migrate(address indexed account);

    struct Point {
        int128 bias;
        int128 slope; // - dweight / dt
        uint256 ts;
        uint256 blk; // block
    }

    struct LockedBalance {
        int128 amount;
        int128 discount;
        uint256 start;
        uint256 end;
    }

    int128 public constant DEPOSIT_FOR_TYPE = 0;
    int128 public constant CREATE_LOCK_TYPE = 1;
    int128 public constant INCREASE_LOCK_AMOUNT = 2;
    int128 public constant INCREASE_UNLOCK_TIME = 3;
    int128 public constant MIGRATE = 4;
    uint256 internal constant MULTIPLIER = 1e18;

    uint256 public immutable override interval;
    uint256 public immutable override maxDuration;
    address public immutable override token;
    string public override name;
    string public override symbol;
    uint8 public immutable override decimals;
    address public immutable legacy;

    mapping(address => bool) migrated;
    mapping(address => address) public delegateOfLegacy;
    mapping(address => bool) public override isDelegate;

    uint256 public override supply;
    mapping(address => address[]) public override delegateAt;
    mapping(address => LockedBalance) public override locked;
    uint256 public override epoch;

    mapping(uint256 => Point) public override pointHistory; // epoch -> unsigned point
    mapping(address => mapping(uint256 => Point)) public override userPointHistory; // user -> Point[user_epoch]
    mapping(address => uint256) public override userPointEpoch;
    mapping(uint256 => int128) public override slopeChanges; // time -> signed slope change

    constructor(
        address _token,
        string memory _name,
        string memory _symbol,
        uint256 _interval,
        uint256 _maxDuration,
        address _legacy
    ) {
        token = _token;
        name = _name;
        symbol = _symbol;
        decimals = IERC20Metadata(_token).decimals();

        interval = _interval;
        maxDuration = (_maxDuration / _interval) * _interval; // rounded down to a multiple of interval

        pointHistory[0].blk = block.number;
        pointHistory[0].ts = block.timestamp;

        legacy = _legacy;
    }

    modifier onlyDelegate {
        revertIfForbidden(isDelegate[msg.sender]);
        _;
    }

    /**
     * @notice Check if the call is from an EOA or a whitelisted smart contract, revert if not
     */
    modifier authorized {
        if (msg.sender != tx.origin) {
            revertIfForbidden(isDelegate[msg.sender]);
        }
        _;
    }

    function revertIfDiscountTooHigh(bool success) internal pure {
        if (!success) revert DiscountTooHigh();
    }

    function revertIfDiscounted(bool success) internal pure {
        if (!success) revert Discounted();
    }

    function revertIfNotExpired(bool success) internal pure {
        if (!success) revert NotExpired();
    }

    function revertIfNotPastBlock(bool success) internal pure {
        if (!success) revert NotPastBlock();
    }

    function delegateLength(address addr) external view returns (uint256) {
        return delegateAt[addr].length;
    }

    /**
     * @notice Get the most recently recorded rate of voting power decrease for `addr`
     * @param addr Address of the user wallet
     * @return Value of the slope
     */
    function getLastUserSlope(address addr) external view override returns (int128) {
        uint256 uepoch = userPointEpoch[addr];
        return userPointHistory[addr][uepoch].slope;
    }

    /**
     * @notice Get the timestamp for checkpoint `_idx` for `_addr`
     * @param _addr User wallet address
     * @param _idx User epoch number
     * @return Epoch time of the checkpoint
     */
    function getCheckpointTime(address _addr, uint256 _idx) external view override returns (uint256) {
        return userPointHistory[_addr][_idx].ts;
    }

    /**
     * @notice Get timestamp when `_addr`'s lock finishes
     * @param _addr User wallet
     * @return Epoch time of the lock end
     */
    function unlockTime(address _addr) external view override returns (uint256) {
        return locked[_addr].end;
    }

    function setDelegateOfLegacy(address _legacy, address delegate) external onlyOwner {
        delegateOfLegacy[_legacy] = delegate;

        emit SetDelegateOfLegacy(_legacy, delegate);
    }

    function setDelegate(address account, bool _isDelegate) external override onlyOwner {
        isDelegate[account] = _isDelegate;

        emit SetDelegate(account, _isDelegate);
    }

    function migrate(
        address account,
        int128 amount,
        int128 discount,
        uint256 start,
        uint256 end,
        address[] calldata delegates
    ) external override {
        revertIfForbidden(msg.sender == legacy);
        revertIfExistent(locked[account].amount == 0);

        // in case interval is different from legacy
        start = ((start + interval) / interval) * interval;
        end = (end / interval) * interval;
        if (start >= end) end += interval;

        LockedBalance memory lock = LockedBalance(amount, discount, start, end);
        locked[account] = lock;

        uint256 supply_before = supply;
        supply = supply_before + amount.toUint256();

        _checkpoint(account, LockedBalance(0, 0, 0, 0), lock);

        for (uint256 i; i < delegates.length; ) {
            address delegate = delegateOfLegacy[delegates[i]];
            if (delegate != address(0)) {
                IVotingEscrowMigrator(delegate).migrate(account, amount, discount, start, end, new address[](0));
                _pushDelegate(account, delegate);
            }
            unchecked {
                i++;
            }
        }

        emit Deposit(account, amount.toUint256(), discount.toUint256(), end, MIGRATE, block.timestamp);
        emit Supply(supply_before, supply_before + amount.toUint256());
        emit Migrate(account);
    }

    /**
     * @notice Record global and per-user data to checkpoint
     * @param addr User's wallet address. No user checkpoint if 0x0
     * @param old_locked Pevious locked amount / end lock time for the user
     * @param new_locked New locked amount / end lock time for the user
     */
    function _checkpoint(
        address addr,
        LockedBalance memory old_locked,
        LockedBalance memory new_locked
    ) internal {
        Point memory u_old;
        Point memory u_new;
        int128 old_dslope;
        int128 new_dslope;
        uint256 _epoch = epoch;

        if (addr != address(0)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                u_old.slope = old_locked.amount / maxDuration.toInt128();
                u_old.bias = u_old.slope * (old_locked.end - block.timestamp).toInt128();
            }
            if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                u_new.slope = new_locked.amount / maxDuration.toInt128();
                u_new.bias = u_new.slope * (new_locked.end - block.timestamp).toInt128();
            }

            // Read values of scheduled changes in the slope
            // old_locked.end can be in the past and in the future
            // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
            old_dslope = slopeChanges[old_locked.end];
            if (new_locked.end != 0) {
                if (new_locked.end == old_locked.end) new_dslope = old_dslope;
                else new_dslope = slopeChanges[new_locked.end];
            }
        }

        Point memory last_point = Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number});
        if (_epoch > 0) last_point = pointHistory[_epoch];
        uint256 last_checkpoint = last_point.ts;
        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initial_last_point = Point(last_point.bias, last_point.slope, last_point.ts, last_point.blk);
        uint256 block_slope; // dblock/dt
        if (block.timestamp > last_point.ts)
            block_slope = (MULTIPLIER * (block.number - last_point.blk)) / (block.timestamp - last_point.ts);
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        {
            // Go over weeks to fill history and calculate what the current point is
            uint256 t_i = (last_checkpoint / interval) * interval;
            for (uint256 i; i < 255; i++) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += interval;
                int128 d_slope;
                if (t_i > block.timestamp) t_i = block.timestamp;
                else d_slope = slopeChanges[t_i];
                last_point.bias -= last_point.slope * (t_i - last_checkpoint).toInt128();
                last_point.slope += d_slope;
                if (last_point.bias < 0)
                    // This can happen
                    last_point.bias = 0;
                if (last_point.slope < 0)
                    // This cannot happen - just in case
                    last_point.slope = 0;
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.blk = initial_last_point.blk + (block_slope * (t_i - initial_last_point.ts)) / MULTIPLIER;
                _epoch += 1;
                if (t_i == block.timestamp) {
                    last_point.blk = block.number;
                    break;
                } else pointHistory[_epoch] = last_point;
            }
        }

        epoch = _epoch;
        // Now point_history is filled until t=now

        if (addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) last_point.slope = 0;
            if (last_point.bias < 0) last_point.bias = 0;
        }

        // Record the changed point into history
        pointHistory[_epoch] = last_point;

        if (addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (old_locked.end > block.timestamp) {
                // old_dslope was <something> - u_old.slope, so we cancel that
                old_dslope += u_old.slope;
                if (new_locked.end == old_locked.end) old_dslope -= u_new.slope; // It was a new deposit, not extension
                slopeChanges[old_locked.end] = old_dslope;
            }

            if (new_locked.end > block.timestamp) {
                if (new_locked.end > old_locked.end) {
                    new_dslope -= u_new.slope; // old slope disappeared at this point
                    slopeChanges[new_locked.end] = new_dslope;
                }
                // else: we recorded it already in old_dslope
            }

            // Now handle user history
            uint256 user_epoch = userPointEpoch[addr] + 1;

            userPointEpoch[addr] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            userPointHistory[addr][user_epoch] = u_new;
        }
    }

    /**
     * @notice Deposit and lock tokens for a user
     * @param _addr User's wallet address
     * @param _value Amount to deposit
     * @param _discount Amount to get discounted out of _value
     * @param unlock_time New time when to unlock the tokens, or 0 if unchanged
     * @param locked_balance Previous locked amount / timestamp
     */
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 _discount,
        uint256 unlock_time,
        LockedBalance memory locked_balance,
        int128 _type
    ) internal {
        LockedBalance memory _locked = locked_balance;
        uint256 supply_before = supply;

        supply = supply_before + _value;
        LockedBalance memory old_locked;
        (old_locked.amount, old_locked.discount, old_locked.start, old_locked.end) = (
            _locked.amount,
            _locked.discount,
            _locked.start,
            _locked.end
        );
        // Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount += (_value).toInt128();
        if (_discount != 0) _locked.discount += _discount.toInt128();
        if (unlock_time != 0) {
            if (_locked.start == 0) _locked.start = block.timestamp;
            _locked.end = unlock_time;
        }
        locked[_addr] = _locked;

        // Possibilities:
        // Both old_locked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(_addr, old_locked, _locked);

        if (_value > _discount) {
            IERC20(token).safeTransferFrom(_addr, address(this), _value - _discount);
        }

        emit Deposit(_addr, _value, _discount, _locked.end, _type, block.timestamp);
        emit Supply(supply_before, supply_before + _value);
    }

    function _pushDelegate(address addr, address delegate) internal {
        address[] storage delegates = delegateAt[addr];
        for (uint256 i; i < delegates.length; ) {
            if (delegates[i] == delegate) return;
            unchecked {
                ++i;
            }
        }
        // if not found
        delegateAt[addr].push(delegate);
    }

    /**
     * @notice Record global data to checkpoint
     */
    function checkpoint() external override {
        _checkpoint(address(0), LockedBalance(0, 0, 0, 0), LockedBalance(0, 0, 0, 0));
    }

    /**
     * @notice Deposit `_value` tokens for `_addr` and add to the lock
     * @dev Anyone (even a smart contract) can deposit for someone else, but
     *      cannot extend their locktime and deposit for a brand new user
     * @param _addr User's wallet address
     * @param _value Amount to add to user's lock
     */
    function depositFor(address _addr, uint256 _value) external override nonReentrant {
        LockedBalance memory _locked = locked[_addr];

        revertIfInvalidAmount(_value > 0);
        revertIfNonExistent(_locked.amount > 0);
        revertIfExpired(_locked.end > block.timestamp);

        _depositFor(_addr, _value, 0, 0, _locked, DEPOSIT_FOR_TYPE);
    }

    /**
     * @notice Deposit `_value` tokens with `_discount` for `_addr` and lock for `_duration`
     * @dev Only delegates can creat a lock for someone else
     * @param _addr User's wallet address
     * @param _value Amount to add to user's lock
     * @param _discount Amount to get discounted out of _value
     * @param _duration Epoch time until tokens unlock from now
     */
    function createLockFor(
        address _addr,
        uint256 _value,
        uint256 _discount,
        uint256 _duration
    ) external override nonReentrant onlyDelegate {
        _pushDelegate(_addr, msg.sender);

        uint256 unlock_time = ((block.timestamp + _duration) / interval) * interval; // Locktime is rounded down to a multiple of interval
        LockedBalance memory _locked = locked[_addr];

        revertIfInvalidAmount(_value > 0);
        revertIfDiscountTooHigh(_value >= _discount);
        revertIfExistent(_locked.amount == 0);
        revertIfTooEarly(unlock_time > block.timestamp);
        revertIfTooLate(unlock_time <= block.timestamp + maxDuration);

        _depositFor(_addr, _value, _discount, unlock_time, _locked, CREATE_LOCK_TYPE);
    }

    /**
     * @notice Deposit `_value` tokens for `msg.sender` and lock for `_duration`
     * @param _value Amount to deposit
     * @param _duration Epoch time until tokens unlock from now
     */
    function createLock(uint256 _value, uint256 _duration) external override nonReentrant authorized {
        uint256 unlock_time = ((block.timestamp + _duration) / interval) * interval; // Locktime is rounded down to a multiple of interval
        LockedBalance memory _locked = locked[msg.sender];

        revertIfInvalidAmount(_value > 0);
        revertIfExistent(_locked.amount == 0);
        revertIfTooEarly(unlock_time > block.timestamp);
        revertIfTooLate(unlock_time <= block.timestamp + maxDuration);

        _depositFor(msg.sender, _value, 0, unlock_time, _locked, CREATE_LOCK_TYPE);
    }

    /**
     * @notice Deposit `_value` additional tokens for `_addr`
     *          without modifying the unlock time
     * @param _addr User's wallet address
     * @param _value Amount of tokens to deposit and add to the lock
     * @param _discount Amount to get discounted out of _value
     */
    function increaseAmountFor(
        address _addr,
        uint256 _value,
        uint256 _discount
    ) external override nonReentrant onlyDelegate {
        _pushDelegate(_addr, msg.sender);

        LockedBalance memory _locked = locked[_addr];

        revertIfInvalidAmount(_value > 0);
        revertIfDiscountTooHigh(_value >= _discount);
        revertIfNonExistent(_locked.amount > 0);
        revertIfExpired(_locked.end > block.timestamp);

        _depositFor(_addr, _value, _discount, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    /**
     * @notice Deposit `_value` additional tokens for `msg.sender`
     *          without modifying the unlock time
     * @param _value Amount of tokens to deposit and add to the lock
     */
    function increaseAmount(uint256 _value) external override nonReentrant authorized {
        LockedBalance memory _locked = locked[msg.sender];

        revertIfInvalidAmount(_value > 0);
        revertIfNonExistent(_locked.amount > 0);
        revertIfExpired(_locked.end > block.timestamp);

        _depositFor(msg.sender, _value, 0, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    /**
     * @notice Extend the unlock time for `msg.sender` to `_duration`
     * @param _duration Increased epoch time for unlocking
     */
    function increaseUnlockTime(uint256 _duration) external override nonReentrant authorized {
        LockedBalance memory _locked = locked[msg.sender];
        uint256 unlock_time = ((_locked.end + _duration) / interval) * interval; // Locktime is rounded down to a multiple of interval

        revertIfExpired(_locked.end > block.timestamp);
        revertIfNonExistent(_locked.amount > 0);
        revertIfDiscounted(_locked.discount == 0); // keep this line or not?
        revertIfTooEarly(unlock_time >= _locked.end + interval);
        revertIfTooLate(unlock_time <= block.timestamp + maxDuration);

        _depositFor(msg.sender, 0, 0, unlock_time, _locked, INCREASE_UNLOCK_TIME);
    }

    /**
     * @notice Withdraw all tokens for `msg.sender`
     * @dev Only possible if the lock has expired
     */
    function withdraw() external override nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];
        revertIfNotExpired(block.timestamp >= _locked.end);

        uint256 value = _locked.amount.toUint256();
        uint256 discount = _locked.discount.toUint256();

        locked[msg.sender] = LockedBalance(0, 0, 0, 0);
        uint256 supply_before = supply;
        supply = supply_before - value;

        // old_locked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, _locked, LockedBalance(0, 0, 0, 0));

        address[] storage delegates = delegateAt[msg.sender];
        for (uint256 i; i < delegates.length; ) {
            IVotingEscrowDelegate(delegates[i]).withdraw(msg.sender, 0);
            unchecked {
                ++i;
            }
        }
        delete delegateAt[msg.sender];

        if (value > discount) {
            IERC20(token).safeTransfer(msg.sender, value - discount);
        }

        emit Withdraw(msg.sender, value, discount, block.timestamp);
        emit Supply(supply_before, supply_before - value);
    }

    /**
     * @notice Binary search to estimate timestamp for block number
     * @param _block Block to find
     * @param max_epoch Don't go beyond this epoch
     * @return Approximate timestamp for block
     */
    function _findBlockEpoch(uint256 _block, uint256 max_epoch) internal view returns (uint256) {
        uint256 _min;
        uint256 _max = max_epoch;
        for (uint256 i; i < 128; i++) {
            if (_min >= _max) break;
            uint256 _mid = (_min + _max + 1) / 2;
            if (pointHistory[_mid].blk <= _block) _min = _mid;
            else _max = _mid - 1;
        }
        return _min;
    }

    function balanceOf(address addr) public view override returns (uint256) {
        return balanceOf(addr, block.timestamp);
    }

    /**
     * @notice Get the voting power for `addr`
     * @param addr User wallet address
     * @param _t Epoch time to return voting power at
     * @return User voting power
     */
    function balanceOf(address addr, uint256 _t) public view override returns (uint256) {
        uint256 _epoch = userPointEpoch[addr];
        if (_epoch == 0) return 0;
        else {
            uint256 _min;
            uint256 _max = _epoch;
            for (uint256 i; i < 128; i++) {
                if (_min >= _max) break;
                uint256 _mid = (_min + _max + 1) / 2;
                if (userPointHistory[addr][_mid].ts <= _t) _min = _mid;
                else _max = _mid - 1;
            }
            Point memory upoint = userPointHistory[addr][_min];

            upoint.bias -= upoint.slope * (_t - upoint.ts).toInt128();
            if (upoint.bias >= 0) return upoint.bias.toUint256();
            else return 0;
        }
    }

    /**
     * @notice Measure voting power of `addr` at some point in the past
     * @param addr User's wallet address
     * @param _block Block to calculate the voting power at
     * @return Voting power
     */
    function balanceOfAt(address addr, uint256 _block) external view override returns (uint256) {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        revertIfNotPastBlock(_block <= block.number);

        // Binary search
        uint256 _min;
        uint256 _max = userPointEpoch[addr];
        for (uint256 i; i < 128; i++) {
            if (_min >= _max) break;
            uint256 _mid = (_min + _max + 1) / 2;
            if (userPointHistory[addr][_mid].blk <= _block) _min = _mid;
            else _max = _mid - 1;
        }

        Point memory upoint = userPointHistory[addr][_min];

        uint256 max_epoch = epoch;
        uint256 _epoch = _findBlockEpoch(_block, max_epoch);
        Point memory point_0 = pointHistory[_epoch];
        uint256 d_block;
        uint256 d_t;
        if (_epoch < max_epoch) {
            Point memory point_1 = pointHistory[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint256 block_time = point_0.ts;
        if (d_block != 0) block_time += ((d_t * (_block - point_0.blk)) / d_block);

        upoint.bias -= upoint.slope * (block_time - upoint.ts).toInt128();
        if (upoint.bias >= 0) return upoint.bias.toUint256();
        else return 0;
    }

    /**
     * @notice Calculate total voting power at some point in the past
     * @param point The point (bias/slope) to start search from
     * @param t Time to calculate the total voting power at
     * @return Total voting power at that time
     */
    function _supplyAt(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory last_point = point;
        uint256 t_i = (last_point.ts / interval) * interval;
        for (uint256 i; i < 255; i++) {
            t_i += interval;
            int128 d_slope;
            if (t_i > t) t_i = t;
            else d_slope = slopeChanges[t_i];
            last_point.bias -= last_point.slope * (t_i - last_point.ts).toInt128();
            if (t_i == t) break;
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) last_point.bias = 0;
        return last_point.bias.toUint256();
    }

    function totalSupply() public view override returns (uint256) {
        return totalSupply(block.timestamp);
    }

    /**
     * @notice Calculate total voting power
     * @return Total voting power
     */
    function totalSupply(uint256 t) public view override returns (uint256) {
        uint256 _epoch = epoch;
        Point memory last_point = pointHistory[_epoch];
        return _supplyAt(last_point, t);
    }

    /**
     * @notice Calculate total voting power at some point in the past
     * @param _block Block to calculate the total voting power at
     * @return Total voting power at `_block`
     */
    function totalSupplyAt(uint256 _block) external view override returns (uint256) {
        revertIfNotPastBlock(_block <= block.number);
        uint256 _epoch = epoch;
        uint256 target_epoch = _findBlockEpoch(_block, _epoch);

        Point memory point = pointHistory[target_epoch];
        uint256 dt;
        if (target_epoch < _epoch) {
            Point memory point_next = pointHistory[target_epoch + 1];
            if (point.blk != point_next.blk)
                dt = ((_block - point.blk) * (point_next.ts - point.ts)) / (point_next.blk - point.blk);
        } else if (point.blk != block.number)
            dt = ((_block - point.blk) * (block.timestamp - point.ts)) / (block.number - point.blk);
        // Now dt contains info on how far are we beyond point

        return _supplyAt(point, point.ts + dt);
    }
}
