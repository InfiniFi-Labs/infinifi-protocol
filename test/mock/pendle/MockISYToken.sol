// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "@test/mock/MockERC20.sol";
import {ISYToken} from "@interfaces/pendle/ISYToken.sol";

contract MockISYToken is MockERC20, ISYToken {
    uint256 public absoluteSupplyCap;
    uint256 public absoluteTotalSupply;

    function test() public pure override {}

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function getAbsoluteSupplyCap() external view returns (uint256) {
        return absoluteSupplyCap;
    }

    function getAbsoluteTotalSupply() external view returns (uint256) {
        return absoluteTotalSupply;
    }

    function setAbsoluteSupplyCap(uint256 _absoluteSupplyCap) external {
        absoluteSupplyCap = _absoluteSupplyCap;
    }

    function setAbsoluteTotalSupply(uint256 _absoluteTotalSupply) external {
        absoluteTotalSupply = _absoluteTotalSupply;
    }

    function assetInfo() external view returns (uint8 assetType, address assetAddress, uint8 assetDecimals) {
        return (0, address(this), 18);
    }
}
