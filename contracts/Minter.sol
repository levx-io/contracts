// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./interfaces/IMinter.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/INFTGauge.sol";

interface IToken {
    function mint(address account, uint256 value) external;
}

/**
 * @title Token Minter
 * @author LevX (team@levx.io)
 */
contract Minter is IMinter {
    uint256 internal constant RATE_DENOMINATOR = 1e18;
    uint256 internal constant INFLATION_DELAY = 86400;

    address public immutable override token;
    address public immutable override controller;
    uint256 public immutable override initialSupply;
    uint256 public immutable override initialRate;
    uint256 public immutable override rateReductionTime;
    uint256 public immutable override rateReductionCoefficient;

    address public override dev;
    int128 public override miningEpoch;
    uint256 public override startEpochTime;
    uint256 public override rate;

    uint256 public override mintedTotal;
    uint256 public override mintedDevFee;
    mapping(address => mapping(uint256 => mapping(address => uint256))) public override minted; // gauge -> tokenId -> user -> amount

    uint256 internal startEpochSupply;

    constructor(
        address _token,
        address _controller,
        uint256 _initialSupply,
        uint256 _initialRate,
        uint256 _rateReductionTime,
        uint256 _rateReductionCoefficient,
        address _dev
    ) {
        token = _token;
        controller = _controller;
        initialSupply = _initialSupply;
        initialRate = _initialRate;
        rateReductionTime = _rateReductionTime;
        rateReductionCoefficient = _rateReductionCoefficient;
        dev = _dev;

        startEpochTime = block.timestamp + INFLATION_DELAY - rateReductionTime;
        miningEpoch = -1;
        rate = 0;
        startEpochSupply = initialSupply;
    }

    /**
     * @notice Current number of tokens in existence (claimed or unclaimed)
     */
    function availableSupply() external view override returns (uint256) {
        return _availableSupply();
    }

    /**
     * @notice How much supply is mintable from start timestamp till end timestamp
     * @param start Start of the time interval (timestamp)
     * @param end End of the time interval (timestamp)
     * @return Tokens mintable from `start` till `end`
     */
    function mintableInTimeframe(uint256 start, uint256 end) external view returns (uint256) {
        if (start > end) revert InvalidTimeRange();
        uint256 toMint = 0;
        uint256 currentEpochTime = startEpochTime;
        uint256 currentRate = rate;

        // Special case if end is in future (not yet minted) epoch
        if (end > currentEpochTime + rateReductionTime) {
            currentEpochTime += rateReductionTime;
            currentRate = (currentRate * RATE_DENOMINATOR) / rateReductionCoefficient;
        }

        if (end > currentEpochTime + rateReductionTime) revert TooLate();

        // Number of rate changes MUST be less than 10,000
        for (uint256 i; i < 10000; ) {
            if (end >= currentEpochTime) {
                uint256 currentEnd = end;
                if (currentEnd > currentEpochTime + rateReductionTime)
                    currentEnd = currentEpochTime + rateReductionTime;

                uint256 currentStart = start;
                if (currentStart >= currentEpochTime + rateReductionTime) break;
                else if (currentStart < currentEpochTime) currentStart = currentEpochTime;

                toMint += currentRate * (currentEnd - currentStart);

                if (start >= currentEpochTime) break;
            }

            currentEpochTime -= rateReductionTime;
            currentRate = (currentRate * rateReductionCoefficient) / RATE_DENOMINATOR; // double-division with rounding made rate a bit less => good
            assert(currentRate <= initialRate);

            unchecked {
                ++i;
            }
        }

        return toMint;
    }

    /**
     * @notice Update the dev address to receive 3.33% emissions
     * @param newDev new dev address
     */
    function updateDev(address newDev) external override {
        if (msg.sender != dev) revert Forbidden();
        dev = newDev;
        emit UpdateDev(newDev);
    }

    /**
     * @notice Update mining rate and supply at the start of the epoch
     * @dev Callable by any address, but only once per epoch
     *      Total supply becomes slightly larger if this function is called late
     */
    function updateMiningParameters() external override {
        if (block.timestamp < startEpochTime + rateReductionTime) revert TooEarly();
        _updateMiningParameters();
    }

    /**
     * @notice Get timestamp of the current mining epoch start
     *         while simultaneously updating mining parameters
     * @return Timestamp of the epoch
     */
    function startEpochTimeWrite() external override returns (uint256) {
        uint256 _startEpochTime = startEpochTime;
        if (block.timestamp >= _startEpochTime + rateReductionTime) {
            _updateMiningParameters();
            return startEpochTime;
        } else return _startEpochTime;
    }

    /**
     * @notice Get timestamp of the next mining epoch start
     *         while simultaneously updating mining parameters
     * @return Timestamp of the next epoch
     */
    function futureEpochTimeWrite() external override returns (uint256) {
        uint256 _startEpochTime = startEpochTime;
        if (block.timestamp >= _startEpochTime + rateReductionTime) {
            _updateMiningParameters();
            return startEpochTime + rateReductionTime;
        } else return _startEpochTime + rateReductionTime;
    }

    /**
     * @notice Mint everything which belongs to `msg.sender` and send to them
     * @param gaugeAddr `NFTGauge` address to get mintable amount from
     * @param tokenId tokenId
     */
    function mint(address gaugeAddr, uint256 tokenId) external override {
        if (IGaugeController(controller).gaugeTypes(gaugeAddr) < 0) revert NonExistent();

        INFTGauge(gaugeAddr).userCheckpoint(tokenId, msg.sender);
        uint256 totalMint = INFTGauge(gaugeAddr).integrateFraction(tokenId, msg.sender);
        uint256 toMint = totalMint - minted[gaugeAddr][tokenId][msg.sender];
        if (toMint <= 0) revert NoAmountToMint();

        mintedTotal += toMint;
        minted[gaugeAddr][tokenId][msg.sender] = totalMint;

        emit Minted(msg.sender, gaugeAddr, tokenId, totalMint);
        IToken(token).mint(msg.sender, toMint);
    }

    /**
     * @notice Mint dev fee (3.33% of total amount minted)
     */
    function mintDevFee() external override {
        uint256 totalMint = mintedTotal / 33;
        uint256 toMint = totalMint - mintedDevFee;
        if (toMint <= 0) revert NoAmountToMint();

        mintedDevFee = totalMint;

        emit MintedDevFee(dev, totalMint);
        IToken(token).mint(dev, toMint);
    }

    function _availableSupply() internal view returns (uint256) {
        return startEpochSupply + (block.timestamp - startEpochTime) * rate;
    }

    /**
     * @dev Update mining rate and supply at the start of the epoch
     *      Any modifying mining call must also call this
     */
    function _updateMiningParameters() internal {
        uint256 _rate = rate;
        uint256 _startEpochSupply = startEpochSupply;

        startEpochTime += rateReductionTime;
        miningEpoch += 1;

        if (_rate == 0) _rate = initialRate;
        else {
            _startEpochSupply += _rate * rateReductionTime;
            startEpochSupply = _startEpochSupply;
            _rate = (_rate * RATE_DENOMINATOR) / rateReductionCoefficient;
        }

        rate = _rate;

        emit UpdateMiningParameters(block.timestamp, _rate, _startEpochSupply);
    }
}
