// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOracle {
    /// @notice price of a token expressed in a reference token.
    /// @dev be mindful of the decimals here, because if quote token
    /// doesn't have 18 decimals, value is used to scale the decimals.
    /// For example, for USDC quote (6 decimals) expressed in
    /// DAI reference (18 decimals), value should be around ~1e30,
    /// so that price is:
    /// 1e6 * 1e30 / WAD (1e18)
    /// ~= WAD (1e18)
    /// ~= 1:1
    function price() external view returns (uint256);
}
