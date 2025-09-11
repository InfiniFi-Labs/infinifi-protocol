// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";

interface IResolvFundamentalPriceOracle {
    function lastPrice()
        external
        view
        returns (uint256 price, uint256 usrSupply, uint256 reserves, uint256 timestamp);
}

/// @notice Returns the price of USR, in $ with 18 decimals.
contract ResolvOracle is IOracle {
    address public constant fundamentalPriceOracle = 0x7f45180d6fFd0435D8dD695fd01320E6999c261c;

    function price() external view override returns (uint256) {
        (uint256 _price,,,) = IResolvFundamentalPriceOracle(fundamentalPriceOracle).lastPrice();
        return _price; // already has 18 decimals
    }
}
