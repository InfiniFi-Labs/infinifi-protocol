// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";

interface IChainlinkOracle {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Returns a value reported by Chainlink.
/// @dev When the price returned by Chainlink is stale, the price() function
/// will revert, which will prevent yield accruals and redemptions until the protocol assets
/// can be priced properly.
contract ChainlinkOracle is IOracle {
    address public immutable feed;
    uint256 public immutable decimalNormalization;
    bool public immutable divide;
    uint256 public immutable heartbeat;

    error StalePrice(address feed, uint256 updatedAt);

    constructor(address _feed, uint256 _decimalNormalization, bool _divide, uint256 _heartbeat) {
        feed = _feed;
        decimalNormalization = _decimalNormalization;
        divide = _divide;
        heartbeat = _heartbeat;
    }

    function price() external view override returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IChainlinkOracle(feed).latestRoundData();

        // check if the price is stale
        require(block.timestamp - updatedAt <= heartbeat, StalePrice(feed, updatedAt));

        // casting to 'uint256' is safe because we do not expect negative values in price feeds
        // forge-lint: disable-start(unsafe-typecast)
        if (decimalNormalization == 0) return uint256(answer);
        if (divide) return uint256(answer) / decimalNormalization;
        return uint256(answer) * decimalNormalization;
        // forge-lint: disable-end(unsafe-typecast)
    }
}
