// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Accounting} from "@finance/Accounting.sol";

/// @notice Simple Assets checker contract to be used at the end of a msig payload
/// @dev this contract uses 0 decimals of precision and bps (1/10_000) for the checks, so that values are more human readable.
contract AssetsChecker {
    address public immutable accounting;

    event AssetsChecked(uint256 indexed timestamp, uint256 assets);
    event AssetsDiffChecked(uint256 indexed timestamp, uint256 assetsBefore, uint256 assetsAfter);

    error NotSaved();
    error AlreadySaved();
    error CheckAbsFailed(uint256 value, uint256 minValue, uint256 maxValue);
    error CheckDiffAbsFailed(int256 diff, int256 minDiff, int256 maxDiff);
    error CheckDiffRelFailed(int256 ratio, int256 minBps, int256 maxBps);

    uint256 public transient savedAssetsValue;
    uint256 public transient savedAssetsBlock;

    constructor(address _accounting) {
        accounting = _accounting;
    }

    /// @notice check the assets are between some values
    function checkAbs(uint256 _minValue, uint256 _maxValue) external {
        uint256 currentAssetsValue = Accounting(accounting).totalAssetsValue() / 1e18;

        require(
            currentAssetsValue >= _minValue && currentAssetsValue <= _maxValue,
            CheckAbsFailed(currentAssetsValue, _minValue, _maxValue)
        );

        emit AssetsChecked(block.timestamp, currentAssetsValue);
    }

    /// @notice save the assets at the current block, this is required before calling the check functions.
    function saveAssets() external {
        require(savedAssetsBlock == 0, AlreadySaved());
        savedAssetsValue = Accounting(accounting).totalAssetsValue();
        savedAssetsBlock = block.number;
    }

    /// @notice check the difference in assets is greater or equal than an absolute maximum difference
    /// @param _maxDiff the maximum difference in dollars (0 decimals)
    /// @dev use this in the following scenarios:
    /// Example 1: you expect no changes, you can call checkDiffAbs(0, 0) to ensure that there is no change in assets.
    /// Example 2: you expect to lose 100$, and want to revert if the loss is greater than 110$,
    /// then you can call checkDiffAbs(-110, 0). This will also revert if there is an unexpected gain.
    /// Example 3: you expect to gain 100$, and want to revert if the profit is less than 90$,
    /// then you can call checkDiffAbs(90, 200). This will also revert if there is an unexpected gain greater than 200$.
    function checkDiffAbs(int256 _minDiff, int256 _maxDiff) external {
        require(savedAssetsBlock == block.number, NotSaved());
        uint256 currentAssetsValue = Accounting(accounting).totalAssetsValue();

        // casting to 'int256' is safe because expected values are way less than 5e76 (max int256)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 diff = (int256(currentAssetsValue) - int256(savedAssetsValue)) / 1e18;
        require(diff >= _minDiff && diff <= _maxDiff, CheckDiffAbsFailed(diff, _minDiff, _maxDiff));

        emit AssetsDiffChecked(block.timestamp, savedAssetsValue, currentAssetsValue);
    }

    /// @notice check the difference in assets is greater or equal than a percentage difference
    /// @param _minBps minimum basis points of difference (1/10_000)
    /// @param _maxBps maximum basis points of difference (1/10_000)
    /// Example 1: you want to revert if the loss is more than 0.3%, then you can call checkDiffRel(-30, 0).
    /// This will also revert if there is an unexpected gain.
    /// Example 2: you want to revert if the gain is less than 0.3%, then you can call checkDiffRel(30, 100).
    /// This will also revert if there is an unexpected gain greater than 1%.
    function checkDiffRel(int256 _minBps, int256 _maxBps) external {
        require(savedAssetsBlock == block.number, NotSaved());
        uint256 currentAssetsValue = Accounting(accounting).totalAssetsValue();

        // casting to 'int256' is safe because expected values are way less than 5e76 (max int256)
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 ratio = int256(currentAssetsValue) * 10_000 / int256(savedAssetsValue) - 10_000;
        require(ratio >= _minBps && ratio <= _maxBps, CheckDiffRelFailed(ratio, _minBps, _maxBps));

        emit AssetsDiffChecked(block.timestamp, savedAssetsValue, currentAssetsValue);
    }
}
