// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice Abstract util to restrict actions (transfers/redemptions) until a given timestamp
abstract contract ActionRestriction is CoreControlled {
    error ActionRestricted(address user, uint256 timestamp);

    /// @notice mapping of transfer/redemption restrictions: from address to timestamp after which transfers/redemptions are allowed
    mapping(address => uint256) public restrictions;

    constructor(address _core) CoreControlled(_core) {}

    /// @notice restricts transfers until the given timestamp
    function restrictActionUntil(address _user, uint256 _timestamp)
        external
        onlyCoreRole(CoreRoles.ACTION_RESTRICTOR)
    {
        restrictions[_user] = _timestamp;
    }

    /// @notice prevents actions until the restriction timestamp
    function _checkActionRestriction(address _from) internal view {
        uint256 restriction = restrictions[_from];
        // if it's 0, storage is unset so user has no transfer restriction
        if (restriction > 0) {
            require(block.timestamp >= restriction, ActionRestricted(_from, restriction));
        }
    }
}
