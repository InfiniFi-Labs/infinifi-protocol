// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMaplePoolManagerLike {
    function poolPermissionManager() external view returns (address);
    function withdrawalManager() external view returns (address);
}

