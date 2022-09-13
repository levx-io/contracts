// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

error Forbidden();
error InvalidDividendRatio();
error InvalidDeadline();
error InvalidCurrency();
error InvalidPrice();
error Expired();
error NonExistent();
error Existent();
error VotedTooEarly();
error NoAmount();
error NotListed();
error Auction();
error NotAuction();
error PriceTooLow();
error InvalidOffer();
error BidInProgress();

function revertIfForbidden(bool success) pure {
    if (!success) revert Forbidden();
}

function revertIfInvalidDividendRatio(bool success) pure {
    if (!success) revert InvalidDividendRatio();
}

function revertIfInvalidDeadline(bool success) pure {
    if (!success) revert InvalidDeadline();
}

function revertIfInvalidCurrency(bool success) pure {
    if (!success) revert InvalidCurrency();
}

function revertIfInvalidPrice(bool success) pure {
    if (!success) revert InvalidPrice();
}

function revertIfExpired(bool success) pure {
    if (!success) revert Expired();
}

function revertIfNonExistent(bool success) pure {
    if (!success) revert NonExistent();
}

function revertIfExistent(bool success) pure {
    if (!success) revert Existent();
}

function revertIfVotedTooEarly(bool success) pure {
    if (!success) revert VotedTooEarly();
}

function revertIfNoAmount(bool success) pure {
    if (!success) revert NoAmount();
}

function revertIfNotListed(bool success) pure {
    if (!success) revert NotListed();
}

function revertIfAuction(bool success) pure {
    if (!success) revert Auction();
}

function revertIfNotAuction(bool success) pure {
    if (!success) revert NotAuction();
}

function revertIfPriceTooLow(bool success) pure {
    if (!success) revert PriceTooLow();
}

function revertIfBidInProgress(bool success) pure {
    if (!success) revert BidInProgress();
}

function revertIfInvalidOffer(bool success) pure {
    if (!success) revert InvalidOffer();
}
