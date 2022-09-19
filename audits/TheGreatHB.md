# Audit by [TheGreatHB](https://twitter.com/TheGreatHB_)

## Code repository
[https://github.com/levxdao/ve](https://github.com/levxdao/ve)

## Review commit hash
[a007173e5d9cfc9d8f8983f256c9ca2f516c3fe4](https://github.com/levxdao/ve/tree/a007173e5d9cfc9d8f8983f256c9ca2f516c3fe4)

## Review scope
    + contracts/base/CloneFactory.sol
    + contracts/base/ERC721Initializable.sol
    + contracts/base/WrappedERC721.sol
    + contracts/libraries/Base64.sol
    + contracts/libraries/Errors.sol
    + contracts/libraries/Integers.sol
    + contracts/libraries/Math.sol
    + contracts/libraries/NFTs.sol
    + contracts/libraries/Signature.sol
    + contracts/libraries/Tokens.sol
    + contracts/libraries/VotingEscrowHelper.sol
    + contracts/GaugeController.sol
    + contracts/Minter.sol
    + contracts/NFTGauge.sol
    + contracts/NFTGaugeFactory.sol

### WrappedERC721
1. Unnecessary Signature Import *[Optimization]*
    + Signature is not used.

2. In listForSale, currency is limited to ETH only. ***[Important]***
    + No Buy, Bid functions required.

3. In listForSale, price can also be entered as 0. ***[Important]***

4. A problem that occurs when ETH transfer fails in `_bid()`. ***[Important]***
    + If there is a previous bid, the bid amount is returned to the previous bidder. At this time, if the currency is ETH and the bidder is a Contract so that it is impossible to receive the transfer, additional bids cannot occur afterwards. See Noun's code (https://github.com/nounsDAO/nouns-monorepo/blob/master/packages/nouns-contracts/contracts/NounsAuctionHouse.sol#L243-L260)

5. Invalid parameter in `Tokens.transfer()` in `claim()` ***[Important]***
    + The owner address is entered in the location of the token address.

6. NFT transfer is missing in `claim()` ***[Important]***

7. When claim calls `_settle()`, `sale.price` is sent, but it should be the bid price, not the `sale.price`. ***[Important]***

8. The amount emitted from the event in the claim should be the bid price, not the `sale.price`. ***[Important]***

9. Missing check in `makeOffer()` that currency is not `address(0)` **[Recommended]**
    + Since it is not known whether the relevant part is reverted in `executePayment()`, it is recommended to check it in `makeOffer()`.


### Integers
1. No overflow check. ***[Important]***
    + In `toInt128()`, overflow occurs when u is greater than `type(Int128).max`. In curve's vyper code, revert occurs when overflow occurs.

2. Don't check underflow. ***[Important]***
    + In `toUint256()`, an underflow occurs when a negative i is entered. In curve's vyper code, revert occurs when underflow occurs.

### NFTs
1. In `safeTransferFrom()`, when `token` is cryptopunks and `from` is `address(this)` is not considered. ***[Important]***
    + The current transfer method is to purchase and send punk, but if you are already in a contract with this purchase, there is no need to purchase and send it.

### Minter
1. Missing visibility of constant variable. **[Recommended]**
    + Missing visibility of `RATE_DENOMINATOR` and `INFLATION_DELAY`.

2. A problem that may occur in the number of iterations of the mintableInTimeframe loop. ***[Important]***
    + Since the value of rateReductionTime is determined at the time of distribution, it is difficult to predict whether 1000 iterations will be a sufficient value in a situation where you do not know how much it will be in code.

3. Event occurrence is missing from `updateTreasury()`　　　　　**[Recommended]**


### NFTGaugeFactory
1. Distributable in constructor. ***[Important]***
    + Revert occurs at `initialize()` of `NFTGauge`. The first gauge is created with `address(0)` as the address of minter, which is the second argument. In the initialize function of `NFTGauge`, revert occurs because various functions such as `controller` address are called from the `minter`.

2. The range of `_feeRatio` is not checked in the constructor. ***[Important]***
    + When a `feeRate` exceeding 10000 is entered, a greater amount of fee may be sent or entered in `distributeFeesETH()` and `distributeFees()`.

3. The range of `_feeRatio` in `updateFeeRatio()` is not checked. ***[Important]***
    + When a `feeRate` exceeding 10000 is entered, a greater amount of fee may be sent or entered in `distributeFeesETH()` and `distributeFees()`.

4. User's `currency` extortion problem through `executePayment()` function　　　　　***[Important]***
    + `executePayment()` can be called by a `NFTGauge`, and `NFTGauge` can be upgraded at any time. If you put the wrong function in the new `NFTGauge`, the user's currency may be extorted. I suggest adding a nonce and going through the process of verifying the user's signature every time it is used.

5. Token transfer is missing from `distributeFees`　　　　　***[Important]***
    + When you call `distributeFees()`, you need to transfer from `msg.sender` with `amountFee` tokens, but it seems to be missing.

6. Overflow problem　　　　　***[Important]***
    + In `_distributeFees()`, the value of `uint256` is coerced to `uint192`. At this time, if the value is greater than uint192 max, overflow occurs.

7. The name of the variable `lastFeeClaimed` seems to be incorrect　　　　　**[Recommendation]**
    + If `lastFeeClaimed` is 10, it means that the claim was made up to the 9th, not the 10th. Considered to be a usage of the wrong word.

8. When comparing the deposit time of `fee.timestamp` and `msg.sender` in `claimFees()`, you must use 'greater than', not 'greater than or equal to'　　　　***[Important]***
    + If the two values are the same, 1. As a new holder, you can receive a much greater amount than existing holders (the balance of ve is highest when it is start). A more Important problem is 2. In the same block, when `_distributeFees()` is called first, and then A deposits, `totalSupply` when `amountPerShare` is stored does not reflect A's balance. Underflow may occur.

9. Do not check if `to` in `claimFees()` is less than `fees[token].length`　　　　　***[Important]***
    + If `to` is greater than `length` is entered, the for statement is skipped and `lastFeeClaimed` is updated with a greater value. After that, if the fee is not pushed beyond the amount, claim is not possible for a long time.


### GaugeController
1. The problem of how to calculate the amount of user's balance in `voteForGaugeWeights()`. ***[Important]***
    + In `voteForGaugeWeights()`, when calculating the user's balance, the voting expiration time (lockEnd) and the user's current slope are calculated and recorded. After that, even if the balance of ve is changed (increase amount / increase unlock time, etc.), the GC assumes that it does not change without additional voting. This is because, except for the time-dependent change in the amount recorded as slope in ve, it cannot be less than the last recorded amount when the time comes. Therefore, considering that there are many ves but few ves at a specific point in time, there may be cases where less ves are given to users, but more tokens do not occur. For example, let's assume that the balance of ve of a specific person in ve is 1000 and the slope is 1. 200 seconds after that point, assuming the value of ve 100 seconds ago (100 seconds after the last vote), GC assumes that the value will never be less than 900. The reason is that in the case of curve, until that point, the amount of ve can only increase (through the increase function) more than the predetermined amount, but not decrease. However, in VotingEscrow.sol, there is a cancel() function that makes the amount ve to 0 and fetches LevX even at a loss. Without taking into account whether this has ever been called, the GC cannot calculate the user's balance since the last vote.

2. In `voteForGaugeWeights()`, `powerUsed >= 0` is a meaningless conditional. *[Optimization]*
    + `powerUsed` is `uint256` type, and >= 0 always returns true

3. The function that modifies totalWeight in `_increaseGaugeWeight()` can be simplified. *[Optimization]*
    + `totalWeight = totalWeight + newSum * typeWeight - oldSum * typeWeight` can be replaced with `totalWeight += increment * typeWeight` .

4. In `_getTotal()` etc., the limit is set to 100 when looping as many as the number of `gaugeTypes`　　　　　***[Important]***
    + If the gauge exceeds 100, more gauges are not reflected.

5. Update incorrect `voteUserSlopes` value in `_updateSlopeChanges()`　　　　　***[Important]***
    + `voteUserSlopes[msg.sender][addr] = newSlope` is an invalid statement. It should be `voteUserSlopes[user][msg.sender] = newSlope`. However, there is no user in the function, so you have to either add it or move the code to the bottom of voteForGaugeWeights.


### NFTGauge
1. In `_checkpoint()`, `prevFutureEpoch >= _periodTime` is considered a meaningless conditional clause. 　　　　*[Optimization]*
    + The timing of the decrease in the amount of issuance after the last stored is of course considered to be equal to or greater than the time of the last stored. It's like a meaningless phrase...

2. Invalid variable naming in `_checkpoint()`. *[Optimization]*
    + curve uses `weekTime` and `prevWeekTime` variables because `interval` is week, but `interval` is not week in this system

3. When `userCheckpoint()` is the first checkPoint call of the target user, many useless calls are made. **[Recommended]**
    + `int128 checkpoint = period[tokenId][user]` to check the checkpoint, if it is 0, `if(checkpoint == 0) {periodOf[tokenId][user] = _period; return;}` would be better.

4. When calculating `wrapped` in userCheckpoint, underflow may occur ***[Important]***
    + If both start and end of `_wrap` are less than ts, underflow can occur in `wrapped += (end - ts)`. For example, let's say the `wrap()` has occurred twice and the user A calls `userCheckpoint()` once after the first unwrap occurs, then in the second `userCheckpoint()` call inside the next `wrap()`, `ts` is between `_wrap[0].end` and `_wrap[1].start`. At this time, while looping, revert occurs from `_wrap[0]` to `wrapped += (end - ts)` due to an underflow.

5. The `integrateFraction` calculation expression in `userCheckpoint()` appears to be incorrect　　　　　***[Important]***
    + Problem 1. `bias` is the average of the variation values from `ts` to the `present` (or the end point when ve becomes 0), but the actual wrapped duration is not reflected.
    + ex) Assuming that it was unwraped 1 minute after the last userCheckpoint, and userCheckpoint was called a month after that, in fact, you should be able to receive only 1 minute's worth for 1 minute with a higher ve balance. It may be extremely less than the actual amount.

    + Problem 2. If `lockEnd` has passed and the current ve balance is 0, the value of `integrateFraction` is lower than the time from the time when the denominator `time` passed until now. (time should originally be `lockEnd - ts`)

    + Problem 3. As in Problem 2, if the user's ve balance remains but the NFT is currently unwrapped, the amount of `integrateFraction` will be calculated lower than actual because if `time` refers to the `time` difference so far, it is divided by a larger number by mistake. (`time` should originally be `_wrap[n].end - ts`)

6. Unconditional token transfer failure in `wrap()`　　　　　***[Important]***
    + Wrap fails when using `safeTransferFrom()` because the `NFTGauge` contract does not implement `receiver(onERC721Received)`.

7. Possibility of tokenTransfer failure in unwrap　　　　　***[Important]***
   + If `to` does not implement `receiver(onERC721Received)`, the transfer may fail.

8. `voteDelayCheck` in `vote()`　　　　　*[Question]*
    + After unwrap the token, it cannot be rewrapped within 1 week. was that intended?

9. `voteDelayCheck` in `revoke()`　　　　　*[Question]*
    + If you want to unwrap, you cannot unwrap within 1 week after wrapping. Or, if token owner self votes then unwrap is not allowed within 1 week. was that intended?

10. Unnecessary updates when `revoke()` is called by non-voters　　　　　**[Recommended]**
    Wouldn't it be better to revert if `lastUserVote[id][msg.sender]` is 0 before calling `userCheckpoint()`?

11. No consideration of the amount of dividends in `claimDividends()`　　　　　**[Recommendation]**
    + Would the last index be needed in a situation where the value of `_lastDividendClaimed` is unknown, like `to` in `NFTGaugeFactory.claimFees()`?

12. Naming variables in `claimDividends()` *[Optimization]*
    + The name isn't strictly `last`, since it's your turn to receive this first. Wouldn't it be better to choose `start` or `from`?

13. Unnecessary loops in `claimDividends()`　　　　　**[Recommended]**
    + Assume that 100 dividends are stacked on a specific tokenId, and if user A has voted after the 90th dividend, when calling `claimDividends()` for the first time, the loop starts from 0. Even the balance of ve is calculated from the time of dividend 0, multiplied by 0 which is the userWeight, and 0 is continuously added to the amount for 90 times. When voting, if this is the first vote for that tokenId, it would be nice to set `_lastDividendClaimed` as the dividend's length.

14. Problem calculating `userWeight` in `claimDividends()` even when balance is 0　　　　　**[Recommended]**
    + if the balance of ve is 0, it would be nice to add `if (balance == 0) continue;`.

15. Incorrect comment in `_getValueAt()`　　　　　**[Recommended]**
    + The return value is `VotedSlope`, not the weight of timestamp

16. Unnecessary code in `_updateValueAtNow()`　　　　　**[Recommendation]**
    + In `NFTGauge`, `_updateValueAtNow` is used to modify only the user's `VotedSlope[]`. Since `voteDelay` exists, it seems that the code after the `else` cannot be called.

17. When currency is an `ERC20` in _settle, it seems that approval of currency is missing　　　　　***[Important]***
    + If you take the fee from `factory` by calling `transferFrom`, you need to `approve()` it prior to it.

18. Problem with `Dividend.timestamp` recording in `_settle()`　　　　　***[Important]***
    + The `_getSum()` function calculates and returns the bias at the start of the next interval. However, Dividend timestamp added to `_dividends` records the starting point of this interval that has already passed.

18. Problem of how to get `Dividend.amountPerShare` in `_settle()`　　　　　***[Important]***
    + The `_getSum()` function calculates and returns the bias at the start of the next interval. However, since that period has not yet come, the actual sum may be different when that time comes due to additional votes/revokes. The distribution is made further in the future as the actual `balance * amountPerShare` at that point in time, with a different denominator, so more or less dividends can be distributed to users. Rather than recording the `amountPerShare`, it is considered more accurate to record the `dividend` itself and calculate the sum upon claim by creating a function such as `_getSumAt` that returns the exact sum of the past time. Alternatively, it'll be also efficient that if `Dividend` struct is set as `timestamp`, `totalDividend`, `amountPerShare` and when the dividend is called for the first time, calculate and record amountPerShare and use amountPerShare when amountPerShare is not 0.
