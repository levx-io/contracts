// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../base/ERC721Initializable.sol";
import "../interfaces/IWrappedERC721.sol";
import "../interfaces/INFTGaugeFactory.sol";
import "../libraries/Tokens.sol";
import "../libraries/Math.sol";
import "../libraries/Errors.sol";

abstract contract WrappedERC721 is ERC721Initializable, ReentrancyGuard, IWrappedERC721 {
    using Strings for uint256;

    struct Order {
        uint256 price;
        address currency;
        uint64 deadline;
        bool auction;
    }

    struct Bid_ {
        uint256 price;
        address bidder;
        uint64 timestamp;
    }

    address public override nftContract;
    address public override factory;

    mapping(uint256 => mapping(address => Order)) public override sales;
    mapping(uint256 => mapping(address => Bid_)) public override currentBids;
    mapping(uint256 => mapping(address => Order)) public override offers;

    function __WrappedERC721_init(address _nftContract) internal initializer {
        nftContract = _nftContract;
        factory = msg.sender;

        string memory name;
        string memory symbol;
        try IERC721Metadata(_nftContract).name() returns (string memory _name) {
            name = _name;
        } catch {
            name = uint256(uint160(nftContract)).toHexString(20);
        }
        try IERC721Metadata(_nftContract).symbol() returns (string memory _symbol) {
            symbol = string(abi.encodePacked("W", _symbol));
        } catch {
            symbol = "WNFT";
        }
        __ERC721_init(string(abi.encodePacked("Wrapped ", name)), symbol);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Initializable, IERC721Metadata)
        returns (string memory output)
    {
        revertIfNonExistent(_exists(tokenId));

        return IERC721Metadata(nftContract).tokenURI(tokenId);
    }

    function listForSale(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline,
        bool auction
    ) external override {
        revertIfForbidden(ownerOf(tokenId) == msg.sender);
        revertIfInvalidDeadline(block.timestamp < deadline);

        sales[tokenId][msg.sender] = Order(price, currency, deadline, auction);

        emit ListForSale(tokenId, msg.sender, price, currency, deadline, auction);
    }

    function cancelListing(uint256 tokenId) external override {
        revertIfForbidden(ownerOf(tokenId) == msg.sender);

        delete sales[tokenId][msg.sender];
        delete currentBids[tokenId][msg.sender];

        emit CancelListing(tokenId, msg.sender);
    }

    function buyETH(uint256 tokenId, address owner) external payable override {
        address currency = _buy(tokenId, owner, msg.value);
        revertIfInvalidCurrency(currency == address(0));

        _settle(tokenId, address(0), owner, msg.value);
    }

    function buy(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override nonReentrant {
        address currency = _buy(tokenId, owner, price);
        revertIfInvalidCurrency(currency != address(0));

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);

        _settle(tokenId, currency, owner, price);
    }

    function _buy(
        uint256 tokenId,
        address owner,
        uint256 price
    ) internal returns (address currency) {
        Order memory sale = sales[tokenId][owner];
        revertIfNotListed(sale.deadline > 0);
        revertIfExpired(block.timestamp <= sale.deadline);
        revertIfInvalidPrice(sale.price == price);
        revertIfAuction(!sale.auction);

        _safeTransfer(owner, msg.sender, tokenId, "0x");

        currency = sale.currency;
        emit Buy(tokenId, owner, msg.sender, price, currency);
    }

    function bidETH(uint256 tokenId, address owner) external payable override {
        address currency = _bid(tokenId, owner, msg.value);
        revertIfInvalidCurrency(currency == address(0));
    }

    function bid(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override nonReentrant {
        address currency = _bid(tokenId, owner, price);
        revertIfInvalidCurrency(currency != address(0));

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);
    }

    function _bid(
        uint256 tokenId,
        address owner,
        uint256 price
    ) internal returns (address currency) {
        Order memory sale = sales[tokenId][owner];
        uint256 deadline = sale.deadline;
        revertIfNotListed(deadline > 0);
        revertIfNotAuction(sale.auction);

        currency = sale.currency;
        Bid_ memory prevBid = currentBids[tokenId][owner];
        if (prevBid.price == 0) {
            revertIfPriceTooLow(price >= sale.price);
            revertIfExpired(block.timestamp <= deadline);
        } else {
            revertIfPriceTooLow(price >= (prevBid.price * 110) / 100);
            revertIfExpired(block.timestamp <= Math.max(deadline, prevBid.timestamp + 10 minutes));

            Tokens.transfer(currency, prevBid.bidder, prevBid.price);
        }
        currentBids[tokenId][owner] = Bid_(price, msg.sender, uint64(block.timestamp));

        emit Bid(tokenId, owner, msg.sender, price, currency);
    }

    function claim(uint256 tokenId, address owner) external override nonReentrant {
        Order memory sale = sales[tokenId][owner];
        revertIfNotListed(sale.deadline > 0);
        revertIfNotAuction(sale.auction);

        Bid_ memory currentBid = currentBids[tokenId][owner];
        revertIfForbidden(currentBid.bidder == msg.sender);
        revertIfBidInProgress(currentBid.timestamp + 10 minutes < block.timestamp);

        Tokens.transfer(owner, msg.sender, tokenId);

        _settle(tokenId, sale.currency, owner, sale.price);

        emit Claim(tokenId, owner, msg.sender, sale.price, sale.currency);
    }

    function makeOfferETH(uint256 tokenId, uint64 deadline) external payable override nonReentrant {
        _makeOffer(tokenId, msg.value, address(0), deadline);
    }

    function makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) external override nonReentrant {
        _makeOffer(tokenId, price, currency, deadline);

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);
    }

    function _makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) internal {
        revertIfNonExistent(_exists(tokenId));
        revertIfInvalidPrice(price > 0);
        revertIfInvalidDeadline(block.timestamp < uint256(deadline));

        Order memory offer = offers[tokenId][msg.sender];
        if (offer.deadline > 0) {
            emit WithdrawOffer(tokenId, msg.sender);

            Tokens.transfer(offer.currency, msg.sender, offer.price);
        }

        offers[tokenId][msg.sender] = Order(price, currency, deadline, false);

        emit MakeOffer(tokenId, msg.sender, price, currency, uint256(deadline));
    }

    function withdrawOffer(uint256 tokenId) external override {
        Order memory offer = offers[tokenId][msg.sender];
        revertIfInvalidOffer(offer.deadline > 0);

        delete offers[tokenId][msg.sender];

        emit WithdrawOffer(tokenId, msg.sender);

        Tokens.transfer(offer.currency, msg.sender, offer.price);
    }

    function acceptOffer(uint256 tokenId, address maker) external override nonReentrant {
        revertIfForbidden(ownerOf(tokenId) == msg.sender);

        Order memory offer = offers[tokenId][maker];
        revertIfInvalidOffer(offer.deadline > 0);
        revertIfExpired(block.timestamp <= offer.deadline);

        delete offers[tokenId][maker];
        _safeTransfer(msg.sender, maker, tokenId, "0x");

        _settle(tokenId, offer.currency, msg.sender, offer.price);

        emit AcceptOffer(tokenId, maker, msg.sender, offer.price, offer.currency, offer.deadline);
    }

    function _settle(
        uint256 tokenId,
        address currency,
        address to,
        uint256 amount
    ) internal virtual;

    function _beforeTokenTransfer(
        address from,
        address,
        uint256 tokenId
    ) internal virtual override {
        if (from != address(0)) {
            delete sales[tokenId][from];
            delete currentBids[tokenId][from];
        }
    }
}
