// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../interfaces/IVotingEscrow.sol";
import "./Integers.sol";

library VotingEscrowHelper {
    using Integers for int128;
    using Integers for uint256;

    /**
     * @notice Helper function to get a historical balance of VotingEscrow
     * @dev This is needed because `VotingEscrow.balanceOf(address, uint256)` doesn't support reading historical balance
     */
    function balanceOf(
        address escrow,
        address addr,
        uint256 _t
    ) public view returns (uint256) {
        uint256 _epoch = IVotingEscrow(escrow).userPointEpoch(addr);
        if (_epoch == 0) return 0;
        else {
            uint256 _min;
            uint256 _max = _epoch;
            for (uint256 i; i < 128; i++) {
                if (_min >= _max) break;
                uint256 _mid = (_min + _max + 1) / 2;
                (, , uint256 _ts, ) = IVotingEscrow(escrow).userPointHistory(addr, _mid);
                if (_ts <= _t) _min = _mid;
                else _max = _mid - 1;
            }

            (int128 bias, int128 slope, uint256 ts, ) = IVotingEscrow(escrow).userPointHistory(addr, _min);
            bias -= slope * (_t - ts).toInt128();
            if (bias < 0) bias = 0;
            return bias.toUint256();
        }
    }
}
