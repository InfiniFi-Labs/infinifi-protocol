// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPoolPermissionManagerLike {
    function setLenderBitmaps(address[] calldata lenders_, uint256[] calldata bitmaps_) external;
}

