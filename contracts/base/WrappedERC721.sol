// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";

import "../base/ERC721Initializable.sol";
import "../interfaces/ITokenURIRenderer.sol";
import "../libraries/Signature.sol";

abstract contract WrappedERC721 is ERC721Initializable {
    using Strings for uint256;

    // keccak256("Permit(address spender,uint256 tokenId,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x49ecf333e5b8c95c40fdafc95c1ad136e8914a8fb55e9dc8bb01eaa83a2df9ad;
    // keccak256("Permit(address owner,address spender,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_ALL_TYPEHASH = 0xdaab21af31ece73a508939fedd476a5ee5129a5ed4bb091f3236ffb45394df62;

    bytes32 internal _DOMAIN_SEPARATOR;
    uint256 internal _CACHED_CHAIN_ID;

    address public nftContract;
    address public tokenURIRenderer;
    mapping(uint256 => uint256) public nonces;
    mapping(address => uint256) public noncesForAll;

    function __WrappedERC721_init(address _nftContract, address _tokenURIRenderer) internal initializer {
        nftContract = _nftContract;
        tokenURIRenderer = _tokenURIRenderer;

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

    function tokenURI(uint256 tokenId) public view override returns (string memory output) {
        require(_exists(tokenId), "WERC721: TOKEN_NON_EXISTENT");

        return ITokenURIRenderer(tokenURIRenderer).render(nftContract, tokenId);
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
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

    function permit(
        address spender,
        uint256 tokenId,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(block.timestamp <= deadline, "BNFT721: EXPIRED");

        address owner = ownerOf(tokenId);
        require(owner != address(0), "BNFT721: INVALID_TOKENID");
        require(spender != owner, "BNFT721: NOT_NECESSARY");

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
    ) external {
        require(block.timestamp <= deadline, "BNFT721: EXPIRED");
        require(owner != address(0), "BNFT721: INVALID_ADDRESS");
        require(spender != owner, "BNFT721: NOT_NECESSARY");

        bytes32 hash = keccak256(abi.encode(PERMIT_ALL_TYPEHASH, owner, spender, noncesForAll[owner]++, deadline));
        Signature.verify(hash, owner, v, r, s, DOMAIN_SEPARATOR());

        _setApprovalForAll(owner, spender, true);
    }
}
