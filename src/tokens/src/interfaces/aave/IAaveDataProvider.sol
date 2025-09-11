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

    struct AaveDataProviderReserveData {
        uint256 unbacked; // The amount of unbacked tokens
        uint256 accruedToTreasuryScaled; // The scaled amount of tokens accrued to treasury that is to be minted
        uint256 totalAToken; // The total supply of the aToken
        uint256 totalStableDebt; // The total stable debt of the reserve
        uint256 totalVariableDebt; // The total variable debt of the reserve
        uint256 liquidityRate; // The liquidity rate of the reserve
        uint256 variableBorrowRate; // The variable borrow rate of the reserve
        uint256 stableBorrowRate; // The stable borrow rate of the reserve
        uint256 averageStableBorrowRate; // The average stable borrow rate of the reserve
        uint256 liquidityIndex; // The liquidity index of the reserve
        uint256 variableBorrowIndex; // The variable borrow index of the reserve
        uint40 lastUpdateTimestamp; // The timestamp of the last update of the reserve
    }

    function getReserveData(address asset) external view returns (AaveDataProviderReserveData memory data);

    /**
     * @notice Returns if the pool is paused
     * @param asset The address of the underlying asset of the reserve
     * @return isPaused True if the pool is paused, false otherwise
     */
    function getPaused(address asset) external view returns (bool isPaused);
}
