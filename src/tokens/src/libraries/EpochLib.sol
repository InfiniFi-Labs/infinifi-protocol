// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library EpochLib {
    uint256 internal constant EPOCH = 1 weeks;
    uint256 internal constant EPOCH_OFFSET = 3 days;

    /// @notice epoch start (start of the epoch) for a given timestamp
    function epoch(uint256 _timestamp) public pure returns (uint256) {
        return (_timestamp - EPOCH_OFFSET) / EPOCH;
    }

    /// @notice epoch end (end of the epoch) for a given timestamp
    function nextEpoch(uint256 _timestamp) public pure returns (uint256) {
        return epoch(_timestamp) + 1;
    }

    /// @notice Convert epoch to timestamp taking into account the epoch offset
    function epochToTimestamp(uint256 _epoch) public pure returns (uint256) {
        return _epoch * EPOCH + EPOCH_OFFSET;
    }
}
