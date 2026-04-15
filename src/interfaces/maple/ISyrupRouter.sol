// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ISyrupRouter {
    function deposit(uint256 amount, bytes32 depositData) external returns (uint256 shares);
    function authorizeAndDeposit(
        uint256 bitmap,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint256 amount,
        bytes32 depositData
    ) external returns (uint256 shares);
}

