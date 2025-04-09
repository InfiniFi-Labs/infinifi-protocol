// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {IOracle} from "@interfaces/IOracle.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";

/// @notice InfiniFi Accounting contract
contract Accounting is CoreControlled {
    using FixedPointMathLib for uint256;

    /// @notice reference to the farm registry
    address public immutable farmRegistry;

    constructor(address _core, address _farmRegistry) CoreControlled(_core) {
        farmRegistry = _farmRegistry;
    }

    /// @notice mapping from asset to oracle
    mapping(address => address) public oracle;

    /// @notice returns the price of an asset
    function price(address _asset) external view returns (uint256) {
        return IOracle(oracle[_asset]).price();
    }

    /// @notice set the oracle for an asset
    function setOracle(address _asset, address _oracle) external onlyCoreRole(CoreRoles.ORACLE_MANAGER) {
        oracle[_asset] = _oracle;
    }

    /// @notice set the price of an asset
    function setPrice(address _asset, uint256 _price) external onlyCoreRole(CoreRoles.ORACLE_MANAGER) {
        FixedPriceOracle(oracle[_asset]).setPrice(_price);
    }

    /// -------------------------------------------------------------------------------------------
    /// Reference token getters (e.g. USD for iUSD, ETH for iETH, ...)
    /// @dev note that the "USD" token does not exist, it is just an abstract unit of account
    /// used in the protocol to represent stablecoins pegged to USD, that allows to uniformly
    /// account for a diverse reserve composed of USDC, DAI, FRAX, etc.
    /// -------------------------------------------------------------------------------------------

    /// @notice returns the sum of the value of all assets held on protocol contracts listed in the farm registry.
    function totalAssetsValue() external view returns (uint256 _totalValue) {
        address[] memory assets = FarmRegistry(farmRegistry).getEnabledAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 assetPrice = IOracle(oracle[assets[i]]).price();
            uint256 _assets = _calculateTotalAssets(FarmRegistry(farmRegistry).getAssetFarms(assets[i]));
            _totalValue += _assets.mulWadDown(assetPrice);
        }
    }

    /// @notice returns the sum of the value of all liquid assets held on protocol contracts listed in the farm registry.
    /// @dev see totalAssetsValue()
    function totalAssetsValueOf(uint256 _type) external view returns (uint256 _totalValue) {
        address[] memory assets = FarmRegistry(farmRegistry).getEnabledAssets();
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 assetPrice = IOracle(oracle[assets[i]]).price();
            address[] memory assetFarms = FarmRegistry(farmRegistry).getAssetTypeFarms(assets[i], uint256(_type));
            uint256 _assets = _calculateTotalAssets(assetFarms);
            _totalValue += _assets.mulWadDown(assetPrice);
        }
    }

    /// -------------------------------------------------------------------------------------------
    /// Specific asset getters (e.g. USDC, DAI, ...)
    /// -------------------------------------------------------------------------------------------

    /// @notice returns the sum of the balance of all farms of a given asset.
    function totalAssets(address _asset) external view returns (uint256) {
        return _calculateTotalAssets(FarmRegistry(farmRegistry).getAssetFarms(_asset));
    }

    function totalAssetsOf(address _asset, uint256 _type) external view returns (uint256) {
        return _calculateTotalAssets(FarmRegistry(farmRegistry).getAssetTypeFarms(_asset, uint256(_type)));
    }

    /// -------------------------------------------------------------------------------------------
    /// Internal helpers
    /// -------------------------------------------------------------------------------------------

    function _calculateTotalAssets(address[] memory _farms) internal view returns (uint256 _totalAssets) {
        uint256 length = _farms.length;
        for (uint256 index = 0; index < length; index++) {
            _totalAssets += IFarm(_farms[index]).assets();
        }
    }
}
