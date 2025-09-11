// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice library for the redemption queue
/// @dev from OZ but with the least amount of features and also adding a
/// way to update the front of the queue for partial fundings
library RedemptionQueue {
    /// ------------------- ERRORS -------------------
    error QueueIsFull();
    error QueueIsEmpty();
    error IndexOutOfBounds(uint256 _index);

    /// @notice struct for a redemption request
    /// fits in 32 bytes for storage efficiency
    struct RedemptionRequest {
        /// @notice the amount of receipt token (iUSD/iETH) waiting to be redeemed
        /// @dev max value is 79.228B with 18 decimals, we assume no single redemption will be larger than this
        uint96 amount; // 12 bytes
        /// @notice the recipient of the redemption
        address recipient; // 20 bytes
    }

    struct RedemptionRequestsQueue {
        uint128 _begin;
        uint128 _end;
        mapping(uint128 index => RedemptionRequest) _data;
    }

    /// @notice Inserts a redemption request at the end of the queue.
    function pushBack(RedemptionRequestsQueue storage _redemptionRequestsQueue, RedemptionRequest memory _value)
        internal
    {
        unchecked {
            uint128 backIndex = _redemptionRequestsQueue._end;
            if (backIndex + 1 == _redemptionRequestsQueue._begin) {
                revert QueueIsFull();
            }

            _redemptionRequestsQueue._data[backIndex] = _value;
            _redemptionRequestsQueue._end = backIndex + 1;
        }
    }

    /// @notice Removes the redemption request at the beginning of the queue and returns it.
    function popFront(RedemptionRequestsQueue storage _redemptionRequestsQueue)
        internal
        returns (RedemptionRequest memory)
    {
        unchecked {
            uint128 frontIndex = _redemptionRequestsQueue._begin;
            if (frontIndex == _redemptionRequestsQueue._end) {
                revert QueueIsEmpty();
            }
            RedemptionRequest memory value = _redemptionRequestsQueue._data[frontIndex];
            delete _redemptionRequestsQueue._data[frontIndex];
            _redemptionRequestsQueue._begin = frontIndex + 1;
            return value;
        }
    }

    /// @notice Updates the amount of the redemption request at the beginning of the queue.
    function updateFront(RedemptionRequestsQueue storage _redemptionRequestsQueue, uint96 _newAmount) internal {
        if (empty(_redemptionRequestsQueue)) {
            revert QueueIsEmpty();
        }

        _redemptionRequestsQueue._data[_redemptionRequestsQueue._begin].amount = _newAmount;
    }

    /// @notice Returns the redemption request at the beginning of the queue, without removing it.
    function front(RedemptionRequestsQueue storage _redemptionRequestsQueue)
        internal
        view
        returns (RedemptionRequest memory)
    {
        if (empty(_redemptionRequestsQueue)) {
            revert QueueIsEmpty();
        }
        return _redemptionRequestsQueue._data[_redemptionRequestsQueue._begin];
    }

    /// @notice Returns the number of items in the queue.
    function length(RedemptionRequestsQueue storage _redemptionRequestsQueue) internal view returns (uint256) {
        unchecked {
            return uint256(_redemptionRequestsQueue._end - _redemptionRequestsQueue._begin);
        }
    }

    /// @notice Return the redemption request at a position in the queue given by `index`,
    /// with the first item at 0 and last item at `length(deque) - 1`.
    function at(RedemptionRequestsQueue storage _redemptionRequestsQueue, uint256 _index)
        internal
        view
        returns (RedemptionRequest memory)
    {
        if (_index >= length(_redemptionRequestsQueue)) {
            revert IndexOutOfBounds(_index);
        }
        // By construction, length is a uint128, so the check above ensures that index can be safely downcast to uint128
        unchecked {
            return _redemptionRequestsQueue._data[_redemptionRequestsQueue._begin + uint128(_index)];
        }
    }

    /// @notice returns true if the queue is empty.
    function empty(RedemptionRequestsQueue storage _redemptionRequestsQueue) internal view returns (bool) {
        return _redemptionRequestsQueue._end == _redemptionRequestsQueue._begin;
    }
}
