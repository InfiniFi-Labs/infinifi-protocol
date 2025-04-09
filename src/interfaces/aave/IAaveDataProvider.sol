// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice the IDataProvider interface for Aave V3
/// @dev https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/helpers/AaveProtocolDataProvider.sol
interface IAaveDataProvider {
    /**
     * @notice Returns the caps parameters of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return borrowCap The borrow cap of the reserve
     * @return supplyCap The supply cap of the reserve
     */
    function getReserveCaps(address asset) external view returns (uint256 borrowCap, uint256 supplyCap);
}
