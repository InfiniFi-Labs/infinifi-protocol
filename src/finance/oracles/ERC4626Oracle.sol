// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IOracle} from "@interfaces/IOracle.sol";

/// @notice Returns the price of an ERC4626 vault share token, in $ with 18 decimals.
contract ERC4626Oracle is IOracle {
    using FixedPointMathLib for uint256;

    address public immutable vault;
    address public immutable assetOracle;

    constructor(address _vault, address _assetOracle) {
        vault = _vault;
        assetOracle = _assetOracle;
    }

    function price() external view override returns (uint256) {
        uint256 assetPrice = IOracle(assetOracle).price();
        uint256 sharePrice = ERC4626(vault).convertToAssets(FixedPointMathLib.WAD);
        return sharePrice.mulWadDown(assetPrice);
    }
}
