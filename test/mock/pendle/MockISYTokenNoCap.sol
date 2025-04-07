// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "@test/mock/MockERC20.sol";
import {ISYToken} from "@interfaces/pendle/ISYToken.sol";

contract MockISYTokenNoCap is MockERC20 {
    uint256 public absoluteSupplyCap;
    uint256 public absoluteTotalSupply;

    function test() public pure override {}

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}
}
