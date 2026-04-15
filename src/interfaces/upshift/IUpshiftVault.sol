// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IUpshiftVault {
    /// @notice The duration of the time-lock for withdrawals.
    function lagDuration() external view returns (uint256);

    /**
     * @notice Requests to redeem a given number of shares from the holder specified.
     * @dev The respective amount of assets will be made available in X hours from now, where "X" is the lag defined by the owner of the pool.
     * @param shares The number of shares to burn.
     * @param receiverAddr The address of the receiver.
     * @param holderAddr The address of the tokens holder.
     * @return assets The amount of assets that can be claimed for this specific withdrawal request.
     * @return claimableEpoch The date at which the assets become claimable. This is expressed as a Unix epoch.
     */
    function requestRedeem(uint256 shares, address receiverAddr, address holderAddr) external returns (uint256, uint256);

    /**
     * @notice Redeems the number of shares specified, instantly.
     * @param shares The number of shares to redeem.
     * @param receiverAddr The address of the receiver.
     * @param holderAddr The address of the tokens holder.
     */
    function instantRedeem(uint256 shares, address receiverAddr, address holderAddr) external;

    /**
     * @notice Gets the asset amount that can be claimed by a receiver at the date specified.
     * @dev This is a forecast on the amount of assets that can be claimed by a given party on the date specified.
     * @param year The year.
     * @param month The month.
     * @param day The day.
     * @param receiverAddr The address of the receiver.
     * @return uint256 The total amount of assets that can be claimed at a the date specified.
     */
    function getClaimableAmountByReceiver(uint256 year, uint256 month, uint256 day, address receiverAddr)
        external
        view
        returns (uint256);

    /*
     * @notice Gets the date at which your withdrawal request can be claimed
     * @return year The year
     * @return month The month.
     * @return day The day.
     * @return claimableEpoch The Unix epoch at which your withdrawal request can be claimed
     */
    function getWithdrawalEpoch()
        external
        view
        returns (uint256 year, uint256 month, uint256 day, uint256 claimableEpoch);

    /**
     * @notice Allows any public address to process the scheduled withdrawal requests of the receiver specified.
     * @dev Throws if the receiving address is not the legitimate address you registered via "requestRedeem()"
     * @param year The year component of the claim. It can be a past date.
     * @param month The month component of the claim. It can be a past date.
     * @param day The day component of the claim. It can be a past date.
     * @param receiverAddr The address of the legitimate receiver of the funds.
     * @return uint256 The effective number of shares (LP tokens) that were burnt from the liquidity pool.
     * @return uint256 The effective amount of underlying assets that were transfered to the receiver.
     */
    function claim(uint256 year, uint256 month, uint256 day, address receiverAddr) external returns (uint256, uint256);
}
