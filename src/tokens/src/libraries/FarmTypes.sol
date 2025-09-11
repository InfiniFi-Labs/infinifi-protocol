// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library FarmTypes {
    /// @notice indicates farm type that is not generating any yield but is capable of storing funds
    uint256 internal constant PROTOCOL = 0;

    /// @notice farm type that has instant principal withdrawals. (eg AAVE)
    uint256 internal constant LIQUID = 1;

    /// @notice (illiquid farm) has a maturity until when the principal value is locked
    uint256 internal constant MATURITY = 2;
}
