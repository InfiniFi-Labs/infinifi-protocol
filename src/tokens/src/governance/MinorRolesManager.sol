// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @title A contract to manage minor roles
contract MinorRolesManager is CoreControlled {
    constructor(address _core) CoreControlled(_core) {}

    function grantPause(address _account) external onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER) {
        core().grantRole(CoreRoles.PAUSE, _account);
    }

    function revokePause(address _account) external onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER) {
        core().revokeRole(CoreRoles.PAUSE, _account);
    }

    function grantPeriodicRebalancer(address _account) external onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER) {
        core().grantRole(CoreRoles.PERIODIC_REBALANCER, _account);
    }

    function revokePeriodicRebalancer(address _account) external onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER) {
        core().revokeRole(CoreRoles.PERIODIC_REBALANCER, _account);
    }

    function grantFarmSwapCaller(address _account) external onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER) {
        core().grantRole(CoreRoles.FARM_SWAP_CALLER, _account);
    }

    function revokeFarmSwapCaller(address _account) external onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER) {
        core().revokeRole(CoreRoles.FARM_SWAP_CALLER, _account);
    }
}
