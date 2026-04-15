// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Farm} from "@integrations/Farm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @title A contract to help claim Merkl rewards
/// This contract needs GOVERNOR role to act on behalf of protocol contracts
/// that have earned rewards.
contract MerklRewardsClaimer is CoreControlled {
    error RewardsNotEnabled(address _farm, address _rewardToken);
    error NoRewardsToClaim(address _farm);
    error InvalidRecipient(address _recipient);
    error AssetMismatch(uint256 assetsBefore, uint256 assetsAfter);

    event RecipientUpdated(uint256 indexed timestamp, address indexed recipient);
    event EnabledRewardsUpdated(
        uint256 indexed timestamp, address indexed farm, address indexed rewardToken, address rewardContract
    );
    event Claimed(uint256 indexed timestamp, address indexed farm, address indexed rewardToken, uint256 amount);

    /// @notice recipient of the rewards
    address public recipient;

    /// @notice mapping of rewards enabled for claiming
    mapping(address _farm => mapping(address _rewardToken => address _rewardContract)) public enabledRewards;

    constructor(address _core, address _recipient) CoreControlled(_core) {
        _setRecipient(_recipient);
    }

    /// @notice sets the recipient of the rewards
    function setRecipient(address _recipient) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        _setRecipient(_recipient);
    }

    function _setRecipient(address _recipient) internal {
        require(_recipient != address(0), InvalidRecipient(_recipient));
        recipient = _recipient;
        emit RecipientUpdated(block.timestamp, _recipient);
    }

    function setEnabledRewards(address _farm, address _rewardToken, address _rewardContract)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        enabledRewards[_farm][_rewardToken] = _rewardContract;
        emit EnabledRewardsUpdated(block.timestamp, _farm, _rewardToken, _rewardContract);
    }

    /// @notice claims rewards for a protocol contract on Merkl
    function claimRewards(address _farm, address _rewardToken, uint256 _amount, bytes32[] calldata _proof)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        address rewardContract = enabledRewards[_farm][_rewardToken];
        require(rewardContract != address(0), RewardsNotEnabled(_farm, _rewardToken));

        uint256 assetsBefore = Farm(_farm).assets();

        {
            CoreControlled.Call[] memory claimCalls = new CoreControlled.Call[](1);
            address[] memory users = new address[](1);
            users[0] = _farm;
            address[] memory tokens = new address[](1);
            tokens[0] = _rewardToken;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = _amount;
            bytes32[][] memory proofs = new bytes32[][](1);
            proofs[0] = _proof;
            claimCalls[0] = CoreControlled.Call({
                target: rewardContract,
                value: 0,
                callData: abi.encodeWithSignature(
                    "claim(address[],address[],uint256[],bytes32[][])", users, tokens, amounts, proofs
                )
            });
            CoreControlled(_farm).emergencyAction(claimCalls);
        }

        uint256 rewardTokenBalance = IERC20(_rewardToken).balanceOf(_farm);
        require(rewardTokenBalance > 0, NoRewardsToClaim(_farm));

        {
            CoreControlled.Call[] memory transferCalls = new CoreControlled.Call[](1);
            transferCalls[0] = CoreControlled.Call({
                target: _rewardToken,
                value: 0,
                callData: abi.encodeWithSignature("transfer(address,uint256)", recipient, rewardTokenBalance)
            });
            CoreControlled(_farm).emergencyAction(transferCalls);
        }

        // ensure the rewards claiming did not affect the farm's assets, as could be the case from a configuration
        // error where the reward token is the farm's asset token, a supported secondary asset, or a receipt token
        // from the farm's deposit.
        uint256 assetsAfter = Farm(_farm).assets();
        require(assetsAfter == assetsBefore, AssetMismatch(assetsBefore, assetsAfter));

        emit Claimed(block.timestamp, _farm, _rewardToken, rewardTokenBalance);
    }
}
