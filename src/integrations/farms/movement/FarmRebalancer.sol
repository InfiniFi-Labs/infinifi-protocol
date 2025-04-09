// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice InfiniFi manual rebalancer, allows to move funds between farms.
contract FarmRebalancer is CoreControlled {
    error InactiveRebalancer();
    error InvalidFarm(address farm);
    error IncompatibleAssets();
    error EmptyInput();
    error InvalidInput();
    /// @notice event emitted when funds are moved between farms

    event Allocate(uint256 indexed timestamp, address indexed from, address indexed to, address asset, uint256 amount);

    /// @notice reference to the farm registry
    address public immutable farmRegistry;

    constructor(address _core, address _farmRegistry) CoreControlled(_core) {
        farmRegistry = _farmRegistry;
    }

    /// @notice batch movement between farms,
    /// this is a convenience function that allows to move funds between farms in a single call without having to call singleMovement multiple times
    /// @dev all arrays must have the same length and non-zero length
    /// @param _from array of farm addresses to move funds from
    /// @param _to array of farm addresses to move funds to
    /// @param _amounts array of amounts to move
    function batchMovement(address[] memory _from, address[] memory _to, uint256[] memory _amounts)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_MANAGER_ADMIN)
    {
        require(_from.length > 0, EmptyInput());
        require(_from.length == _to.length && _from.length == _amounts.length, InvalidInput());

        for (uint256 i = 0; i < _from.length; i++) {
            singleMovement(_from[i], _to[i], _amounts[i]);
        }
    }

    /// @notice perform a single movement between two farms
    /// @dev An allocation amount of 0 is interpreted as a full liquidity() movement.
    /// @dev An allocation amount of type(uint256).max is interpreted as a full assets() movement.
    function singleMovement(address _from, address _to, uint256 _amount)
        public
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_MANAGER_ADMIN)
        returns (uint256)
    {
        require(FarmRegistry(farmRegistry).isFarm(_from), InvalidFarm(_from));
        require(FarmRegistry(farmRegistry).isFarm(_to), InvalidFarm(_to));
        address _asset = IFarm(_from).assetToken();
        require(IFarm(_to).assetToken() == _asset, IncompatibleAssets());

        // compute amount to withdraw
        if (_amount == 0) {
            _amount = IFarm(_from).liquidity();
        } else if (_amount == type(uint256).max) {
            _amount = IFarm(_from).assets();
        }

        // Check if amount is greater than max deposit
        _amount = _amount > IFarm(_from).maxDeposit() ? IFarm(_from).maxDeposit() : _amount;

        // perform movement
        IFarm(_from).withdraw(_amount, _to);
        IFarm(_to).deposit();

        // emit event
        emit Allocate({timestamp: block.timestamp, from: _from, to: _to, asset: _asset, amount: _amount});

        return _amount;
    }
}
