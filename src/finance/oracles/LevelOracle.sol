// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";

interface ILevelReserveLens {
    // Returns the reserve price of lvlUSD.
    // If the reserves are overcollateralized, return $1 (1e18).
    // Otherwise, return the ratio of USD reserves to lvlUSD supply.
    function getReservePrice() external view returns (uint256);
}

/// @notice Returns the price of lvlUSD, in $ with 18 decimals.
contract LevelOracle is IOracle {
    address public immutable levelReserveLens;

    constructor(address _levelReserveLens) {
        levelReserveLens = _levelReserveLens;
    }

    function price() external view override returns (uint256) {
        uint256 _price = ILevelReserveLens(levelReserveLens).getReservePrice();
        return _price;
    }
}
