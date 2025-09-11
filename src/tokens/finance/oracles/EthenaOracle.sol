// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Returns the price of sUSDe, in $ with 18 decimals.
/// The vault share price is used to convert sUSDe to USDe, and USDe is hardcoded to $1.
contract EthenaOracle is IOracle {
    address public constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    function price() external view override returns (uint256) {
        return ERC4626(sUSDe).convertToAssets(1e18);
    }
}
