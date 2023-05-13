// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./IERC721NonTransferable.sol";

interface IWrappedERC721 is IERC721NonTransferable {
    error InvalidDeadline();
    error InvalidCurrency();
    error InvalidOffer();
    error NotListed();
    error InvalidPrice();
    error Auction();
    error NotAuction();
    error PriceTooLow();
    error BidInProgress();

    event ListForSale(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 price,
        address currency,
        uint64 deadline,
        bool indexed auction
    );
    event CancelListing(uint256 indexed tokenId, address indexed owner);
    event MakeOffer(uint256 indexed tokenId, address indexed maker, uint256 price, address currency, uint256 deadline);
    event WithdrawOffer(uint256 indexed tokenId, address indexed maker);
    event AcceptOffer(
        uint256 indexed tokenId,
        address indexed maker,
        address indexed taker,
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

    function nftContract() external view returns (address);

    function factory() external view returns (address);

    function sales(
        uint256 tokenId,
        address owner
    ) external view returns (uint256 price, address currency, uint64 deadline, bool auction);

    function currentBids(
        uint256 tokenId,
        address owner
    ) external view returns (uint256 price, address bidder, uint64 timestamp);

    function offers(
        uint256 tokenId,
        address maker
    ) external view returns (uint256 price, address currency, uint64 deadline, bool auction);

    function listForSale(uint256 tokenId, uint256 price, address currency, uint64 deadline, bool auction) external;

    function cancelListing(uint256 tokenId) external;

    function buyETH(uint256 tokenId, address owner) external payable;

    function buy(uint256 tokenId, address owner, uint256 price) external;

    function bidETH(uint256 tokenId, address owner) external payable;

    function bid(uint256 tokenId, address owner, uint256 price) external;

    function claim(uint256 tokenId, address owner) external;

    function makeOfferETH(uint256 tokenId, uint64 deadline) external payable;

    function makeOffer(uint256 tokenId, uint256 price, address currency, uint64 deadline) external;

    function withdrawOffer(uint256 tokenId) external;

    function acceptOffer(uint256 tokenId, address maker) external;
}
