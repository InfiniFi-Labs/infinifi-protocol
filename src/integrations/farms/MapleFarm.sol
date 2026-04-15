// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";

import {ISyrupRouter} from "@interfaces/maple/ISyrupRouter.sol";
import {IMaplePoolLike} from "@interfaces/maple/IMaplePoolLike.sol";
import {IMaplePoolManagerLike} from "@interfaces/maple/IMaplePoolManagerLike.sol";
import {IWithdrawalManagerLike} from "@interfaces/maple/IWithdrawalManagerLike.sol";

/// @title MapleFarm
/// @notice Farm integration that deploys assetTokens into Maple pools and tracks pending redemptions.
/// @dev for syrupUSDC, authorizations are done through the router. First deposit has to be authorized
/// (vaultAuthorizeAndDeposit), follow-ups can be done with vaultDepositAuthorized. After the farm is
/// authorized, it can also request redemptions (vaultRequestRedeem).
contract MapleFarm is MultiAssetFarmV2 {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    // immutable references to external contracts
    address public immutable pool;
    address public immutable router;

    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant _DEPOSIT_DATA = bytes32(bytes("0:infinifi"));

    uint256 public immutable duration;

    constructor(
        address _core,
        address _accounting,
        address _assetToken,
        address _pool,
        address _router,
        uint256 _duration
    ) MultiAssetFarmV2(_core, _assetToken, _accounting) {
        pool = _pool;
        router = _router;
        duration = _duration;

        _enableAsset(_assetToken);
        _enableAsset(_pool);

        // tolerate at most a rounding down to the 5th decimal
        maxSlippage = 0.99999e18;
    }

    function maturity() external view returns (uint256) {
        return block.timestamp + duration;
    }

    /// @inheritdoc MultiAssetFarmV2
    /// @dev Small override because MultiAssetFarmV2.assets() includes the balance of the
    /// assetTokens & pool shares, but not the pool shares that are pending redemption.
    function assets() public view override returns (uint256) {
        address poolManager = IMaplePoolLike(pool).manager();
        address withdrawalManager = IMaplePoolManagerLike(poolManager).withdrawalManager();

        uint256 assetsPendingRedemption = 0;
        uint256 userEscrowedShares = IWithdrawalManagerLike(withdrawalManager).userEscrowedShares(address(this));
        if (userEscrowedShares != 0) {
            assetsPendingRedemption += IMaplePoolLike(pool).convertToExitAssets(userEscrowedShares);
        }
        uint256 manualSharesAvailable = IWithdrawalManagerLike(withdrawalManager).manualSharesAvailable(address(this));
        if (manualSharesAvailable != 0) {
            assetsPendingRedemption += IMaplePoolLike(pool).convertToExitAssets(manualSharesAvailable);
        }

        return super.assets() + assetsPendingRedemption;
    }

    function vaultAuthorizeAndDeposit(
        uint256 _amount,
        uint256 _bitmap,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external whenNotPaused checkSlippage onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) returns (uint256) {
        IERC20(assetToken).forceApprove(router, _amount);
        return ISyrupRouter(router).authorizeAndDeposit(_bitmap, _deadline, _v, _r, _s, _amount, _DEPOSIT_DATA);
    }

    /// @notice Deposit assets held by the farm into pool via the router.
    /// @param _amount The amount of assets to deposit.
    /// @return The number of pool shares minted to the farm.
    function vaultDepositAuthorized(uint256 _amount)
        external
        whenNotPaused
        checkSlippage
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        IERC20(assetToken).forceApprove(router, _amount);
        return ISyrupRouter(router).deposit(_amount, _DEPOSIT_DATA);
    }

    /// @notice Deposit assets held by the farm into the pool directly (without router).
    /// This requires a prior authorization from the pool manager, or the call will revert.
    /// @param _amount The amount of assets to deposit.
    /// @return The number of pool shares minted to the farm.
    function vaultDeposit(uint256 _amount)
        external
        whenNotPaused
        checkSlippage
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        IERC20(assetToken).forceApprove(pool, _amount);
        return IMaplePoolLike(pool).deposit(_amount, address(this));
    }

    /// @notice Request redemption of pool shares back to assetToken through the Maple withdrawal queue.
    /// @param _shares The amount of pool shares to request for redemption.
    /// @return The amount of shares escrowed in the withdrawal manager for processing.
    function vaultRequestRedeem(uint256 _shares)
        external
        whenNotPaused
        checkSlippage
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        return IMaplePoolLike(pool).requestRedeem(_shares, address(this));
    }

    /// @notice Redeem from a Maple pool, if manual exit mode is enabled.
    /// If the manual exit mode is not enabled, the WithdrawalManager will directly send assetTokens
    /// to the farm when redemption is processed, instead of marking the shares as available to redeem
    /// and requiring a call to this function.
    /// @param _shares The amount of pool shares to redeem.
    /// @return The amount of shares escrowed in the withdrawal manager for processing.
    function vaultRedeem(uint256 _shares)
        external
        whenNotPaused
        checkSlippage
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (uint256)
    {
        return IMaplePoolLike(pool).redeem(_shares, address(this), address(this));
    }
}
