// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Farm} from "@integrations/Farm.sol";
import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";

interface IERC7575 {
    function share() external view returns (address);
}

interface IERC7540 {
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 requestId);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
}

/// @title ERC7540 Farm, similar to an ERC4626 Farm but for asynchronous vaults.
/// @dev Supports ERC7575 vaults that have an external share token.
/// @dev only one deposit and redemption request can be done in parallel, if the vault is
/// discriminating by request ID (see https://eips.ethereum.org/EIPS/eip-7540#request-ids).
contract ERC7540Farm is Farm, IMaturityFarm {
    using SafeERC20 for IERC20;

    error AssetMismatch(address _assetToken, address _vaultAsset);
    error RequestInProgress(uint256 _requestId);

    address public immutable vault;
    address public immutable share;
    uint256 public immutable duration;
    uint256 public pendingDepositRequestId;
    uint256 public pendingRedeemRequestId;

    constructor(address _core, address _assetToken, address _vault, uint256 _duration) Farm(_core, _assetToken) {
        vault = _vault;
        address vaultAsset = ERC4626(_vault).asset();
        require(vaultAsset == _assetToken, AssetMismatch(_assetToken, vaultAsset));

        try IERC7575(_vault).share() returns (address _share) {
            share = _share;
        } catch {
            share = _vault;
        }

        duration = _duration;
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + duration;
    }

    /// @notice Returns the total assets in the farm + the rebasing balance of the aToken
    function assets() public view override(Farm, IFarm) returns (uint256) {
        // assets & pending + claimable deposits
        uint256 assetTokens = liquidity();
        assetTokens += IERC7540(vault).pendingDepositRequest(pendingDepositRequestId, address(this));
        assetTokens += IERC7540(vault).claimableDepositRequest(pendingDepositRequestId, address(this));

        // vault shares & pending + claimable redemptions
        uint256 vaultShares = ERC20(share).balanceOf(address(this));
        vaultShares += IERC7540(vault).pendingRedeemRequest(pendingRedeemRequestId, address(this));
        vaultShares += IERC7540(vault).claimableRedeemRequest(pendingRedeemRequestId, address(this));

        return assetTokens + ERC4626(vault).convertToAssets(vaultShares);
    }

    // liquidity is the balance of asset token in the farm that can be directly transferred
    function liquidity() public view virtual override returns (uint256) {
        return ERC20(assetToken).balanceOf(address(this));
    }

    // noop: deposits are handled asynchronously
    function _deposit(uint256 availableAssets) internal virtual override {}

    // transfer assetTokens directly held by the farm (the liquidity())
    function _withdraw(uint256 _amount, address _to) internal virtual override {
        IERC20(assetToken).safeTransfer(_to, _amount);
    }

    // allow to receive vault share tokens from secondary asset movements
    function isAssetSupported(address _asset) public view virtual returns (bool) {
        return _asset == assetToken || _asset == share;
    }

    // allow movement of vault share tokens as a secondary asset
    function withdrawSecondaryAsset(address _asset, uint256 _amount, address _to)
        external
        onlyCoreRole(CoreRoles.FARM_MANAGER)
        whenNotPaused
    {
        require(_asset == share, AssetMismatch(_asset, share));

        uint256 assetsBefore = assets();
        IERC20(share).safeTransfer(_to, _amount);
        uint256 assetsAfter = assets();

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsAfter);
    }

    function vaultRequestDeposit(uint256 _assets)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        uint256 _pendingDepositRequestId = pendingDepositRequestId;
        require(_pendingDepositRequestId == 0, RequestInProgress(_pendingDepositRequestId));

        IERC20(assetToken).forceApprove(vault, _assets);
        uint256 requestId = IERC7540(vault).requestDeposit(_assets, address(this), address(this));
        pendingDepositRequestId = requestId;
        return requestId;
    }

    function vaultDeposit(uint256 _assets)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        /// @dev The 7540 vaults might not be fully async, and might behave like 4646 if either their
        /// deposit or redeem flow is synchronous, therefore the token approval might be needed. In case
        /// the behavior of the vault is async, this approval is not needed since assetTokens are pulled
        /// at the time of the request, and not at the time of fulfillment.
        IERC20(assetToken).forceApprove(vault, _assets);
        uint256 depositedShares = ERC4626(vault).deposit(_assets, address(this));
        IERC20(assetToken).forceApprove(vault, 0);

        pendingDepositRequestId = 0;

        return depositedShares;
    }

    function vaultRequestRedeem(uint256 _shares)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        uint256 _pendingRedeemRequestId = pendingRedeemRequestId;
        require(_pendingRedeemRequestId == 0, RequestInProgress(_pendingRedeemRequestId));

        IERC20(share).forceApprove(vault, _shares);
        uint256 requestId = IERC7540(vault).requestRedeem(_shares, address(this), address(this));
        pendingRedeemRequestId = requestId;
        return requestId;
    }

    function vaultRedeem(uint256 _shares)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        /// @dev The 7540 vaults might not be fully async, and might behave like 4646 if either their
        /// deposit or redeem flow is synchronous, therefore the token approval might be needed. In case
        /// the behavior of the vault is async, this approval is not needed since assetTokens are pulled
        /// at the time of the request, and not at the time of fulfillment.
        /// Moreover, the approval might not be needed if the share token is the vault itself, but this
        /// approval allows to support ERC7575 with only minor additional gas spent.
        IERC20(share).forceApprove(vault, _shares);
        uint256 redeemedAssets = ERC4626(vault).redeem(_shares, address(this), address(this));
        IERC20(share).forceApprove(vault, 0);

        pendingRedeemRequestId = 0;

        return redeemedAssets;
    }
}
