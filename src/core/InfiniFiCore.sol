// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";

/// @notice Maintains roles and access control
contract InfiniFiCore is AccessControlEnumerable {
    error RoleAlreadyExists(bytes32 role);
    error RoleDoesNotExist(bytes32 role);
    error LengthMismatch(uint256 expected, uint256 actual);

    /// @notice construct Core
    constructor() {
        // For initial setup before going live, deployer can then call
        // renounceRole(bytes32 role, address account)
        _grantRole(CoreRoles.GOVERNOR, msg.sender);

        // Initial roles setup: direct hierarchy, everything under governor
        _setRoleAdmin(CoreRoles.GOVERNOR, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.GUARDIAN, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.ENTRY_POINT, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.RECEIPT_TOKEN_MINTER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.RECEIPT_TOKEN_BURNER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.LOCKED_TOKEN_MANAGER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.ACTION_RESTRICTOR, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.FARM_MANAGER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.FARM_MANAGER_ADMIN, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.FARM_SWAP_CALLER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.ORACLE_MANAGER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.FINANCE_MANAGER, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.PROPOSER_ROLE, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.EXECUTOR_ROLE, CoreRoles.GOVERNOR);
        _setRoleAdmin(CoreRoles.CANCELLER_ROLE, CoreRoles.GOVERNOR);
    }

    /// @notice creates a new role to be maintained
    /// @param role the new role id
    /// @param adminRole the admin role id for `role`
    function createRole(bytes32 role, bytes32 adminRole) external onlyRole(CoreRoles.GOVERNOR) {
        require(getRoleAdmin(role) == bytes32(0), RoleAlreadyExists(role));
        _setRoleAdmin(role, adminRole);
    }

    /// @notice override admin role of an existing role
    /// @param role the role id
    /// @param adminRole the admin role id
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(CoreRoles.GOVERNOR) {
        require(getRoleAdmin(role) != bytes32(0), RoleDoesNotExist(role));
        _setRoleAdmin(role, adminRole);
    }

    /// @notice batch granting of roles to various addresses
    /// @dev if msg.sender does not have admin role needed to grant any of the
    /// granted roles, the whole transaction reverts.
    function grantRoles(bytes32[] calldata roles, address[] calldata accounts) external {
        require(roles.length == accounts.length, LengthMismatch(roles.length, accounts.length));
        for (uint256 i = 0; i < roles.length; i++) {
            _checkRole(getRoleAdmin(roles[i]));
            _grantRole(roles[i], accounts[i]);
        }
    }
}
