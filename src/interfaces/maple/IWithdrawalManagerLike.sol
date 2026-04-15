// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IWithdrawalManagerLike {
    function userEscrowedShares(address _owner) external view returns (uint256);
    function processRedemptions(uint256 maxSharesToProcess_) external;
    function manualSharesAvailable(address _owner) external view returns (uint256);
}

