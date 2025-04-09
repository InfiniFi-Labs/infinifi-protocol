// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice InfiniFi Farm registry
contract FarmRegistry is CoreControlled {
    error FarmAlreadyAdded(address farm);
    error FarmNotFound(address farm);
    error AssetNotEnabled(address farm, address asset);
    error AssetAlreadyEnabled(address asset);
    error AssetNotFound(address asset);

    event AssetEnabled(uint256 indexed timestamp, address asset);
    event AssetDisabled(uint256 indexed timestamp, address asset);
    event FarmsAdded(uint256 indexed timestamp, uint256 farmType, address[] indexed farms);
    event FarmsRemoved(uint256 indexed timestamp, uint256 farmType, address[] indexed farms);

    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private assets;
    EnumerableSet.AddressSet private farms;
    mapping(uint256 _type => EnumerableSet.AddressSet _farms) private typeFarms;
    mapping(address _asset => EnumerableSet.AddressSet _farms) private assetFarms;
    mapping(address _asset => mapping(uint256 _type => EnumerableSet.AddressSet _farms)) private assetFarmTypes;

    constructor(address _core) CoreControlled(_core) {}

    /// ----------------------------------------------------------------------------
    /// READ METHODS
    /// ----------------------------------------------------------------------------

    function getEnabledAssets() external view returns (address[] memory) {
        return assets.values();
    }

    function isAssetEnabled(address _asset) external view returns (bool) {
        return assets.contains(_asset);
    }

    function getFarms() external view returns (address[] memory) {
        return farms.values();
    }

    function getTypeFarms(uint256 _type) external view returns (address[] memory) {
        return typeFarms[_type].values();
    }

    function getAssetFarms(address _asset) external view returns (address[] memory) {
        return assetFarms[_asset].values();
    }

    function getAssetTypeFarms(address _asset, uint256 _type) external view returns (address[] memory) {
        return assetFarmTypes[_asset][_type].values();
    }

    function isFarm(address _farm) external view returns (bool) {
        return farms.contains(_farm);
    }

    function isFarmOfAsset(address _farm, address _asset) external view returns (bool) {
        return assetFarms[_asset].contains(_farm);
    }

    function isFarmOfType(address _farm, uint256 _type) external view returns (bool) {
        return typeFarms[_type].contains(_farm);
    }

    /// ----------------------------------------------------------------------------
    /// WRITE METHODS
    /// ----------------------------------------------------------------------------

    function enableAsset(address _asset) external onlyCoreRole(CoreRoles.GOVERNOR) {
        require(assets.add(_asset), AssetAlreadyEnabled(_asset));
        emit AssetEnabled(block.timestamp, _asset);
    }

    function disableAsset(address _asset) external onlyCoreRole(CoreRoles.GOVERNOR) {
        require(assets.remove(_asset), AssetNotFound(_asset));
        emit AssetDisabled(block.timestamp, _asset);
    }

    function addFarms(uint256 _type, address[] calldata _list) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _addFarms(_type, _list);
        emit FarmsAdded(block.timestamp, _type, _list);
    }

    function removeFarms(uint256 _type, address[] calldata _list) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _removeFarms(_type, _list);
        emit FarmsRemoved(block.timestamp, _type, _list);
    }

    /// ----------------------------------------------------------------------------
    /// INTERNAL METHODS
    /// ----------------------------------------------------------------------------

    function _addFarms(uint256 _type, address[] calldata _list) internal {
        for (uint256 i = 0; i < _list.length; i++) {
            address farmAsset = IFarm(_list[i]).assetToken();
            require(assets.contains(farmAsset), AssetNotEnabled(_list[i], farmAsset));
            require(farms.add(_list[i]), FarmAlreadyAdded(_list[i]));
            require(typeFarms[_type].add(_list[i]), FarmAlreadyAdded(_list[i]));
            require(assetFarms[farmAsset].add(_list[i]), FarmAlreadyAdded(_list[i]));
            require(assetFarmTypes[farmAsset][_type].add(_list[i]), FarmAlreadyAdded(_list[i]));
        }
    }

    function _removeFarms(uint256 _type, address[] calldata _list) internal {
        for (uint256 i = 0; i < _list.length; i++) {
            address farmAsset = IFarm(_list[i]).assetToken();
            require(farms.remove(_list[i]), FarmNotFound(_list[i]));
            require(typeFarms[_type].remove(_list[i]), FarmNotFound(_list[i]));
            require(assetFarms[farmAsset].remove(_list[i]), FarmNotFound(_list[i]));
            require(assetFarmTypes[farmAsset][_type].remove(_list[i]), FarmNotFound(_list[i]));
        }
    }
}
