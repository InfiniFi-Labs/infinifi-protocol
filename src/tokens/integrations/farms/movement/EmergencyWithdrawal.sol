// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Farm} from "@integrations/Farm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @title A contract to manage emergency withdrawals from farms.
/// This contract can move funds from farms to a safe address,
/// and pause the farms to prevent further deposits and withdrawals.
/// If more liquidity becomes available to the farm, the contract can
/// unpause the farm, withdraw from it, and repause it atomically.
contract EmergencyWithdrawal is CoreControlled {
    using EnumerableSet for EnumerableSet.AddressSet;

    error FarmAlreadyDeprecated(address farm);
    error FarmNotDeprecated(address farm);

    event SafeAddressChange(uint256 indexed timestamp, address safeAddress);
    event FarmDeprecationChange(uint256 indexed timestamp, address farm, bool deprecated);
    event EmergencyWithdraw(uint256 indexed timestamp, address farm, uint256 amount);

    EnumerableSet.AddressSet private deprecatedFarms;

    /// @notice safe address to move funds to
    /// @dev be careful when configuring this address during protocol deployment,
    /// as since there is no deposit() call, the safe address is not necessarily
    /// a Farm, and may not report the assets held properly.
    /// In the first version of the protocol that is deployed, the MintController
    /// is meant to be used as the safe address.
    address public safeAddress;

    constructor(address _core, address _safeAddress) CoreControlled(_core) {
        safeAddress = _safeAddress;
        emit SafeAddressChange(block.timestamp, _safeAddress);
        assert(safeAddress != address(0));
    }

    function setSafeAddress(address _safeAddress) external onlyCoreRole(CoreRoles.GOVERNOR) {
        safeAddress = _safeAddress;
        emit SafeAddressChange(block.timestamp, _safeAddress);
        assert(safeAddress != address(0));
    }

    function getDeprecatedFarms() external view returns (address[] memory) {
        return deprecatedFarms.values();
    }

    function setDeprecated(address _farm) external onlyCoreRole(CoreRoles.EMERGENCY_WITHDRAWAL) {
        require(deprecatedFarms.add(_farm), FarmAlreadyDeprecated(_farm));

        if (!Farm(_farm).paused()) {
            Farm(_farm).pause();
        }

        emit FarmDeprecationChange(block.timestamp, _farm, true);
    }

    function setNotDeprecated(address _farm) external onlyCoreRole(CoreRoles.EMERGENCY_WITHDRAWAL) {
        require(deprecatedFarms.remove(_farm), FarmNotDeprecated(_farm));

        emit FarmDeprecationChange(block.timestamp, _farm, false);
    }

    function isDeprecated(address _farm) external view returns (bool) {
        return deprecatedFarms.contains(_farm);
    }

    /// @notice unprotected call to withdraw from deprecated farms
    function deprecatedWithdraw(address _farm, uint256 _amount) external {
        require(deprecatedFarms.contains(_farm), FarmNotDeprecated(_farm));

        _emergencyWithdraw(_farm, _amount);
    }

    /// @notice protected call to do an emergency withdrawal from any farm
    function emergencyWithdraw(address _farm, uint256 _amount) external onlyCoreRole(CoreRoles.EMERGENCY_WITHDRAWAL) {
        _emergencyWithdraw(_farm, _amount);
    }

    function _emergencyWithdraw(address _farm, uint256 _amount) internal {
        // either use the provided amount, or read the available liquidity
        if (_amount == 0) {
            _amount = Farm(_farm).liquidity();
        }

        // unpause the farm if it is paused
        if (Farm(_farm).paused()) {
            Farm(_farm).unpause();
        }

        // withdraw the amount from the farm
        Farm(_farm).withdraw(_amount, safeAddress);

        // pause the farm (again or for the first time)
        Farm(_farm).pause();

        emit EmergencyWithdraw(block.timestamp, _farm, _amount);
    }
}
