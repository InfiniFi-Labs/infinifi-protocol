// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMaplePoolLike {
    function manager() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToExitAssets(uint256 shares) external view returns (uint256 assets);
    function requestRedeem(uint256 shares, address receiver) external returns (uint256 escrowedShares);
}

