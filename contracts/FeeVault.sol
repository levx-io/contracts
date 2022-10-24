// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IVotingEscrow.sol";
import "./interfaces/IFeeVault.sol";
import "./libraries/Tokens.sol";
import "./libraries/Integers.sol";

contract FeeVault is IFeeVault {
    using Integers for uint256;

    struct Fee {
        uint64 timestamp;
        uint192 amountPerShare;
    }

    address public immutable override weth;
    address public immutable override votingEscrow;
    mapping(address => uint256) public override balances;
    mapping(address => Fee[]) public override fees;
    mapping(address => mapping(address => uint256)) public override lastFeeClaimed;

    constructor(address _weth, address _votingEscrow) {
        weth = _weth;
        votingEscrow = _votingEscrow;
    }

    receive() external payable {
        // Empty
    }

    function feesLength(address token) external view override returns (uint256) {
        return fees[token].length;
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
     * @param to the last index of the fee (exclusive)
     */
    function claimFees(address token, uint256 to) external override {
        require(to < fees[token].length, "FV: INDEX_OUT_OF_RANGE");

        uint256 from = lastFeeClaimed[token][msg.sender];

        (int128 value, , uint256 start, ) = IVotingEscrow(votingEscrow).locked(msg.sender);
        require(value > 0, "FV: LOCK_NOT_FOUND");

        uint256 amount;
        for (uint256 i = from; i < to; ) {
            Fee memory fee = fees[token][i];
            if (start < fee.timestamp) {
                uint256 balance = IVotingEscrow(votingEscrow).balanceOf(msg.sender, fee.timestamp);
                if (balance > 0) amount += (balance * fee.amountPerShare) / 1e18;
            }
            unchecked {
                ++i;
            }
        }
        lastFeeClaimed[token][msg.sender] = to;

        emit ClaimFees(token, amount, msg.sender);
        Tokens.safeTransfer(token, msg.sender, amount, weth);
    }
}
