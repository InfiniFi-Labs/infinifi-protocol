// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FarmTypes} from "@libraries/FarmTypes.sol";
import {Accounting} from "@finance/Accounting.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @title A contract to help clean up matured farms
/// This contract needs PROTOCOL_PARAMETERS & PAUSE roles.
contract MaturedFarmCleaner is CoreControlled {
    error InvalidFarm(address _farm);
    error MaturityNotReached(address _farm);
    error AssetsValueTooHigh(address _farm, uint256 _assetsValue, uint256 _threshold);

    event FarmRemoved(uint256 indexed timestamp, address _farm);

    /// @notice reference to the accounting contract
    address public immutable accounting;
    /// @notice reference to the farm registry contract
    address public immutable farmRegistry;
    /// @notice dollar value threshold for removing a farm
    uint256 public constant THRESHOLD = 10 * 1e18; // $10

    constructor(address _core, address _accounting, address _farmRegistry) CoreControlled(_core) {
        accounting = _accounting;
        farmRegistry = _farmRegistry;
    }

    /// @notice remove a matured farm from the registry and pause it
    /// @param _farm the farm to remove
    function removeMaturedFarm(address _farm) external whenNotPaused {
        // check that the farm is in the registry and illiquid type
        require(FarmRegistry(farmRegistry).isFarmOfType(_farm, FarmTypes.MATURITY), InvalidFarm(_farm));
        // check that the farm has matured (this will revert if the farm is not a maturity farm)
        require(IMaturityFarm(_farm).maturity() < block.timestamp, MaturityNotReached(_farm));

        uint256 illiquidAssetsBefore = Accounting(accounting).totalAssetsValueOf(FarmTypes.MATURITY);

        // remove farm from registry
        address[] memory farmsToRemove = new address[](1);
        farmsToRemove[0] = _farm;
        FarmRegistry(farmRegistry).removeFarms(FarmTypes.MATURITY, farmsToRemove);

        // check that the total illiquid assets has decreased by less than THRESHOLD
        uint256 illiquidAssetsAfter = Accounting(accounting).totalAssetsValueOf(FarmTypes.MATURITY);
        uint256 assetsDecrease = illiquidAssetsBefore - illiquidAssetsAfter;
        require(assetsDecrease <= THRESHOLD, AssetsValueTooHigh(_farm, assetsDecrease, THRESHOLD));

        // pause the deprecated farm
        CoreControlled(_farm).pause();

        emit FarmRemoved(block.timestamp, _farm);
    }
}
