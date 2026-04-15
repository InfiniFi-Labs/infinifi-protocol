// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IMultiDepositorVault
/// @notice Interface for vaults that can accept deposits from multiple addresses
interface IMultiDepositorVault is IERC20 {
    /// @notice Deposit tokens into the vault and mint units
    /// @param sender The sender of the tokens
    /// @param token The token to deposit
    /// @param tokenAmount The amount of token to deposit
    /// @param unitsAmount The amount of units to mint
    /// @param recipient The recipient of the units
    function enter(address sender, IERC20 token, uint256 tokenAmount, uint256 unitsAmount, address recipient) external;

    /// @notice Withdraw tokens from the vault and burn units
    /// @param sender The sender of the units
    /// @param token The token to withdraw
    /// @param tokenAmount The amount of token to withdraw
    /// @param unitsAmount The amount of units to burn
    /// @param recipient The recipient of the tokens
    function exit(address sender, IERC20 token, uint256 tokenAmount, uint256 unitsAmount, address recipient) external;
}
