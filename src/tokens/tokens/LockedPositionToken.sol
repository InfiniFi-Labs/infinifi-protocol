// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice InfiniFi Locked Position Token.
contract LockedPositionToken is CoreControlled, ERC20Permit, ERC20Burnable {
    /// @notice thrown when a user with transfer restrictions tries to transfer
    error TransferRestrictedUntil(address user, uint256 timestamp);

    /// @notice mapping of transfer restrictions: from address to timestamp after which transfers/redemptions are allowed
    mapping(address => uint256) public transferRestrictions;

    constructor(address _core, string memory _name, string memory _symbol)
        CoreControlled(_core)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
    {}

    function mint(address _to, uint256 _amount) external onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        _mint(_to, _amount);
    }

    function burn(uint256 _value) public override onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        _burn(_msgSender(), _value);
    }

    function burnFrom(address _account, uint256 _value) public override onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        _spendAllowance(_account, _msgSender(), _value);
        _burn(_account, _value);
    }

    /// @notice restricts transfers until the next epoch
    function restrictTransferUntilNextEpoch(address _user) external onlyCoreRole(CoreRoles.TRANSFER_RESTRICTOR) {
        transferRestrictions[_user] = EpochLib.epochToTimestamp(EpochLib.nextEpoch(block.timestamp));
    }

    /// ---------------------------------------------------------------------------
    /// Transfer restrictions
    /// ---------------------------------------------------------------------------

    function _update(address _from, address _to, uint256 _value) internal override {
        uint256 restriction = transferRestrictions[_from];
        // if it's 0, storage is unset so user has no transfer restriction
        if (restriction > 0) {
            require(block.timestamp >= restriction, TransferRestrictedUntil(_from, restriction));
        }

        return ERC20._update(_from, _to, _value);
    }
}
