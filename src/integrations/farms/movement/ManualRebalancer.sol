// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";

/// @notice InfiniFi manual rebalancer, allows to move funds between farms.
contract ManualRebalancer is CoreControlled {
    error InactiveRebalancer();
    error InvalidFarm(address farm);
    error IncompatibleAssets();
    error EmptyInput();
    error InvalidInput();
    error CooldownNotElapsed();

    /// @notice cooldown between rebalances
    uint256 public cooldown;

    /// @notice last rebalance timestamp
    uint256 public lastRebalance;

    /// @notice event emitted when new cooldown is set
    event CooldownUpdated(uint256 indexed timestamp, uint256 cooldown);
    /// @notice event emitted when funds are moved between farms
    event Allocate(uint256 indexed timestamp, address indexed from, address indexed to, address asset, uint256 amount);

    /// @notice reference to the farm registry
    address public immutable farmRegistry;

    constructor(address _core, address _farmRegistry) CoreControlled(_core) {
        farmRegistry = _farmRegistry;

        // default values
        cooldown = 4 hours;
        lastRebalance = block.timestamp - 4 hours;
    }

    /// @notice set cooldown
    function setCooldown(uint256 _cooldown) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        cooldown = _cooldown;
        emit CooldownUpdated(block.timestamp, cooldown);
    }

    /// @notice batch movement between farms, with a cooldown
    function batchMovementWithCooldown(address[] calldata _from, address[] calldata _to, uint256[] calldata _amounts)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.PERIODIC_REBALANCER)
    {
        require(block.timestamp - cooldown >= lastRebalance, CooldownNotElapsed());
        lastRebalance = block.timestamp;
        _batchMovement(_from, _to, _amounts);
    }

    /// @notice batch movement between farms,
    /// this is a convenience function that allows to move funds between farms in a single call without having to call singleMovement multiple times
    /// @dev all arrays must have the same length and non-zero length
    /// @param _from array of farm addresses to move funds from
    /// @param _to array of farm addresses to move funds to
    /// @param _amounts array of amounts to move
    function batchMovement(address[] calldata _from, address[] calldata _to, uint256[] calldata _amounts)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.MANUAL_REBALANCER)
    {
        _batchMovement(_from, _to, _amounts);
    }

    /// @notice perform a single movement between two farms
    function singleMovement(address _from, address _to, uint256 _amount)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.MANUAL_REBALANCER)
        returns (uint256)
    {
        return _singleMovement(_from, _to, _amount);
    }

    function _batchMovement(address[] calldata _from, address[] calldata _to, uint256[] calldata _amounts) internal {
        require(_from.length > 0, EmptyInput());
        require(_from.length == _to.length && _from.length == _amounts.length, InvalidInput());

        for (uint256 i = 0; i < _from.length; i++) {
            _singleMovement(_from[i], _to[i], _amounts[i]);
        }
    }

    /// @notice perform a single movement between two farms
    /// @dev An allocation amount of 0 is interpreted as a full liquidity() movement.
    /// @dev An allocation amount of type(uint256).max is interpreted as a full assets() movement.
    function _singleMovement(address _from, address _to, uint256 _amount) internal returns (uint256) {
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

        uint256 maxDeposit = IFarm(_to).maxDeposit();
        // Check if amount is greater than max deposit
        _amount = _amount > maxDeposit ? maxDeposit : _amount;

        // perform movement
        IFarm(_from).withdraw(_amount, _to);
        IFarm(_to).deposit();

        // emit event
        emit Allocate({timestamp: block.timestamp, from: _from, to: _to, asset: _asset, amount: _amount});

        return _amount;
    }

    function singleMovementSecondaryAsset(address _from, address _to, address _assetToken, uint256 _amount)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.MANUAL_REBALANCER)
        returns (uint256)
    {
        return _singleMovementSecondaryAsset(_from, _to, _assetToken, _amount);
    }

    /// @notice perform a single movement of secondary asset between two farms
    /// @dev An allocation amount of type(uint256).max is interpreted as a full balance movement.
    function _singleMovementSecondaryAsset(address _from, address _to, address _asset, uint256 _amount)
        internal
        returns (uint256)
    {
        require(FarmRegistry(farmRegistry).isFarm(_from), InvalidFarm(_from));
        require(FarmRegistry(farmRegistry).isFarm(_to), InvalidFarm(_to));
        address _fromAssetToken = IFarm(_from).assetToken();
        address _toAssetToken = IFarm(_to).assetToken();

        require(_asset == _fromAssetToken || MultiAssetFarm(_from).isAssetSupported(_asset), IncompatibleAssets());
        require(_asset == _toAssetToken || MultiAssetFarm(_to).isAssetSupported(_asset), IncompatibleAssets());

        if (_asset == _fromAssetToken) {
            if (_amount == type(uint256).max) _amount = IFarm(_from).liquidity();
            IFarm(_from).withdraw(_amount, _to);
        } else {
            if (_amount == type(uint256).max) _amount = IERC20(_asset).balanceOf(_from);
            MultiAssetFarm(_from).withdrawSecondaryAsset(_asset, _amount, _to);
        }

        // trigger deposit in destination farm
        IFarm(_to).deposit();

        // emit event
        emit Allocate({timestamp: block.timestamp, from: _from, to: _to, asset: _asset, amount: _amount});

        return _amount;
    }
}
