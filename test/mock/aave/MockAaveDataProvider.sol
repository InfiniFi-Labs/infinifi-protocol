// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAaveDataProvider} from "@interfaces/aave/IAaveDataProvider.sol";

contract MockAaveDataProvider is IAaveDataProvider {
    uint256 public borrowCap;
    uint256 public supplyCap;

    constructor(uint256 _borrowCap, uint256 _supplyCap) {
        borrowCap = _borrowCap;
        supplyCap = _supplyCap;
    }

    // disable coverage for this contract
    function test() public view {}

    // Aave returns the borrow cap and supply cap for the asset with 0 decimals
    // example for 1000 USDC it returns 1000 !
    function getReserveCaps(address /* _asset*/ ) external view returns (uint256, uint256) {
        return (borrowCap, supplyCap);
    }

    function setBorrowCap(uint256 _borrowCap) external {
        borrowCap = _borrowCap;
    }

    function setSupplyCap(uint256 _supplyCap) external {
        supplyCap = _supplyCap;
    }
}
