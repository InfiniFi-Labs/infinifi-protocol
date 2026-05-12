// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

/// @title IdleCDO variant that supports epochs.
/// @dev When epoch is running no deposits or withdrawals are allowed. When epoch ends
/// lenders can request withdrawals, that will be fullfilled by the end of the next epoch.
/// If the apr for the new epoch is lower than the last one, lenders can request 'instant'
/// withdrawals that will be fullfilled when the epoch starts and after instantWithdrawDelay (3 days).
/// Funds for instant and normal withdrawals are sent to the strategy contract (IdleCreditVault)
interface IdleCDOEpochVariant {
    function AATranche() external view returns (address);

    function allowInstantWithdraw() external view returns (bool);

    function disableInstantWithdraw() external view returns (bool);

    function withdrawsRequests(address _owner) external view returns (uint256);

    function virtualPrice(address _tranche) external view returns (uint256);

    function setInstantWithdrawParams(uint256 _delay, uint256 _aprDelta, bool _disable) external;

    /// @notice flag to check if epoch is running
    function isEpochRunning() external view returns (bool);

    /// @notice end date of the current epoch
    function epochEndDate() external view returns (uint256);

    function setIsAYSActive(bool) external;

    /// @notice Start the epoch. No deposits or withdrawals are allowed after this.
    /// @dev We calculate the total funds that the borrower should return at the end of the epoch
    /// ie interests + fees from normal withdraw requests. We send to the borrower underlyings amounts ie interests +
    /// new deposits - instant withdraw requests if any. If funds are not enough to satisfy all requests
    /// then borrower should return the difference before instantWithdrawDeadline. After epoch start there
    /// should be no underlyings in this contract
    function startEpoch() external;

    /// @notice workaround to have safeTransfer to borrower as external and use it in a try/catch block
    /// @param _amount Amount of underlyings to transfer
    function sendFundsToBorrower(uint256 _amount) external;

    /// @notice Stop epoch, accrue interest to the vault and get funds to fullfill normal
    /// (ie non-instant) withdraw requests from the prev epoch.
    /// @param _newApr New apr to set for the next epoch
    /// @param _interest Interest gained in the epoch. This will overwrite the expected interest
    /// must be 0 if there is no need to overwrite the expected interest and if > 0 then it should
    /// be greater than the pending withdraw fees and newApr must be 0. If `_interest` is 1 then
    /// it is interpreted as a special case where we request everything back from the borrower
    /// @dev Only owner or manager can call this function. Borrower MUST approve this contract
    function stopEpoch(uint256 _newApr, uint256 _interest) external;

    /// @notice Stop epoch and set new duration
    /// @dev see stopEpoch and setEpochParams for more details, bufferPeriod is not modified
    /// @param _newApr New apr to set for the next epoch
    /// @param _interest Interest gained in the epoch
    /// @param _duration New epoch duration
    function stopEpochWithDuration(uint256 _newApr, uint256 _interest, uint256 _duration) external;

    /// @dev Get interest and funds for fullfill withdraw requests (normal and instant) from borrower,
    /// method is external so it can be used in the try/catch blocks
    /// @param _amount Amount of interest to transfer
    /// @param _withdrawRequests Total withdraw requests
    /// @param _instantWithdrawRequests Total instant withdraw requests
    function getFundsFromBorrower(uint256 _amount, uint256 _withdrawRequests, uint256 _instantWithdrawRequests) external;

    /// @notice Get funds from borrower to fullfill instant withdraw requests
    /// Manager should call this method after instantWithdrawDeadline (when epoch is running)
    function getInstantWithdrawFunds() external;

    /// @notice allow deposits and redeems for all classes of tranches
    /// @dev can be called by the owner only
    function restoreOperations() external;

    ///
    /// User methods
    ///

    /// @notice pausable
    /// @dev msg.sender should approve this contract first to spend `_amount` of `token`
    /// @param _amount amount of `token` to deposit
    /// @return AA tranche tokens minted
    function depositAA(uint256 _amount) external returns (uint256);

    /// @notice Request a withdraw from the vault
    /// @param _amount Amount of tranche tokens
    /// @param _tranche Tranche to withdraw from
    /// @return Amount of underlyings requested
    function requestWithdraw(uint256 _amount, address _tranche) external returns (uint256);

    /// @notice Get the max amount of underlyings that can be withdrawn by user
    /// @param _user User address
    /// @param _tranche Tranche to withdraw from
    function maxWithdrawable(address _user, address _tranche) external view returns (uint256);

    /// @notice Get the max amount of underlyings that can be withdrawn instantly by user
    /// @param _user User address
    /// @param _tranche Tranche to withdraw from
    function maxWithdrawableInstant(address _user, address _tranche) external view returns (uint256);

    /// @notice Claim a withdraw request from the vault. Can be done when at least 1 epoch passed
    /// since last withdraw request
    function claimWithdrawRequest() external;

    /// @notice Claim an instant withdraw request from the vault. Can be done when epoch is running
    /// as funds will get transferred from borrower when epoch starts
    function claimInstantWithdrawRequest() external;

    /// @notice Check if wallet is allowed to interact with the contract
    /// @param _user User address
    /// @return true if wallet is allowed or keyring address is not set
    function isWalletAllowed(address _user) external view returns (bool);

    function defaulted() external view returns (bool);
}
