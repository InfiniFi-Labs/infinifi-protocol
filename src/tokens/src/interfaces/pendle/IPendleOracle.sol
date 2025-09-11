// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPendleOracle {
    /// @notice Get the PT to SY rate
    /// @param market The address of the Pendle market
    /// @param twapDuration The duration of the TWAP
    /// @return The PT to SY rate with 18 decimals of precision
    function getPtToSyRate(address market, uint32 twapDuration) external view returns (uint256);

    /// @notice Get the PT to asset rate
    /// @param market The address of the Pendle market
    /// @param twapDuration The duration of the TWAP
    /// @return The PT to asset rate with 18 decimals of precision
    function getPtToAssetRate(address market, uint32 twapDuration) external view returns (uint256);
}
