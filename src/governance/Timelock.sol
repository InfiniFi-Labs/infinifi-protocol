// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {CoreControlled} from "@core/CoreControlled.sol";

/// @title An override of the regular OZ governance/TimelockController to allow uniform
/// access control in the InfiniFi system based on roles defined in Core.
/// @dev The roles and roles management from OZ access/AccessControl.sol are ignored, we
/// chose not to fork TimelockController and just bypass its access control system, to
/// introduce as few code changes as possible on top of OpenZeppelin's governance code.
contract Timelock is TimelockController, CoreControlled {
    constructor(address _core, uint256 _minDelay)
        CoreControlled(_core)
        TimelockController(_minDelay, new address[](0), new address[](0), address(0))
    {
        _setRoleAdmin(DEFAULT_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _revokeRole(DEFAULT_ADMIN_ROLE, address(this));
    }

    /// @dev override of OZ access/AccessControl.sol inherited by governance/TimelockController.sol
    /// This will check roles with Core, and not with the storage mapping from AccessControl.sol
    function hasRole(bytes32 role, address account) public view virtual override returns (bool) {
        return core().hasRole(role, account);
    }

    /// @dev override of OZ access/AccessControl.sol, noop because role management is handled in Core.
    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal override {}

    /// @dev override of OZ access/AccessControl.sol, noop because role management is handled in Core.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {}

    /// @dev override of OZ access/AccessControl.sol, noop because role management is handled in Core.
    function _revokeRole(bytes32 role, address account) internal override returns (bool) {}
}
