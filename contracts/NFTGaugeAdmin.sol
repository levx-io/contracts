// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./base/CloneFactory.sol";
import "./interfaces/INFTGaugeAdmin.sol";
import "./NFTGauge.sol";

contract NFTGaugeAdmin is CloneFactory, Ownable, INFTGaugeAdmin {
    using SafeERC20 for IERC20;

    address public immutable override tokenURIRenderer;
    address internal immutable _target;

    uint256 public override fee;
    mapping(address => bool) public override tokenWhitelisted;

    constructor(address _tokenURIRenderer, uint256 _fee) {
        tokenURIRenderer = _tokenURIRenderer;
        fee = _fee;

        emit UpdateFee(_fee);

        NFTGauge gauge = new NFTGauge();
        gauge.initialize(address(0), address(0));
        _target = address(gauge);
    }

    function whitelistToken(address token) external override onlyOwner {
        tokenWhitelisted[token] = true;

        emit WhitelistToken(token);
    }

    function updateFee(uint256 _fee) external override onlyOwner {
        fee = _fee;

        emit UpdateFee(_fee);
    }

    function createNFTGauge(address nftContract) external override returns (address gauge) {
        gauge = _createClone(_target);
        NFTGauge(gauge).initialize(nftContract, tokenURIRenderer);

        emit CreateNFTGauge(nftContract);
    }

    function executePayment(
        address token,
        address from,
        address to,
        uint256 amount
    ) external override {
        require(tokenWhitelisted[token], "PG: TOKEN_NOT_WHITELIST");

        IERC20(token).safeTransferFrom(from, to, amount);
    }
}
