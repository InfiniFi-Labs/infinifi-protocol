// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ISYToken {
    function getAbsoluteSupplyCap() external view returns (uint256);

    function getAbsoluteTotalSupply() external view returns (uint256);

    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals);

    function yieldToken() external view returns (address);
}
