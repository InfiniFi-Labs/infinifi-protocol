// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @title A contract to help claim Fluid rewards
/// This contract needs GOVERNOR role to act on behalf of protocol contracts
/// that have earned Fluid rewards.
contract FluidRewardsClaimer is CoreControlled {
    error InvalidFarm(address _farm);
    error NoRewardsToClaim(address _farm);
    error InvalidRecipient(address _recipient);

    event RecipientUpdated(uint256 indexed timestamp, address indexed recipient);
    event Claimed(uint256 indexed timestamp, address indexed farm, uint256 amount);

    /// @notice reference to the farm registry contract
    address public immutable farmRegistry;

    /// @notice recipient of the Fluid rewards
    address public recipient;

    /// @notice fluid rewards claimer contract
    address public constant FLUID_REWARDS_CONTRACT = 0x7060FE0Dd3E31be01EFAc6B28C8D38018fD163B0;
    /// @notice fluid reward token
    address public constant FLUID_REWARD_TOKEN = 0x6f40d4A6237C257fff2dB00FA0510DeEECd303eb;

    constructor(address _core, address _farmRegistry, address _recipient) CoreControlled(_core) {
        farmRegistry = _farmRegistry;
        _setRecipient(_recipient);
    }

    /// @notice sets the recipient of the Fluid rewards
    function setRecipient(address _recipient) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        _setRecipient(_recipient);
    }

    function _setRecipient(address _recipient) internal {
        require(_recipient != address(0), InvalidRecipient(_recipient));
        recipient = _recipient;
        emit RecipientUpdated(block.timestamp, _recipient);
    }

    /// @notice claims the Fluid rewards for the recipient
    /// @dev note that this call is unprotected, anyone can make the farm claim its rewards.
    function claimFluidRewards(
        address _farm,
        uint256 _cumulativeAmount,
        uint8 _positionType,
        bytes32 _positionId,
        uint256 _cycle,
        bytes32[] calldata _merkleProof,
        bytes memory _metadata
    ) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        require(FarmRegistry(farmRegistry).isFarm(_farm), InvalidFarm(_farm));

        CoreControlled.Call[] memory claimCalls = new CoreControlled.Call[](1);
        claimCalls[0] = CoreControlled.Call({
            target: FLUID_REWARDS_CONTRACT,
            value: 0,
            callData: abi.encodeWithSignature(
                "claim(address,uint256,uint8,bytes32,uint256,bytes32[],bytes)",
                _farm,
                _cumulativeAmount,
                _positionType,
                _positionId,
                _cycle,
                _merkleProof,
                _metadata
            )
        });
        CoreControlled(_farm).emergencyAction(claimCalls);

        uint256 rewardTokenBalance = IERC20(FLUID_REWARD_TOKEN).balanceOf(_farm);
        require(rewardTokenBalance > 0, NoRewardsToClaim(_farm));

        CoreControlled.Call[] memory transferCalls = new CoreControlled.Call[](1);
        transferCalls[0] = CoreControlled.Call({
            target: FLUID_REWARD_TOKEN,
            value: 0,
            callData: abi.encodeWithSignature("transfer(address,uint256)", recipient, rewardTokenBalance)
        });
        CoreControlled(_farm).emergencyAction(transferCalls);

        emit Claimed(block.timestamp, _farm, rewardTokenBalance);
    }
}
