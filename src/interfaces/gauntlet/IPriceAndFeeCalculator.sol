// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IPriceAndFeeCalculator
/// @notice Interface for the unit price provider
interface IPriceAndFeeCalculator {
    /// @notice Convert units to token amount
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param unitsAmount Amount of units
    /// @return tokenAmount Amount of tokens
    function convertUnitsToToken(address vault, IERC20 token, uint256 unitsAmount)
        external
        view
        returns (uint256 tokenAmount);

    /// @notice Convert token amount to units
    /// @param vault Address of the vault
    /// @param token Address of the token
    /// @param tokenAmount Amount of tokens
    /// @return unitsAmount Amount of units
    function convertTokenToUnits(address vault, IERC20 token, uint256 tokenAmount)
        external
        view
        returns (uint256 unitsAmount);
}
