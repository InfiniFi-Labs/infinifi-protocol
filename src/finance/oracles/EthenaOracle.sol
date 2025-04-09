// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IOracle} from "@interfaces/IOracle.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice Returns the price of sUSDe, looking only at the exchange rate of the vault,
/// and hardcoding the value of USDC & USDe to 1$.
contract EthenaOracle is IOracle {
    address public sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    function price() external view override returns (uint256) {
        return 1e36 / ERC4626(sUSDe).convertToAssets(1e6);
    }
}
