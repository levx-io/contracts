// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./base/WrappedERC721.sol";
import "./interfaces/INFTGauge.sol";
import "./interfaces/IGaugeController.sol";
import "./interfaces/IVotingEscrow.sol";
import "./libraries/Tokens.sol";

contract NFTGauge is WrappedERC721, INFTGauge {
    struct Checkpoint {
        uint128 fromBlock;
        uint128 value;
    }

    struct Dividend {
        uint256 tokenId;
        uint128 blockNumber;
        uint128 amount;
        address token;
        uint256 total;
    }

    address public override controller;
    address public override ve;

    mapping(uint256 => uint256) public override dividendRatios;
    Dividend[] public override dividends;
    mapping(uint256 => mapping(address => bool)) public override dividendsClaimed;

    mapping(uint256 => mapping(address => Checkpoint[])) internal _points;
    mapping(uint256 => Checkpoint[]) internal _pointsSum;
    Checkpoint[] internal _pointsTotal;

    function initialize(
        address _nftContract,
        address _tokenURIRenderer,
        address _controller
    ) external override initializer {
        __WrappedERC721_init(_nftContract, _tokenURIRenderer);

        controller = _controller;
        ve = IGaugeController(_controller).votingEscrow();
    }

    function points(uint256 tokenId, address user) external view returns (uint256) {
        return _exists(tokenId) ? _getValueAt(_points[tokenId][user], block.timestamp) : 0;
    }

    function pointsAt(
        uint256 tokenId,
        address user,
        uint256 _block
    ) external view returns (uint256) {
        uint256 sum = _getValueAt(_pointsSum[tokenId], _block);
        return sum > 0 ? _getValueAt(_points[tokenId][user], _block) : 0;
    }

    function pointsSum(uint256 tokenId) external view returns (uint256) {
        return _getValueAt(_pointsSum[tokenId], block.timestamp);
    }

    function pointsSumAt(uint256 tokenId, uint256 _block) external view returns (uint256) {
        return _getValueAt(_pointsSum[tokenId], _block);
    }

    function pointsTotal() external view returns (uint256) {
        return _getValueAt(_pointsTotal, block.timestamp);
    }

    function pointsTotalAt(uint256 _block) external view returns (uint256) {
        return _getValueAt(_pointsTotal, _block);
    }

    function dividendsLength() external view returns (uint256) {
        return dividends.length;
    }

    /**
     * @notice Mint a wrapped NFT
     * @param tokenId Token Id to deposit
     * @param dividendRatio Dividend ratio for the voters in bps (units of 0.01%)
     * @param to The owner of the newly minted wrapped NFT
     */
    function wrap(
        uint256 tokenId,
        uint256 dividendRatio,
        address to
    ) external override {
        wrap(tokenId, dividendRatio, to, 0);
    }

    /**
     * @notice Mint a wrapped NFT and commit gauge voting to this tokenId
     * @param tokenId Token Id to deposit
     * @param dividendRatio Dividend ratio for the voters in bps (units of 0.01%)
     * @param to The owner of the newly minted wrapped NFT
     * @param userWeight Weight for a gauge in bps (units of 0.01%). Minimal is 0.01%. Ignored if 0
     */
    function wrap(
        uint256 tokenId,
        uint256 dividendRatio,
        address to,
        uint256 userWeight
    ) public override {
        require(dividendRatio <= 10000, "NFTG: INVALID_RATIO");

        dividendRatios[tokenId] = dividendRatio;

        _mint(to, tokenId);

        vote(tokenId, userWeight);

        emit Wrap(tokenId, to);

        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function unwrap(uint256 tokenId, address to) public override {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        dividendRatios[tokenId] = 0;

        _burn(tokenId);

        Checkpoint[] storage checkpointsSum = _pointsSum[tokenId];
        uint256 sum = checkpointsSum[checkpointsSum.length - 1].value;
        _updateValueAtNow(checkpointsSum, 0);
        _updateValueAtNow(_pointsTotal, _pointsTotal[_pointsTotal.length - 1].value - sum);

        emit Unwrap(tokenId, to);

        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function vote(uint256 tokenId, uint256 userWeight) public override {
        uint256 balance = IVotingEscrow(ve).balanceOf(msg.sender);
        uint256 pointNew = (balance * userWeight) / 10000;

        Checkpoint[] storage checkpoints = _points[tokenId][msg.sender];
        uint256 numCheckpoints = checkpoints.length;
        uint256 pointOld;
        if (numCheckpoints > 0) {
            pointOld = checkpoints[numCheckpoints - 1].value;
        }
        _updateValueAtNow(checkpoints, pointNew);

        Checkpoint[] storage checkpointsSum = _pointsSum[tokenId];
        uint256 numCheckpointsSum = checkpointsSum.length;
        if (numCheckpointsSum > 0) {
            _updateValueAtNow(checkpointsSum, checkpointsSum[numCheckpointsSum - 1].value + pointNew - pointOld);
        } else {
            _updateValueAtNow(checkpointsSum, pointNew);
        }
        uint256 numCheckpointsTotal = _pointsTotal.length;
        if (numCheckpointsTotal > 0) {
            _updateValueAtNow(_pointsTotal, _pointsTotal[_pointsTotal.length - 1].value + pointNew - pointOld);
        } else {
            _updateValueAtNow(_pointsTotal, pointNew);
        }

        IGaugeController(controller).voteForGaugeWeights(msg.sender, userWeight);

        emit Vote(tokenId, msg.sender, userWeight);
    }

    function claimDividends(uint256[] calldata ids) external override {
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            require(!dividendsClaimed[id][msg.sender], "NFTG: CLAIMED");
            dividendsClaimed[id][msg.sender] = true;

            Dividend memory dividend = dividends[id];
            uint256 amount = (dividend.amount *
                _getValueAt(_points[dividend.tokenId][msg.sender], dividend.blockNumber)) / dividend.total;
            require(amount > 0, "NFTG: INSUFFICIENT_AMOUNT");
            Tokens.transfer(dividend.token, msg.sender, amount);

            emit ClaimDividend(id, msg.sender, dividend.token, amount);
        }
    }

    /**
     * @dev `_getValueAt` retrieves the number of tokens at a given block number
     * @param checkpoints The history of values being queried
     * @param _block The block number to retrieve the value at
     * @return The weight at `_block`
     */
    function _getValueAt(Checkpoint[] storage checkpoints, uint256 _block) internal view returns (uint256) {
        if (checkpoints.length == 0) return 0;

        // Shortcut for the actual value
        Checkpoint storage last = checkpoints[checkpoints.length - 1];
        if (_block >= last.fromBlock) return last.value;
        if (_block < checkpoints[0].fromBlock) return 0;

        // Binary search of the value in the array
        uint256 min = 0;
        uint256 max = checkpoints.length - 1;
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (checkpoints[mid].fromBlock <= _block) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }
        return checkpoints[min].value;
    }

    /**
     * @dev `_updateValueAtNow` is used to update checkpoints
     * @param checkpoints The history of data being updated
     * @param _value The new number of weight
     */
    function _updateValueAtNow(Checkpoint[] storage checkpoints, uint256 _value) internal {
        if ((checkpoints.length == 0) || (checkpoints[checkpoints.length - 1].fromBlock < block.number)) {
            Checkpoint storage newCheckPoint = checkpoints.push();
            newCheckPoint.fromBlock = uint128(block.number);
            newCheckPoint.value = uint128(_value);
        } else {
            Checkpoint storage oldCheckPoint = checkpoints[checkpoints.length - 1];
            oldCheckPoint.value = uint128(_value);
        }
    }

    function _settle(
        uint256 tokenId,
        address currency,
        address to,
        uint256 amount
    ) internal override {
        uint256 fee;
        if (currency == address(0)) {
            fee = INFTGaugeFactory(factory).distributeFeesETH{value: amount}();
        } else {
            fee = INFTGaugeFactory(factory).distributeFees(currency, amount);
        }
        uint256 dividend = ((amount - fee) * dividendRatios[tokenId]) / 10000;
        Checkpoint[] storage checkpoints = _pointsSum[tokenId];
        dividends.push(
            Dividend(
                tokenId,
                uint128(block.timestamp),
                uint128(dividend),
                currency,
                checkpoints[checkpoints.length - 1].value
            )
        );
        emit AddDividend(tokenId, currency, dividend);

        Tokens.transfer(currency, to, amount - fee - dividend);
    }
}
