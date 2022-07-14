// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/INFTGaugeAdmin.sol";

contract NFTGauge is WrappedERC721, ReentrancyGuard, INFTGauge {
    using SafeERC20 for IERC20;

    struct Order {
        uint256 price;
        address currency;
        uint64 deadline;
        bool auction;
    }

    address public override controller;
    address public override ve;
    address public override admin;
    mapping(uint256 => mapping(address => Order)) public override sales;
    mapping(uint256 => mapping(address => address)) public override currentBidders;
    mapping(uint256 => mapping(address => mapping(address => Order))) public override offers;

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller
    ) external override initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);

        controller = _controller;
        ve = IGaugeController(_controller).votingEscrow();

        admin = msg.sender;
    }

    /**
     * @notice Mint a wrapped NFT and commit gauge voting to this gauge addr
     * @param to The owner of the newly minted wrapped NFT
     * @param tokenId Token Id to deposit
     * @param userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function deposit(
        address to,
        uint256 tokenId,
        uint256 userWeight
    ) public override {
        _mint(to, tokenId);
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);

        emit Deposit(to, tokenId);
    }

    function withdraw(address to, uint256 tokenId) public override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        _cancelIfListed(tokenId, msg.sender);

        _burn(tokenId);
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);

        emit Withdraw(to, tokenId);
    }

    function listForSale(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline,
        bool auction
    ) external override {
        require(block.timestamp < deadline, "NFTG: INVALID_DEADLINE");
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        Order storage sale = sales[tokenId][msg.sender];
        uint256 _deadline = sale.deadline;
        require(_deadline == 0 || _deadline < block.timestamp, "NFTG: LISTED_FOR_SALE");

        sales[tokenId][msg.sender] = Order(price, currency, deadline, auction);

        emit ListForSale(tokenId, msg.sender, price, currency, deadline, auction);
    }

    function cancelListing(uint256 tokenId) external override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        Order storage sale = sales[tokenId][msg.sender];
        uint256 _deadline = sale.deadline;
        require(_deadline > 0, "NFTG: NOT_LISTED_FOR_SALE");
        require(block.timestamp <= _deadline, "NFTG: EXPIRED");

        delete sales[tokenId][msg.sender];

        emit CancelListing(tokenId, msg.sender);
    }

    function buyWithETH(uint256 tokenId, address owner) external payable override {
        require(msg.value > 0, "NFTG: VALUE_TOO_LOW");

        address currency = _buy(tokenId, owner, msg.value, sales[tokenId][owner]);
        require(currency == address(0), "NFTG: ETH_UNACCEPTABLE");
        // TODO: distribute funds
    }

    function buy(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override nonReentrant {
        address currency = _buy(tokenId, owner, price, sales[tokenId][owner]);
        require(currency != address(0), "NFTG: ONLY_ETH_ACCEPTABLE");

        INFTGaugeAdmin(admin).executePayment(currency, msg.sender, price);
        // TODO: distribute funds
    }

    function _buy(
        uint256 tokenId,
        address owner,
        uint256 price,
        Order memory sale
    ) internal returns (address currency) {
        uint256 _deadline = sale.deadline;
        require(_deadline > 0, "NFTG: NOT_LISTED_FOR_SALE");
        require(block.timestamp <= _deadline, "NFTG: EXPIRED");
        require(!sale.auction, "NFTG: BID_REQUIRED");

        _transfer(owner, msg.sender, tokenId);

        currency = sale.currency;
        emit Buy(tokenId, owner, msg.sender, price, currency);
    }

    function bidWithETH(uint256 tokenId, address owner) external payable override {
        require(msg.value > 0, "NFTG: VALUE_TOO_LOW");

        address currency = _bid(tokenId, owner, msg.value, sales[tokenId][owner]);
        require(currency == address(0), "NFTG: ETH_UNACCEPTABLE");
        // TODO: distribute funds
    }

    function bid(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override nonReentrant {
        address currency = _bid(tokenId, owner, price, sales[tokenId][owner]);
        require(currency != address(0), "NFTG: ONLY_ETH_ACCEPTABLE");

        INFTGaugeAdmin(admin).executePayment(currency, msg.sender, price);
        // TODO: distribute funds
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
        currentBidders[tokenId][owner] = msg.sender;
        if (prevBidder != address(0)) {
            uint256 prevPrice = sale.price;
            require(price >= (prevPrice * 110) / 100, "NFTG: PRICE_TOO_LOW");

            _transferTokens(currency, prevBidder, prevPrice);
        }
        sale.price = price;

        emit Bid(tokenId, owner, msg.sender, price, currency);
    }

    function claim(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override {
        Order storage sale = sales[tokenId][owner];
        uint256 _deadline = sale.deadline;
        require(_deadline > 0, "NFTG: NOT_LISTED_FOR_SALE");
        require(_deadline < block.timestamp, "NFTG: NOT_EXPIRED");
        require(sale.auction, "NFTG: NOT_CLAIMABLE");

        address prevBidder = currentBidders[tokenId][owner];
        require(prevBidder != address(0), "NFTG: NOT_BIDDEN");

        _transfer(owner, msg.sender, tokenId);

        emit Claim(tokenId, owner, msg.sender, price, sale.currency);
        // TODO: distribute funds
    }

    function makeOfferETH(uint256 tokenId, uint64 deadline) external payable override {
        require(msg.value > 0, "NFTG: VALUE_TOO_LOW");

        _makeOffer(tokenId, msg.value, address(0), deadline);
    }

    function makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) external override {
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

    function withdrawOffer(uint256 tokenId, address taker) external override {
        Order storage offer = offers[tokenId][taker][msg.sender];
        uint256 _deadline = offer.deadline;
        require(_deadline > 0, "NFTG: INVALID_OFFER");

        delete offers[tokenId][taker][msg.sender];

        emit WithdrawOffer(tokenId, taker, msg.sender);

        (uint256 _price, address _currency) = (offer.price, offer.currency);
        _transferTokens(_currency, msg.sender, _price);
    }

    function acceptOffer(uint256 tokenId, address maker) external override {
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
        }
    }
}
