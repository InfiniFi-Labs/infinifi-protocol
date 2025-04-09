// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";
import {CoreControlled, CoreRoles} from "@core/CoreControlled.sol";

contract FixedPriceOracle is IOracle, CoreControlled {
    uint256 public price;

    constructor(address _core, uint256 _price) CoreControlled(_core) {
        price = _price;
    }

    function setPrice(uint256 _price) external onlyCoreRole(CoreRoles.ORACLE_MANAGER) {
        price = _price;
    }
}
