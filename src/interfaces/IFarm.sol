// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Interface for an InfiniFi Farm contract
interface IFarm {
    /// @notice emitted when there is a deposit of withdrawal from the farm
    event AssetsUpdated(uint256 timestamp, uint256 assetsBefore, uint256 assetsAfter);

    // --------------------------------------------------------------------
    // Accounting
    // --------------------------------------------------------------------

    /// @notice the cap of the farm
    function cap() external view returns (uint256);

    /// @notice the asset used by deposits and withdrawals in the farm
    function assetToken() external view returns (address);

    /// @notice the total assets in the farm, reported as a balance of asset()
    function assets() external view returns (uint256);

    // --------------------------------------------------------------------
    // Adapter logic
    // --------------------------------------------------------------------
    /// @notice deposit all asset() held by the contract into the farm
    function deposit() external;

    /// @notice Returns the max deposit amount for the underlying protocol
    function maxDeposit() external view returns (uint256);

    /// @notice withdraw an amount of the asset() from the farm
    /// @param amount Amount of assets to withdraw
    /// @param to Address to receive the withdrawn assets
    function withdraw(uint256 amount, address to) external;

    /// @notice available number of assetToken() withdrawable instantly from the farm
    function liquidity() external view returns (uint256);
}
