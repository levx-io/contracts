// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IFeeVault.sol";
import "./interfaces/IVotingEscrow.sol";
import "./libraries/Tokens.sol";
import "./libraries/Integers.sol";
import "./libraries/UniswapV2Helper.sol";

/**
 * @title Vault for storing fees generated from NFT trades
 * @author LevX (team@levx.io)
 */
contract FeeVault is IFeeVault {
    using Integers for uint256;

    struct Fee {
        uint64 timestamp;
        uint192 amountPerShare;
    }

    address public immutable override votingEscrow;
    address public immutable override rewardToken;
    address public immutable override swapRouter;
    address public immutable override weth;
    mapping(address => uint256) public override balances;
    mapping(address => Fee[]) public override fees; // token -> fees
    mapping(address => mapping(address => uint256)) public override lastFeeClaimed; // token -> user -> index

    constructor(address _votingEscrow, address _rewardToken, address _swapRouter) {
        votingEscrow = _votingEscrow;
        rewardToken = _rewardToken;
        swapRouter = _swapRouter;
        weth = IUniswapV2Router02(swapRouter).WETH();
    }

    receive() external payable {
        // Empty
    }

    function feesLength(address token) external view override returns (uint256) {
        return fees[token].length;
    }

    /**
     * @notice Get accumulated amount of fees to the latest
     * @param token In which currency fees were paid
     * @param user Account to check the amount of
     */
    function claimableFees(address token, address user) external view override returns (uint256 amount) {
        return claimableFees(token, user, 0);
    }

    /**
     * @notice Get accumulated amount of fees
     * @param token In which currency fees were paid
     * @param user Account to check the amount of
     * @param toIndex the last index of the fee (exclusive)
     */
    function claimableFees(address token, address user, uint256 toIndex) public view override returns (uint256 amount) {
        if (toIndex == 0) toIndex = fees[token].length;

        (int128 value, ) = IVotingEscrow(votingEscrow).locked(user);
        if (value <= 0) revert NonExistent();

        for (uint256 i = lastFeeClaimed[token][user]; i < toIndex; ) {
            Fee memory fee = fees[token][i];
            uint256 balance = IVotingEscrow(votingEscrow).balanceOf(user, fee.timestamp);
            if (balance > 0) amount += (balance * fee.amountPerShare) / 1e18;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Checkpoint increased amount of `token`
     * @param token In which currency fees were paid
     */
    function checkpoint(address token) external override {
        uint256 balance = Tokens.balanceOf(token, address(this));
        uint256 amount = balance - balances[token];

        if (amount > 0) {
            IVotingEscrow(votingEscrow).checkpoint();
            fees[token].push(
                Fee(uint64(block.timestamp), ((amount * 1e18) / IVotingEscrow(votingEscrow).totalSupply()).toUint192())
            );
            balances[token] = balance;

            emit Checkpoint(token, fees[token].length - 1, amount);
        }
    }

    /**
     * @notice Claim accumulated fees
     * @param token In which currency fees were paid
     * @param toIndex the last index of the fee (exclusive)
     * @param amountRewardMin Minimum amount of reward after swapping
     * @param path Route for swapping fees
     * @param deadline Expiration timestamp
     */
    function claimFees(
        address token,
        uint256 toIndex,
        uint256 amountRewardMin,
        address[] calldata path,
        uint256 deadline
    ) external override {
        if (toIndex >= fees[token].length) revert OutOfRange();
        if (path[0] != (token == address(0) ? weth : token)) revert InvalidPath();
        if (path[path.length - 1] != rewardToken) revert InvalidPath();

        uint256 amount = claimableFees(token, msg.sender, toIndex);
        lastFeeClaimed[token][msg.sender] = toIndex;

        if (amount > 0) {
            uint256[] memory amounts = UniswapV2Helper.swap(swapRouter, token, amount, amountRewardMin, path, deadline);
            emit ClaimFees(token, amount, amounts[amounts.length - 1], msg.sender);
        }
    }
}
