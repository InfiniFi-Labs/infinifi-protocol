// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice the IDataProvider interface for Aave V3
/// @dev https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/helpers/AaveProtocolDataProvider.sol
interface IAddressProvider {
    /**
     * @notice Returns the address of the pool data provider for the pool
     * @return The address of the pool data provider
     */
    function getPoolDataProvider() external view returns (address);
}
