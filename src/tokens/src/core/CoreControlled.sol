// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";

/// @notice Defines some modifiers and utilities around interacting with Core
abstract contract CoreControlled is Pausable {
    error UnderlyingCallReverted(bytes returnData);

    /// @notice emitted when the reference to core is updated
    event CoreUpdate(address indexed oldCore, address indexed newCore);

    /// @notice reference to Core
    InfiniFiCore private _core;

    constructor(address coreAddress) {
        _core = InfiniFiCore(coreAddress);
    }

    /// @notice named onlyCoreRole to prevent collision with OZ onlyRole modifier
    modifier onlyCoreRole(bytes32 role) {
        require(_core.hasRole(role, msg.sender), "UNAUTHORIZED");
        _;
    }

    /// @notice address of the Core contract referenced
    function core() public view returns (InfiniFiCore) {
        return _core;
    }

    /// @notice WARNING CALLING THIS FUNCTION CAN POTENTIALLY
    /// BRICK A CONTRACT IF CORE IS SET INCORRECTLY
    /// @notice set new reference to core
    /// only callable by governor
    /// @param newCore to reference
    function setCore(address newCore) external onlyCoreRole(CoreRoles.GOVERNOR) {
        _setCore(newCore);
    }

    /// @notice WARNING CALLING THIS FUNCTION CAN POTENTIALLY
    /// BRICK A CONTRACT IF CORE IS SET INCORRECTLY
    /// @notice set new reference to core
    /// @param newCore to reference
    function _setCore(address newCore) internal {
        address oldCore = address(_core);
        _core = InfiniFiCore(newCore);

        emit CoreUpdate(oldCore, newCore);
    }

    /// @notice set pausable methods to paused
    function pause() public onlyCoreRole(CoreRoles.PAUSE) {
        _pause();
    }

    /// @notice set pausable methods to unpaused
    function unpause() public onlyCoreRole(CoreRoles.UNPAUSE) {
        _unpause();
    }

    /// ------------------------------------------
    /// ------------ Emergency Action ------------
    /// ------------------------------------------

    /// inspired by MakerDAO Multicall:
    /// https://github.com/makerdao/multicall/blob/master/src/Multicall.sol

    /// @notice struct to pack calldata and targets for an emergency action
    struct Call {
        /// @notice target address to call
        address target;
        /// @notice amount of eth to send with the call
        uint256 value;
        /// @notice payload to send to target
        bytes callData;
    }

    /// @notice due to inflexibility of current smart contracts,
    /// add this ability to be able to execute arbitrary calldata
    /// against arbitrary addresses.
    /// callable only by governor
    function emergencyAction(Call[] calldata calls)
        external
        payable
        virtual
        onlyCoreRole(CoreRoles.GOVERNOR)
        returns (bytes[] memory returnData)
    {
        returnData = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            address payable target = payable(calls[i].target);
            uint256 value = calls[i].value;
            bytes calldata callData = calls[i].callData;

            (bool success, bytes memory returned) = target.call{value: value}(callData);
            require(success, UnderlyingCallReverted(returned));
            returnData[i] = returned;
        }
    }
}
