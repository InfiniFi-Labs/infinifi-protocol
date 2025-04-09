// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {Farm} from "@integrations/Farm.sol";

/// @title ERC4626 Farm
/// @notice This contract is used to deploy assets in an ERC4626 vault
contract ERC4626Farm is Farm {
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
        return super.assets() + ERC4626(vault).convertToAssets(vaultShares);
    }

    function liquidity() public view override returns (uint256) {
        return super.assets() + ERC4626(vault).maxWithdraw(address(this));
    }

    function _deposit() internal override {
        uint256 availableAssets = ERC20(assetToken).balanceOf(address(this));
        ERC20(assetToken).approve(vault, availableAssets);
        ERC4626(vault).deposit(availableAssets, address(this));
    }

    function _withdraw(uint256 _amount, address _to) internal override {
        ERC4626(vault).withdraw(_amount, _to, address(this));
    }

    function maxDeposit() external view override returns (uint256) {
        return ERC4626(vault).maxDeposit(address(this));
    }
}
