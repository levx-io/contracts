// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../base/ERC721NonTransferable.sol";
import "../interfaces/IWrappedERC721.sol";
import "../interfaces/INFTGaugeFactory.sol";
import "../libraries/Tokens.sol";
import "../libraries/Math.sol";

abstract contract WrappedERC721 is ERC721NonTransferable, ReentrancyGuard, IWrappedERC721 {
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

    address internal _weth;

    function __WrappedERC721_init(address _nftContract) internal onlyInitializing {
        nftContract = _nftContract;
        factory = msg.sender;

        _weth = INFTGaugeFactory(msg.sender).weth();
        string memory name;
        string memory symbol;
        try IERC721NonTransferable(_nftContract).name() returns (string memory _name) {
            name = _name;
        } catch {
            name = uint256(uint160(nftContract)).toHexString(20);
        }
        try IERC721NonTransferable(_nftContract).symbol() returns (string memory _symbol) {
            symbol = string(abi.encodePacked("W", _symbol));
        } catch {
            symbol = "WNFT";
        }
        __ERC721_init(string(abi.encodePacked("Wrapped ", name)), symbol);
    }

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721NonTransferable, IERC721NonTransferable) returns (string memory output) {
        if (!_exists(tokenId)) revert NonExistent();

        return IERC721NonTransferable(nftContract).tokenURI(tokenId);
    }

    function listForSale(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline,
        bool auction
    ) external override {
        if (ownerOf(tokenId) != msg.sender) revert Forbidden();
        if (block.timestamp >= deadline) revert InvalidDeadline();

        sales[tokenId][msg.sender] = Order(price, currency, deadline, auction);

        emit ListForSale(tokenId, msg.sender, price, currency, deadline, auction);
    }

    function cancelListing(uint256 tokenId) external override {
        if (ownerOf(tokenId) != msg.sender) revert Forbidden();

        delete sales[tokenId][msg.sender];
        delete currentBids[tokenId][msg.sender];

        emit CancelListing(tokenId, msg.sender);
    }

    function buyETH(uint256 tokenId, address owner) external payable override {
        address currency = _buy(tokenId, owner, msg.value);
        if (currency != address(0)) revert InvalidCurrency();

        _settle(tokenId, address(0), owner, msg.value);
    }

    function buy(uint256 tokenId, address owner, uint256 price) external override nonReentrant {
        address currency = _buy(tokenId, owner, price);
        if (currency == address(0)) revert InvalidCurrency();

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);

        _settle(tokenId, currency, owner, price);
    }

    function _buy(uint256 tokenId, address owner, uint256 price) internal returns (address currency) {
        Order memory sale = sales[tokenId][owner];
        if (sale.deadline == 0) revert NotListed();
        if (block.timestamp > sale.deadline) revert Expired();
        if (sale.price != price) revert InvalidPrice();
        if (sale.auction) revert Auction();

        _transfer(owner, msg.sender, tokenId);

        currency = sale.currency;
        emit Buy(tokenId, owner, msg.sender, price, currency);
    }

    function bidETH(uint256 tokenId, address owner) external payable override {
        address currency = _bid(tokenId, owner, msg.value);
        if (currency != address(0)) revert InvalidCurrency();
    }

    function bid(uint256 tokenId, address owner, uint256 price) external override nonReentrant {
        address currency = _bid(tokenId, owner, price);
        if (currency == address(0)) revert InvalidCurrency();

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);
    }

    function _bid(uint256 tokenId, address owner, uint256 price) internal returns (address currency) {
        Order memory sale = sales[tokenId][owner];
        uint256 deadline = sale.deadline;
        if (deadline == 0) revert NotListed();
        if (!sale.auction) revert NotAuction();

        currency = sale.currency;
        Bid_ memory prevBid = currentBids[tokenId][owner];
        if (prevBid.price == 0) {
            if (price < sale.price) revert PriceTooLow();
            if (block.timestamp > deadline) revert Expired();
        } else {
            if (price < (prevBid.price * 110) / 100) revert PriceTooLow();
            if (block.timestamp > Math.max(deadline, prevBid.timestamp + 10 minutes)) revert Expired();

            Tokens.safeTransfer(currency, prevBid.bidder, prevBid.price, _weth);
        }
        currentBids[tokenId][owner] = Bid_(price, msg.sender, uint64(block.timestamp));

        emit Bid(tokenId, owner, msg.sender, price, currency);
    }

    function claim(uint256 tokenId, address owner) external override nonReentrant {
        Order memory sale = sales[tokenId][owner];
        if (sale.deadline <= 0) revert NotListed();
        if (!sale.auction) revert NotAuction();

        Bid_ memory currentBid = currentBids[tokenId][owner];
        if (currentBid.bidder != msg.sender) revert Forbidden();
        if (currentBid.timestamp + 10 minutes >= block.timestamp) revert BidInProgress();

        _transfer(owner, msg.sender, tokenId);

        _settle(tokenId, sale.currency, owner, currentBid.price);

        emit Claim(tokenId, owner, msg.sender, currentBid.price, sale.currency);
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
        if (currency == address(0)) revert InvalidCurrency();

        _makeOffer(tokenId, price, currency, deadline);

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);
    }

    function _makeOffer(uint256 tokenId, uint256 price, address currency, uint64 deadline) internal {
        if (_exists(tokenId)) revert NonExistent();
        if (price == 0) revert InvalidPrice();
        if (block.timestamp >= uint256(deadline)) revert InvalidDeadline();

        Order memory offer = offers[tokenId][msg.sender];
        if (offer.deadline > 0) {
            emit WithdrawOffer(tokenId, msg.sender);

            Tokens.safeTransfer(offer.currency, msg.sender, offer.price, _weth);
        }

        offers[tokenId][msg.sender] = Order(price, currency, deadline, false);

        emit MakeOffer(tokenId, msg.sender, price, currency, uint256(deadline));
    }

    function withdrawOffer(uint256 tokenId) external override {
        Order memory offer = offers[tokenId][msg.sender];
        if (offer.deadline == 0) revert InvalidOffer();

        delete offers[tokenId][msg.sender];

        emit WithdrawOffer(tokenId, msg.sender);

        Tokens.safeTransfer(offer.currency, msg.sender, offer.price, _weth);
    }

    function acceptOffer(uint256 tokenId, address maker) external override nonReentrant {
        if (ownerOf(tokenId) != msg.sender) revert Forbidden();

        Order memory offer = offers[tokenId][maker];
        if (offer.deadline == 0) revert InvalidOffer();
        if (block.timestamp > offer.deadline) revert Expired();

        delete offers[tokenId][maker];
        _transfer(msg.sender, maker, tokenId);

        _settle(tokenId, offer.currency, msg.sender, offer.price);

        emit AcceptOffer(tokenId, maker, msg.sender, offer.price, offer.currency, offer.deadline);
    }

    function _settle(uint256 tokenId, address currency, address to, uint256 amount) internal virtual;

    function _beforeTokenTransfer(address from, address, uint256 tokenId) internal virtual override {
        if (from != address(0)) {
            delete sales[tokenId][from];
            delete currentBids[tokenId][from];
        }
    }
}
