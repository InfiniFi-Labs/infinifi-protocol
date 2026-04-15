// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ERC7540Farm} from "@integrations/farms/ERC7540Farm.sol";

interface IHopperVault {
    function syncDeposit(uint256 assets, address receiver, address referral) external returns (uint256 shares);
}

/// @title Hopper Vault Farm (team@hopperlabs.xyz)
/// @notice Similar to an ERC7540 but with custom synchronous deposit flow.
/// This farm can be used to deposit in vaults such as pFxSave (plasma fxSave) that is operated by 9Summits.
contract HopperVaultFarm is ERC7540Farm {
    using SafeERC20 for IERC20;

    constructor(address _core, address _assetToken, address _vault, uint256 _duration)
        ERC7540Farm(_core, _assetToken, _vault, _duration)
    {}

    function vaultSyncDeposit(uint256 _assets) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IERC20(assetToken).forceApprove(vault, _assets);
        IHopperVault(vault).syncDeposit(_assets, address(this), address(this));
        IERC20(assetToken).forceApprove(vault, 0);
    }
}
