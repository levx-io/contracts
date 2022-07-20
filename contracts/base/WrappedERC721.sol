// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

import "../base/ERC721Initializable.sol";
import "../interfaces/IWrappedERC721.sol";
import "../interfaces/ITokenURIRenderer.sol";
import "../interfaces/INFTGaugeFactory.sol";
import "../libraries/Signature.sol";

abstract contract WrappedERC721 is ERC721Initializable, ReentrancyGuard, IWrappedERC721 {
    using SafeERC20 for IERC20;
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

    // keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_TYPEHASH =
        0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;
    // keccak256("Permit(address owner,address spender,uint256 nonce,uint256 deadline)");
    bytes32 public constant override PERMIT_ALL_TYPEHASH =
        0xdaab21af31ece73a508939fedd476a5ee5129a5ed4bb091f3236ffb45394df62;

    bytes32 internal _DOMAIN_SEPARATOR;
    uint256 internal _CACHED_CHAIN_ID;

    address public override nftContract;
    address public override tokenURIRenderer;
    address public override factory;

    mapping(uint256 => mapping(address => Order)) public override sales;
    mapping(uint256 => mapping(address => Bid_)) public override currentBids;
    mapping(uint256 => mapping(address => mapping(address => Order))) public override offers;

    mapping(uint256 => uint256) public nonces;
    mapping(address => uint256) public noncesForAll;

    function __WrappedERC721_init(address _nftContract, address _tokenURIRenderer) internal initializer {
        nftContract = _nftContract;
        tokenURIRenderer = _tokenURIRenderer;
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

        _CACHED_CHAIN_ID = block.chainid;
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                // keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                keccak256(bytes(Strings.toHexString(uint160(address(this))))),
                0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6, // keccak256(bytes("1"))
                block.chainid,
                address(this)
            )
        );
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Initializable, IERC721Metadata)
        returns (string memory output)
    {
        require(_exists(tokenId), "WERC721: TOKEN_NON_EXISTENT");

        return ITokenURIRenderer(tokenURIRenderer).render(nftContract, tokenId);
    }

    function DOMAIN_SEPARATOR() public view virtual override returns (bytes32) {
        bytes32 domainSeparator;
        if (_CACHED_CHAIN_ID == block.chainid) domainSeparator = _DOMAIN_SEPARATOR;
        else {
            domainSeparator = keccak256(
                abi.encode(
                    // keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
                    0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f,
                    keccak256(bytes(Strings.toHexString(uint160(address(this))))),
                    0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6, // keccak256(bytes("1"))
                    block.chainid,
                    address(this)
                )
            );
        }
        return domainSeparator;
    }

    function listForSale(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline,
        bool auction
    ) external override {
        require(block.timestamp < deadline, "WERC721: INVALID_DEADLINE");
        require(ownerOf(tokenId) == msg.sender, "WERC721: FORBIDDEN");
        require(
            currency == address(0) || INFTGaugeFactory(factory).tokenWhitelisted(currency),
            "WERC721: INVALID_CURRENCY"
        );

        Order storage sale = sales[tokenId][msg.sender];
        uint256 _deadline = sale.deadline;
        require(_deadline == 0 || _deadline < block.timestamp, "WERC721: LISTED_FOR_SALE");

        sales[tokenId][msg.sender] = Order(price, currency, deadline, auction);

        emit ListForSale(tokenId, msg.sender, price, currency, deadline, auction);
    }

    function cancelListing(uint256 tokenId) external override {
        require(ownerOf(tokenId) == msg.sender, "WERC721: FORBIDDEN");

        delete sales[tokenId][msg.sender];
        delete currentBids[tokenId][msg.sender];

        emit CancelListing(tokenId, msg.sender);
    }

    function buyETH(uint256 tokenId, address owner) external payable override {
        address currency = _buy(tokenId, owner, msg.value, sales[tokenId][owner]);
        require(currency == address(0), "WERC721: ETH_UNACCEPTABLE");

        _settle(address(0), owner, msg.value);
    }

    function buy(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override nonReentrant {
        address currency = _buy(tokenId, owner, price, sales[tokenId][owner]);
        require(currency != address(0), "WERC721: ONLY_ETH_ACCEPTABLE");

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);

        _settle(currency, owner, price);
    }

    function _buy(
        uint256 tokenId,
        address owner,
        uint256 price,
        Order memory sale
    ) internal returns (address currency) {
        require(sale.deadline > 0, "WERC721: NOT_LISTED_FOR_SALE");
        require(block.timestamp <= sale.deadline, "WERC721: EXPIRED");
        require(sale.price == price, "WERC721: INVALID_PRICE");
        require(!sale.auction, "WERC721: BID_REQUIRED");

        _transfer(owner, msg.sender, tokenId);

        currency = sale.currency;
        emit Buy(tokenId, owner, msg.sender, price, currency);
    }

    function bidETH(uint256 tokenId, address owner) external payable override {
        address currency = _bid(tokenId, owner, msg.value, sales[tokenId][owner]);
        require(currency == address(0), "WERC721: ETH_UNACCEPTABLE");
    }

    function bid(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external override nonReentrant {
        address currency = _bid(tokenId, owner, price, sales[tokenId][owner]);
        require(currency != address(0), "WERC721: ONLY_ETH_ACCEPTABLE");

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);
    }

    function _bid(
        uint256 tokenId,
        address owner,
        uint256 price,
        Order memory sale
    ) internal returns (address currency) {
        uint256 deadline = sale.deadline;
        require(deadline > 0, "WERC721: NOT_LISTED_FOR_SALE");
        require(sale.auction, "WERC721: NOT_BIDDABLE");

        currency = sale.currency;
        Bid_ memory prevBid = currentBids[tokenId][owner];
        if (prevBid.price == 0) {
            require(price > sale.price, "WERC721: PRICE_TOO_LOW");
            require(block.timestamp <= deadline, "WERC721: EXPIRED");
        } else {
            require(price >= (prevBid.price * 110) / 100, "WERC721: PRICE_TOO_LOW");
            require(
                block.timestamp <= deadline || block.timestamp <= prevBid.timestamp + 10 minutes,
                "WERC721: EXPIRED"
            );

            _transferTokens(currency, prevBid.bidder, prevBid.price);
        }
        currentBids[tokenId][owner] = Bid_(price, msg.sender, uint64(block.timestamp));

        emit Bid(tokenId, owner, msg.sender, price, currency);
    }

    function claim(uint256 tokenId, address owner) external override nonReentrant {
        Order memory sale = sales[tokenId][owner];
        require(sale.deadline > 0, "WERC721: NOT_LISTED_FOR_SALE");
        require(sale.auction, "WERC721: NOT_CLAIMABLE");

        Bid_ memory currentBid = currentBids[tokenId][owner];
        require(currentBid.bidder == msg.sender, "WERC721: FORBIDDEN");
        require(currentBid.timestamp + 10 minutes < block.timestamp, "WERC721: EXPIRED");

        _transfer(owner, msg.sender, tokenId);

        _settle(sale.currency, owner, sale.price);

        emit Claim(tokenId, owner, msg.sender, sale.price, sale.currency);
    }

    function makeOfferETH(uint256 tokenId, uint64 deadline) external payable override {
        _makeOffer(tokenId, msg.value, address(0), deadline);
    }

    function makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) external override {
        _makeOffer(tokenId, price, currency, deadline);

        INFTGaugeFactory(factory).executePayment(currency, msg.sender, price);
    }

    function _makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) internal {
        require(_exists(tokenId), "WERC721: INVALID_TOKEN_ID");
        require(price > 0, "WERC721: INVALID_PRICE");
        require(block.timestamp < uint256(deadline), "WERC721: INVALID_DEADLINE");

        address taker = ownerOf(tokenId);
        offers[tokenId][taker][msg.sender] = Order(price, currency, deadline, false);

        emit MakeOffer(tokenId, taker, msg.sender, price, currency, uint256(deadline));
    }

    function withdrawOffer(uint256 tokenId, address taker) external override {
        Order memory offer = offers[tokenId][taker][msg.sender];
        require(offer.deadline > 0, "WERC721: INVALID_OFFER");

        delete offers[tokenId][taker][msg.sender];

        emit WithdrawOffer(tokenId, taker, msg.sender);

        _transferTokens(offer.currency, msg.sender, offer.price);
    }

    function acceptOffer(uint256 tokenId, address maker) external override nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "WERC721: FORBIDDEN");

        Order memory offer = offers[tokenId][msg.sender][maker];
        require(offer.deadline > 0, "WERC721: INVALID_OFFER");
        require(block.timestamp <= offer.deadline, "WERC721: EXPIRED");

        _transfer(msg.sender, maker, tokenId);

        delete offers[tokenId][msg.sender][maker];

        _settle(offer.currency, msg.sender, offer.price);

        emit AcceptOffer(tokenId, msg.sender, maker, offer.price, offer.currency, offer.deadline);
    }

    function _transferTokens(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "WERC721: FAILED_TO_TRANSFER_ETH");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _settle(
        address token,
        address to,
        uint256 amount
    ) internal virtual;

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
            delete currentBids[tokenId][owner];
        }
    }

    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        require(block.timestamp <= deadline, "WERC721: EXPIRED");

        address owner = ownerOf(tokenId);
        require(owner != address(0), "WERC721: INVALID_TOKENID");
        require(spender != owner, "WERC721: NOT_NECESSARY");

        bytes32 hash = keccak256(abi.encode(PERMIT_TYPEHASH, spender, tokenId, nonces[tokenId]++, deadline));
        Signature.verify(hash, owner, v, r, s, DOMAIN_SEPARATOR());

        _approve(spender, tokenId);
    }

    function permitAll(
        address owner,
        address spender,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override {
        require(block.timestamp <= deadline, "WERC721: EXPIRED");
        require(owner != address(0), "WERC721: INVALID_ADDRESS");
        require(spender != owner, "WERC721: NOT_NECESSARY");

        bytes32 hash = keccak256(abi.encode(PERMIT_ALL_TYPEHASH, owner, spender, noncesForAll[owner]++, deadline));
        Signature.verify(hash, owner, v, r, s, DOMAIN_SEPARATOR());

        _setApprovalForAll(owner, spender, true);
    }
}
