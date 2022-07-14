// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface INFTGauge {
    function controller() external view returns (address);

    function ve() external view returns (address);

    function admin() external view returns (address);

    function sales(uint256 tokenId, address owner)
        external
        view
        returns (
            uint256 price,
            address currency,
            uint64 deadline,
            bool auction
        );

    function currentBidders(uint256 tokenId, address owner) external view returns (address);

    function offers(
        uint256 tokenId,
        address taker,
        address maker
    )
        external
        view
        returns (
            uint256 price,
            address currency,
            uint64 deadline,
            bool auction
        );

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller
    ) external;

    function deposit(address to, uint256 tokenId) external;

    function withdraw(address to, uint256 tokenId) external;

    function listForSale(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline,
        bool auction
    ) external;

    function cancelListing(uint256 tokenId) external;

    function buyWithETH(uint256 tokenId, address owner) external payable;

    function buy(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external;

    function bidWithETH(uint256 tokenId, address owner) external payable;

    function bid(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external;

    function claim(
        uint256 tokenId,
        address owner,
        uint256 price
    ) external;

    function makeOfferETH(uint256 tokenId, uint64 deadline) external payable;

    function makeOffer(
        uint256 tokenId,
        uint256 price,
        address currency,
        uint64 deadline
    ) external;

    function withdrawOffer(uint256 tokenId, address taker) external;

    function acceptOffer(uint256 tokenId, address maker) external;

    event Deposit(address indexed to, uint256 indexed tokenId);
    event Withdraw(address indexed to, uint256 indexed tokenId);
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
    event Buy(uint256 indexed tokenId, address indexed owner, address indexed bidder, uint256 price, address currency);
    event Bid(uint256 indexed tokenId, address indexed owner, address indexed bidder, uint256 price, address currency);
    event Claim(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed bidder,
        uint256 price,
        address currency
    );
}
