// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";
import {IMidasRedeemVault} from "@interfaces/midas/IMidasRedeemVault.sol";
import {IMidasDepositVault} from "@interfaces/midas/IMidasDepositVault.sol";
import {IMidasManageableVault} from "@interfaces/midas/IMidasManageableVault.sol";

/// @title MidasFarm
/// @notice Farm integration that deploys assetTokens into Midas vaults.
/// @dev Supports both instant and request-based deposits and redemptions.
contract MidasFarm is MultiAssetFarmV2, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// @notice Thrown when a deposit or redeem request is already in progress
    /// @param requestId The ID of the request that is still pending
    error RequestInProgress(uint256 requestId);

    /// @notice Thrown when a provided slippage is below the configured maxSlippage
    error InvalidSlippage(uint256 provided, uint256 minimum);

    // immutable references to Midas contracts
    address public immutable mToken;
    address public immutable depositVault;
    address public immutable redeemVault;
    uint256 public immutable decimalsScalingFactor;

    /// @notice Duration of the farm (in seconds) to compute maturity
    uint256 public immutable duration;

    // Last pending request IDs (0 means no pending request, and != 0 requests might not be pending anymore)
    uint256 public pendingDepositRequestId;
    uint256 public pendingRedeemRequestId;

    // referrer ID of the farm for deposits
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant _REFERER_ID = bytes32(bytes("infinifi"));

    constructor(
        address _core,
        address _accounting,
        address _assetToken,
        address _mToken,
        address _depositVault,
        address _redeemVault,
        uint256 _duration
    ) MultiAssetFarmV2(_core, _assetToken, _accounting) {
        mToken = _mToken;
        depositVault = _depositVault;
        redeemVault = _redeemVault;
        duration = _duration;

        // midas vault use 18 decimals always, so if assetToken has less than 18 decimals, we need scaling
        decimalsScalingFactor = 10 ** (18 - ERC20(_assetToken).decimals());

        _enableAsset(_assetToken);
        _enableAsset(_mToken);

        // tolerate at most 0.001% slippage by default
        maxSlippage = 0.99999e18;
    }

    /// @inheritdoc IMaturityFarm
    function maturity() external view override returns (uint256) {
        return block.timestamp + duration;
    }

    /// @inheritdoc MultiAssetFarmV2
    /// @dev Override to include pending deposit and redeem requests in the total assets.
    function assets() public view override(MultiAssetFarmV2, IFarm) returns (uint256) {
        uint256 totalAssets = super.assets();

        // add pending deposit request amount if still pending
        uint256 _pendingDepositRequestId = pendingDepositRequestId;
        if (_pendingDepositRequestId != 0) {
            IMidasManageableVault.DepositRequest memory depositRequest =
                IMidasDepositVault(depositVault).mintRequests(_pendingDepositRequestId);
            if (depositRequest.status == IMidasManageableVault.RequestStatus.Pending) {
                // use amount after fees since that's what will be converted to mTokens
                totalAssets += depositRequest.usdAmountWithoutFees / decimalsScalingFactor;
            }
        }

        // add pending redeem request amount if still pending
        uint256 _pendingRedeemRequestId = pendingRedeemRequestId;
        if (_pendingRedeemRequestId != 0) {
            IMidasManageableVault.RedeemRequest memory redeemRequest =
                IMidasRedeemVault(redeemVault).redeemRequests(_pendingRedeemRequestId);
            if (redeemRequest.status == IMidasManageableVault.RequestStatus.Pending) {
                // redeem amount is in mToken
                totalAssets += convert(mToken, assetToken, redeemRequest.amountMToken);
            }
        }

        return totalAssets;
    }

    /// @notice Deposit assets instantly into the Midas deposit vault.
    /// @param _amount The amount of assetTokens to deposit.
    function vaultDepositInstant(uint256 _amount, uint256 _maxSlippage)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(_maxSlippage >= maxSlippage, InvalidSlippage(_maxSlippage, maxSlippage));

        uint256 minReceiveAmount = convert(assetToken, mToken, _amount).mulWadDown(_maxSlippage);

        IERC20(assetToken).forceApprove(depositVault, _amount);
        IMidasDepositVault(depositVault)
            .depositInstant(assetToken, _amount * decimalsScalingFactor, minReceiveAmount, _REFERER_ID);
    }

    /// @notice Request a deposit into the Midas deposit vault.
    /// @param _amount The amount of assetTokens to deposit.
    /// @return id The request ID for the deposit.
    function vaultDepositRequest(uint256 _amount, uint256 _maxSlippage)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256 id)
    {
        require(_maxSlippage >= maxSlippage, InvalidSlippage(_maxSlippage, maxSlippage));

        // prevent new request if there's already a pending one
        uint256 _pendingDepositRequestId = pendingDepositRequestId;
        if (_pendingDepositRequestId != 0) {
            IMidasManageableVault.DepositRequest memory request =
                IMidasDepositVault(depositVault).mintRequests(_pendingDepositRequestId);
            require(
                request.status != IMidasManageableVault.RequestStatus.Pending,
                RequestInProgress(_pendingDepositRequestId)
            );
        }

        IERC20(assetToken).forceApprove(depositVault, _amount);
        id = IMidasDepositVault(depositVault).depositRequest(assetToken, _amount * decimalsScalingFactor, _REFERER_ID);
        pendingDepositRequestId = id;

        uint256 assetsOut =
            IMidasDepositVault(depositVault).mintRequests(id).usdAmountWithoutFees / decimalsScalingFactor;
        uint256 minAssetsOut = _amount.mulWadDown(_maxSlippage);
        require(assetsOut >= minAssetsOut, SlippageTooHigh(minAssetsOut, assetsOut));
    }

    /// @notice Redeem mTokens instantly from the Midas redeem vault.
    /// @param _amount The amount of mTokens to redeem.
    function vaultRedeemInstant(uint256 _amount, uint256 _maxSlippage)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(_maxSlippage >= maxSlippage, InvalidSlippage(_maxSlippage, maxSlippage));

        // @dev note that we scale by decimalsScalingFactor here because Midas represents amounts in 18 decimals
        // internally to do the slippage check, regardless of the assetToken's decimals.
        uint256 minReceiveAmount = convert(mToken, assetToken, _amount).mulWadDown(_maxSlippage) * decimalsScalingFactor;

        IERC20(mToken).forceApprove(redeemVault, _amount);
        IMidasRedeemVault(redeemVault).redeemInstant(assetToken, _amount, minReceiveAmount);
    }

    /// @notice Request a redemption from the Midas redeem vault.
    /// @param _amount The amount of mTokens to redeem.
    /// @return id The request ID for the redemption.
    function vaultRedeemRequest(uint256 _amount, uint256 _maxSlippage)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256 id)
    {
        require(_maxSlippage >= maxSlippage, InvalidSlippage(_maxSlippage, maxSlippage));

        // prevent new request if there's already a pending one
        uint256 _pendingRedeemRequestId = pendingRedeemRequestId;
        if (_pendingRedeemRequestId != 0) {
            IMidasManageableVault.RedeemRequest memory request =
                IMidasRedeemVault(redeemVault).redeemRequests(_pendingRedeemRequestId);
            require(
                request.status != IMidasManageableVault.RequestStatus.Pending,
                RequestInProgress(_pendingRedeemRequestId)
            );
        }

        IERC20(mToken).forceApprove(redeemVault, _amount);
        id = IMidasRedeemVault(redeemVault).redeemRequest(assetToken, _amount);
        pendingRedeemRequestId = id;

        uint256 assetsOut = convert(mToken, assetToken, IMidasRedeemVault(redeemVault).redeemRequests(id).amountMToken);
        uint256 minAssetsOut = convert(mToken, assetToken, _amount).mulWadDown(_maxSlippage);
        require(assetsOut >= minAssetsOut, SlippageTooHigh(minAssetsOut, assetsOut));
    }
}

