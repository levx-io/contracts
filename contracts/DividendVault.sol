// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./base/Base.sol";
import "./interfaces/IDividendVault.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IUniswapV2Router02.sol";
import "./libraries/Tokens.sol";
import "./libraries/Integers.sol";
import "./libraries/UniswapV2Helper.sol";

contract DividendVault is Base, IDividendVault {
    using Integers for uint256;

    struct Dividend {
        uint256 tokenId;
        uint64 timestamp;
        uint192 amountPerShare;
    }

    address public immutable override votingEscrow;
    address public immutable override rewardToken;
    address public immutable override swapRouter;
    address public immutable override weth;
    uint256 internal immutable _interval;

    mapping(address => uint256) public override balances;
    mapping(address => mapping(address => Dividend[])) public override dividends; // token -> gauge -> Dividend
    mapping(address => mapping(address => mapping(address => uint256))) public override lastDividendClaimed; // token -> gauge -> user -> index

    constructor(
        address _votingEscrow,
        address _rewardToken,
        address _swapRouter
    ) {
        votingEscrow = _votingEscrow;
        rewardToken = _rewardToken;
        swapRouter = _swapRouter;
        weth = IUniswapV2Router02(swapRouter).WETH();
        _interval = IVotingEscrow(_votingEscrow).interval();
    }

    receive() external payable {
        // Empty
    }

    function dividendsLength(address token, address gauge) external view override returns (uint256) {
        return dividends[token][gauge].length;
    }

    /**
     * @notice Get accumulated amount of dividends
     * @param token In which currency dividends were paid
     * @param user Account to check the amount of
     * @param gauges From which gauge dividends were generated (array)
     */
    function claimableDividends(
        address token,
        address user,
        address[] memory gauges
    ) public view override returns (uint256 amount) {
        return claimableDividends(token, user, gauges, new uint256[](gauges.length));
    }

    /**
     * @notice Checkpoint increased amount of `token`
     * @param token In which currency dividends were paid
     * @param user Account to check the amount of
     * @param gauges From which gauge dividends generated (array)
     * @param toIndices the last index of the fee (exclusive; array)
     */
    function claimableDividends(
        address token,
        address user,
        address[] memory gauges,
        uint256[] memory toIndices
    ) public view override returns (uint256 amount) {
        for (uint256 i; i < gauges.length; ) {
            address gauge = gauges[i];
            uint256 toIndex = toIndices[i];
            revertIfOutOfRange(toIndex < dividends[token][gauge].length);
            if (toIndex == 0) toIndex = dividends[token][gauge].length;

            for (uint256 j = lastDividendClaimed[token][gauge][msg.sender]; j < toIndex; ) {
                Dividend memory dividend = dividends[token][gauge][j];
                uint256 balance = IVotingEscrow(votingEscrow).balanceOfAt(msg.sender, dividend.timestamp);
                if (balance > 0) {
                    uint256 userWeight = INFTGauge(gauge).userWeightAt(dividend.tokenId, user, dividend.timestamp);
                    amount += (balance * userWeight * dividend.amountPerShare) / 10000 / 1e18;
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Checkpoint increased amount of `token` for `gauge`'s `tokenId`
     * @param token In which currency dividends were paid
     * @param gauge From which gauge dividends were generated
     * @param tokenId From which tokenId dividends were generated
     */
    function checkpoint(
        address token,
        address gauge,
        uint256 tokenId
    ) external override {
        uint256 balance = Tokens.balanceOf(token, address(this));
        uint256 amount = balance - balances[token];

        if (amount > 0) {
            uint256 time = (block.timestamp / _interval) * _interval;
            (uint256 sum, ) = INFTGauge(gauge).pointsSum(tokenId, time);
            if (sum > 0) {
                dividends[token][gauge].push(Dividend(tokenId, uint64(time), ((amount * 1e18) / sum).toUint192()));
            }
            balances[token] = balance;

            emit Checkpoint(token, gauge, tokenId, dividends[token][gauge].length - 1, amount);
        }
    }

    /**
     * @notice Claim accumulated fees
     * @param token In which currency fees were paid
     * @param gauges From which gauge dividends were generated (array)
     * @param toIndices the last index of the fee (exclusive; array)
     * @param amountRewardMin Minimum amount of reward after swapping
     * @param path Route for swapping fees
     * @param deadline Expiration timestamp
     */
    function claimDividends(
        address token,
        address[] calldata gauges,
        uint256[] calldata toIndices,
        uint256 amountRewardMin,
        address[] calldata path,
        uint256 deadline
    ) external override {
        revertIfInvalidPath(path[0] == (token == address(0) ? weth : token));
        revertIfInvalidPath(path[path.length - 1] == rewardToken);

        uint256 amount = claimableDividends(token, msg.sender, gauges, toIndices);
        for (uint256 i; i < gauges.length; ) {
            address gauge = gauges[i];
            uint256 toIndex = toIndices[i];
            if (toIndex == 0) toIndex = dividends[token][gauge].length;
            lastDividendClaimed[token][gauge][msg.sender] = toIndex;
            unchecked {
                ++i;
            }
        }

        if (amount > 0) {
            uint256[] memory amounts = UniswapV2Helper.swap(swapRouter, token, amount, amountRewardMin, path, deadline);
            emit ClaimDividends(token, amount, amounts[amounts.length - 1], msg.sender);
        }
    }
}
