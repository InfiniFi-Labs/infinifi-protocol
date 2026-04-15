// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Farm} from "@integrations/Farm.sol";

interface IAutoVault {
    // non-standard non-view functions
    // see https://docs.auto.finance/developer-docs/integrating/4626-compliance#view-functions-as-non-payable
    function maxWithdraw(address account) external returns (uint256 assets);
    function previewWithdraw(uint256 assets) external returns (uint256 shares);
}

/// @title AutoFarm
/// @notice This contract is used to deploy assets in an ERC4626 vault
contract AutoFarm is Farm {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when the farm asset token and the vault asset do not match
    error AssetMismatch(address _assetToken, address _vaultAsset);

    address public immutable vault;
    uint256 public immutable duration;

    constructor(address _core, address _assetToken, address _vault, uint256 _duration) Farm(_core, _assetToken) {
        vault = _vault;
        require(ERC4626(vault).asset() == _assetToken, AssetMismatch(_assetToken, ERC4626(vault).asset()));
        duration = _duration;

        // This Farm can have slippage on deposits and withdrawals
        // Link: https://docs.auto.finance/developer-docs/integrating/4626-compliance#slippage
        /// @dev Default slippage tolerance: 0.1% (10bps)
        maxSlippage = 0.999e18;
    }

    function assets() public view override returns (uint256) {
        uint256 vaultShares = IERC20(vault).balanceOf(address(this));
        return ERC4626(vault).convertToAssets(vaultShares);
    }

    function liquidity() public view virtual override returns (uint256) {
        return 0;
    }

    function previewLiquidity() public returns (uint256) {
        return IAutoVault(vault).maxWithdraw(address(this));
    }

    function _deposit(uint256 availableAssets) internal virtual override {
        IERC20(assetToken).forceApprove(vault, availableAssets);
        ERC4626(vault).deposit(availableAssets, address(this));
    }

    /// @dev We are not using regular withdraw because the Auto's redeem has significant less slippage than normal withdraw
    /// @dev https://docs.auto.finance/developer-docs/integrating/4626-compliance#future-functionality-of-mint--withdraw
    function _withdraw(uint256 _amount, address _to) internal virtual override {
        /// @dev this might result in small leftover assetTokens sitting on the farm
        /// due to rounding errors, but it is a hard requirement that exactly _amount of assets() is transferred to _to.
        /// and that the function reverts if >= _amount cannot be withdrawn from the vault.
        uint256 share = IAutoVault(vault).previewWithdraw(_amount);
        ERC4626(vault).redeem(share, address(this), address(this));
        IERC20(assetToken).safeTransfer(_to, _amount);
    }

    function maturity() public view returns (uint256) {
        return block.timestamp + duration;
    }
}
