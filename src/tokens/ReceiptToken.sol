// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ActionRestriction} from "@core/ActionRestriction.sol";

/// @notice InfiniFi Receipt Token.
contract ReceiptToken is ActionRestriction, ERC20Permit, ERC20Burnable {
    constructor(address _core, string memory _name, string memory _symbol)
        ActionRestriction(_core)
        ERC20(_name, _symbol)
        ERC20Permit(_name)
    {}

    /// ---------------------------------------------------------------------------
    /// Supply management
    /// ---------------------------------------------------------------------------

    function mint(address _to, uint256 _amount) external onlyCoreRole(CoreRoles.RECEIPT_TOKEN_MINTER) {
        _mint(_to, _amount);
    }

    function burn(uint256 _value) public override onlyCoreRole(CoreRoles.RECEIPT_TOKEN_BURNER) {
        _burn(_msgSender(), _value);
    }

    function burnFrom(address _account, uint256 _value) public override onlyCoreRole(CoreRoles.RECEIPT_TOKEN_BURNER) {
        _spendAllowance(_account, _msgSender(), _value);
        _burn(_account, _value);
    }

    /// ---------------------------------------------------------------------------
    /// Transfer restrictions
    /// ---------------------------------------------------------------------------

    function _update(address _from, address _to, uint256 _value) internal override {
        if (_from != address(0)) {
            // check action restrictions if the transfer is not a mint
            _checkActionRestriction(_from);
        }
        return ERC20._update(_from, _to, _value);
    }
}
