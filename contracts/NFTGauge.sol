// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGaugeAdmin.sol";

contract NFTGauge is WrappedERC721, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Order {
        uint256 price;
        address currency;
        uint64 deadline;
        bool auction;
    }

    address public admin;
    mapping(uint256 => bool) public withdrawn;
    mapping(uint256 => mapping(address => Order)) public sales;
    mapping(uint256 => mapping(address => address)) public currentBidders;
    mapping(uint256 => mapping(address => mapping(address => Order))) public offers;

    event ListForSale(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 price,
        address currency,
        uint64 deadline,
        bool indexed auction
    );
    event CancelListing(uint256 indexed tokenId, address indexed owner);
    event MakeOffer(
        uint256 indexed tokenId,
        address indexed taker,
        address indexed maker,
        uint256 price,
        address currency,
        uint256 deadline
    );
    event WithdrawOffer(uint256 indexed tokenId, address indexed taker, address indexed maker);
    event AcceptOffer(
        uint256 indexed tokenId,
        address indexed taker,
        address indexed maker,
        uint256 price,
        address currency,
        uint256 deadline
    );
    event Bid(uint256 indexed tokenId, address indexed owner, address indexed bidder, uint256 price, address currency);
    event Claim(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed bidder,
        uint256 price,
        address currency
    );

    function initialize(address _nftContract, address _tokenURIRenderer) external initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);

        admin = msg.sender;
    }

    function deposit(address to, uint256 tokenId) public {
        withdrawn[tokenId] = false;

        _mint(to, tokenId);
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function withdraw(address to, uint256 tokenId) public {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        _cancelIfListed(tokenId, msg.sender);

        withdrawn[tokenId] = true;

        _burn(tokenId);
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function listForSale(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline,
        bool auction
    ) external {
        require(block.timestamp < deadline, "NFTG: INVALID_DEADLINE");
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        Order storage sale = sales[tokenId][msg.sender];
        uint256 _deadline = sale.deadline;
        require(_deadline == 0 || _deadline < block.timestamp, "NFTG: LISTED_FOR_SALE");

        sales[tokenId][msg.sender] = Order(price, currency, deadline, auction);

        emit ListForSale(tokenId, msg.sender, price, currency, deadline, auction);
    }

    function cancelListing(uint256 tokenId) external {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        Order storage sale = sales[tokenId][msg.sender];
        uint256 _deadline = sale.deadline;
        require(_deadline > 0, "NFTG: NOT_LISTED_FOR_SALE");
        require(block.timestamp <= _deadline, "NFTG: EXPIRED");

        delete sales[tokenId][msg.sender];

        emit CancelListing(tokenId, msg.sender);
    }

    function bidETH(uint256 tokenId, address owner) external payable {
        require(msg.value > 0, "NFTG: VALUE_TOO_LOW");

        address currency = _bid(tokenId, owner, msg.value, sales[tokenId][owner]);
        require(currency == address(0), "NFTG: ETH_UNACCEPTABLE");
    }

    function bid(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external nonReentrant {
        address currency = _bid(tokenId, owner, price, sales[tokenId][owner]);
        require(currency != address(0), "NFTG: ONLY_ETH_ACCEPTABLE");

        INFTGaugeAdmin(admin).executePayment(currency, msg.sender, price);
    }

    function _bid(
        uint256 tokenId,
        address owner,
        uint256 price,
        Order memory sale
    ) internal returns (address currency) {
        uint256 _deadline = sale.deadline;
        require(_deadline > 0, "NFTG: NOT_LISTED_FOR_SALE");
        require(block.timestamp <= _deadline, "NFTG: EXPIRED");
        require(sale.auction, "NFTG: NOT_BIDDABLE");

        currency = sale.currency;
        address prevBidder = currentBidders[tokenId][owner];
        if (prevBidder != address(0)) {
            uint256 prevPrice = sale.price;
            require(price >= (prevPrice * 110) / 100, "NFTG: PRICE_TOO_LOW");

            _transferTokens(currency, prevBidder, prevPrice);
        }

        currentBidders[tokenId][owner] = msg.sender;

        emit Bid(tokenId, owner, msg.sender, price, currency);
    }

    function claimETH(uint256 tokenId, address owner) external payable {
        require(msg.value > 0, "NFTG: VALUE_TOO_LOW");

        address currency = _claim(tokenId, owner, msg.value, sales[tokenId][owner]);
        require(currency == address(0), "NFTG: ETH_UNACCEPTABLE");
    }

    function claim(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external nonReentrant {
        address currency = _claim(tokenId, owner, price, sales[tokenId][owner]);
        require(currency != address(0), "NFTG: ONLY_ETH_ACCEPTABLE");

        INFTGaugeAdmin(admin).executePayment(currency, msg.sender, price);
    }

    function _claim(
        uint256 tokenId,
        address owner,
        uint256 price,
        Order memory sale
    ) internal returns (address currency) {
        uint256 _deadline = sale.deadline;
        require(_deadline > 0, "NFTG: NOT_LISTED_FOR_SALE");
        require(block.timestamp <= _deadline, "NFTG: EXPIRED");
        require(!sale.auction, "NFTG: NOT_CLAIMABLE");

        _transfer(owner, msg.sender, tokenId);

        currency = sale.currency;
        emit Claim(tokenId, owner, msg.sender, price, currency);
    }

    function makeOfferETH(uint256 tokenId, uint64 deadline) external payable {
        require(msg.value > 0, "NFTG: VALUE_TOO_LOW");

        _makeOffer(tokenId, msg.value, address(0), deadline);
    }

    function makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) external {
        _makeOffer(tokenId, price, currency, deadline);

        INFTGaugeAdmin(admin).executePayment(currency, msg.sender, price);
    }

    function _makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) internal {
        require(_exists(tokenId), "NFTG: INVALID_TOKEN_ID");
        require(price > 0, "NFTG: INVALID_PRICE");
        require(block.timestamp < uint256(deadline), "NFTG: INVALID_DEADLINE");

        address taker = ownerOf(tokenId);
        offers[tokenId][taker][msg.sender] = Order(price, currency, deadline, false);

        emit MakeOffer(tokenId, taker, msg.sender, price, currency, uint256(deadline));
    }

    function withdrawOffer(uint256 tokenId, address taker) external {
        Order storage offer = offers[tokenId][taker][msg.sender];
        uint256 _deadline = offer.deadline;
        require(_deadline > 0, "NFTG: INVALID_OFFER");

        delete offers[tokenId][taker][msg.sender];

        emit WithdrawOffer(tokenId, taker, msg.sender);

        (uint256 _price, address _currency) = (offer.price, offer.currency);
        _transferTokens(_currency, msg.sender, _price);
    }

    function acceptOffer(uint256 tokenId, address maker) external {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        Order storage offer = offers[tokenId][msg.sender][maker];
        uint256 _deadline = offer.deadline;
        require(_deadline > 0 && _deadline <= block.timestamp, "NFTG: INVALID_OFFER");

        delete offers[tokenId][msg.sender][maker];

        _transfer(msg.sender, maker, tokenId);

        (uint256 _price, address _currency) = (offer.price, offer.currency);
        _transferTokens(_currency, msg.sender, _price);

        emit AcceptOffer(tokenId, msg.sender, maker, _price, _currency, _deadline);
    }

    function _transferTokens(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "NFTG: FAILED_TO_TRANSFER_ETH");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _beforeTokenTransfer(
        address,
        address,
        uint256 tokenId
    ) internal override {
        _cancelIfListed(tokenId, ownerOf(tokenId));
    }

    function _cancelIfListed(uint256 tokenId, address owner) internal {
        Order storage sale = sales[tokenId][owner];
        uint256 _deadline = sale.deadline;
        if (_deadline > 0 && block.timestamp <= _deadline) {
            delete sales[tokenId][owner];
            delete currentBidders[tokenId][owner];

            emit CancelListing(tokenId, owner);
        }
    }
}
