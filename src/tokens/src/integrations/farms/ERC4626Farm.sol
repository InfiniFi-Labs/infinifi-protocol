// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Farm} from "@integrations/Farm.sol";

/// @title ERC4626 Farm
/// @notice This contract is used to deploy assets in an ERC4626 vault
contract ERC4626Farm is Farm {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when the farm asset token and the vault asset do not match
    error AssetMismatch(address _assetToken, address _vaultAsset);

    address public immutable vault;

    constructor(address _core, address _assetToken, address _vault) Farm(_core, _assetToken) {
        vault = _vault;
        require(ERC4626(vault).asset() == _assetToken, AssetMismatch(_assetToken, ERC4626(vault).asset()));
    }

    /// @notice Returns the total assets in the farm + the rebasing balance of the aToken
    function assets() public view override returns (uint256) {
        uint256 vaultShares = ERC20(vault).balanceOf(address(this));
        return ERC4626(vault).convertToAssets(vaultShares);
    }

    function liquidity() public view virtual override returns (uint256) {
        return ERC4626(vault).maxWithdraw(address(this));
    }

    function _deposit(uint256 availableAssets) internal virtual override {
        IERC20(assetToken).forceApprove(vault, availableAssets);
        ERC4626(vault).deposit(availableAssets, address(this));
    }

    function _withdraw(uint256 _amount, address _to) internal virtual override {
        ERC4626(vault).withdraw(_amount, _to, address(this));
    }
}
