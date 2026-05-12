pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IMaturityFarm.sol";
import {MaturityFarm, Farm} from "@integrations/MaturityFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";

import {IdleCDOEpochVariant} from "@interfaces/pareto/IdleCDOEpochVariant.sol";

/// @title IIdleCreditVault
/// @notice Interface for the Idle Credit Vault (Fasanara strategy), which is the underlying
/// borrower contract behind the IdleCDOEpochVariant. It tracks per-user withdrawal requests,
/// epoch numbers, and APR data used to compute accrued interest.
interface IIdleCreditVault {
    /// @notice Returns the current epoch number.
    function epochNumber() external view returns (uint256);

    /// @notice Returns the APR for the apr0 (zero-APR) path for a given epoch.
    /// Used to compute interest when `_settleApr0` has not yet been called on-chain.
    function apr0RateByEpoch(uint256) external view returns (uint256);

    /// @notice Returns the amount of underlyings queued for normal (epoch-locked) withdrawal by `_owner`.
    function withdrawsRequests(address _owner) external view returns (uint256);

    /// @notice Returns the amount of underlyings queued for instant withdrawal by `_owner`.
    function instantWithdrawsRequests(address _owner) external view returns (uint256);

    /// @notice Sets the APR values for the vault.
    function setAprs(uint256, uint256) external;

    /// @notice Returns the last APR recorded by the vault.
    function lastApr() external view returns (uint256);

    /// @notice Returns the apr0 (zero-APR path) accounting state for `_owner`.
    /// @return principal            Unsettled principal still pending settlement.
    /// @return principalEpoch      Epoch in which the principal was registered.
    /// @return settledPrincipal    Principal already settled and claimable.
    /// @return settledInterest     Interest already settled and claimable.
    function apr0Users(address _owner)
        external
        view
        returns (uint256 principal, uint256 principalEpoch, uint256 settledPrincipal, uint256 settledInterest);
}

/// @title ParetoFarm
/// @notice InfiniFi farm adapter for Pareto (Idle Finance) epoch-based credit vaults.
contract ParetoFarm is MaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// @notice Reverts when a zero-amount withdrawal is requested.
    /// @dev Passing 0 to `IdleCDOEpochVariant.requestWithdraw` is interpreted as "withdraw all",
    /// which would be unintentional and hard to reverse during an active epoch.
    error ZeroWithdrawalNotAllowed();

    /// @notice AA-tranche token minted by `epochVariant` in exchange for deposited assets.
    address public immutable shareToken;
    /// @notice Pareto CDO epoch wrapper — handles deposits and withdrawal requests.
    IdleCDOEpochVariant public immutable epochVariant;
    /// @notice Underlying Fasanara credit vault — tracks per-epoch APRs and withdrawal queues.
    IIdleCreditVault public immutable vault;

    /// @param _core          Address of the InfiniFi Core contract.
    /// @param _assetToken    ERC-20 token accepted by the Pareto vault (e.g. USDC).
    /// @param _epochVariant  Address of the IdleCDOEpochVariant contract.
    /// @param _vault         Address of the IIdleCreditVault (Fasanara strategy) contract.
    /// @param _duration      Maturity duration used by the parent MaturityFarm.
    constructor(address _core, address _assetToken, address _epochVariant, address _vault, uint256 _duration)
        MaturityFarm(_core, _assetToken, _duration, true)
    {
        // set default slippage tolerance to 99.5%
        maxSlippage = 0.995e18;
        vault = IIdleCreditVault(_vault);
        epochVariant = IdleCDOEpochVariant(_epochVariant);
        shareToken = IdleCDOEpochVariant(_epochVariant).AATranche();
    }

    /// @notice Returns the immediately liquid assetToken balance held by this contract.
    /// @dev Does not include shares or queued withdrawals — only raw tokens available right now.
    function liquidity() external view override returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this));
    }

    /// @notice Returns the total assets managed by this farm across all states.
    /// @dev Aggregates:
    ///   - Raw assetToken balance in this contract.
    ///   - Pending normal withdrawal requests (skipped if vault has defaulted).
    ///   - Apr0-path positions: settled amounts plus lazily computed interest for closed epochs.
    ///   - Instant withdrawal requests (only when `epochVariant.allowInstantWithdraw()` is true).
    ///   - AA-tranche share balance converted via `epochVariant.virtualPrice`.
    function assets() public view override(Farm, IFarm) returns (uint256) {
        uint256 assetTokenBalance = IERC20(assetToken).balanceOf(address(this));
        bool isDefaulted = epochVariant.defaulted();

        if (!isDefaulted) {
            assetTokenBalance += vault.withdrawsRequests(address(this));

            // apr0 path goes through claimWithdrawRequest, same epoch-lock as withdrawsRequests
            (
                uint256 apr0Principal,
                uint256 apr0PrincipalEpoch,
                uint256 apr0SettledPrincipal,
                uint256 apr0SettledInterest
            ) = vault.apr0Users(address(this));

            assetTokenBalance += apr0SettledPrincipal + apr0SettledInterest;

            if (apr0Principal > 0) {
                assetTokenBalance += apr0Principal;
                // _settleApr0 is lazy: if the request epoch has closed and the rate
                // was written by prepareStopEpochWithApr0, compute interest directly
                // rather than waiting for the next on-chain settlement trigger
                if (apr0PrincipalEpoch < vault.epochNumber()) {
                    uint256 rate = vault.apr0RateByEpoch(apr0PrincipalEpoch);
                    if (rate != 0) {
                        assetTokenBalance += apr0Principal.mulWadDown(rate);
                    }
                }
            }
        }

        // only claimable if allowInstantWithdraw is true
        if (!isDefaulted || epochVariant.allowInstantWithdraw()) {
            assetTokenBalance += vault.instantWithdrawsRequests(address(this));
        }

        uint256 shareBalance = IERC20(shareToken).balanceOf(address(this));
        if (shareBalance > 0) {
            assetTokenBalance += convertToAssets(shareBalance);
        }

        return assetTokenBalance;
    }

    /// @notice Converts AA-tranche shares to the equivalent assetToken amount using the current virtual price.
    /// @param _shares Amount of AA-tranche tokens to convert.
    /// @return Equivalent amount of assetToken.
    function convertToAssets(uint256 _shares) public view returns (uint256) {
        uint256 virtualPrice = epochVariant.virtualPrice(shareToken);
        return _shares.mulWadDown(virtualPrice);
    }

    /// @notice Deposits assetToken into the Pareto vault in exchange for AA-tranche shares.
    /// @dev Approves `epochVariant` to spend `_amount` then calls `depositAA`. Slippage is
    /// checked by the `checkSlippage` modifier after the call.
    /// @param _amount Amount of assetToken to deposit.
    function vaultDeposit(uint256 _amount)
        external
        whenNotPaused
        checkSlippage
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        IERC20(assetToken).forceApprove(address(epochVariant), _amount);
        epochVariant.depositAA(_amount);
    }

    /// @notice Request a withdrawal of tranche tokens from the Pareto vault.
    /// @param _amount Amount of tranche tokens to withdraw. NOTE: passing 0 will request
    /// a withdrawal of the farm's entire tranche token balance, as IdleCDOEpochVariant
    /// interprets zero as "withdraw all."
    function vaultRequestWithdraw(uint256 _amount)
        external
        whenNotPaused
        checkSlippage
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(_amount > 0, ZeroWithdrawalNotAllowed());
        epochVariant.requestWithdraw(_amount, shareToken);
    }

    /// @notice Claims a settled normal withdrawal request, returning assetToken to this contract.
    /// @dev Can only be called after at least one full epoch has elapsed since `vaultRequestWithdraw`.
    function completeWithdraw() external whenNotPaused checkSlippage onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        epochVariant.claimWithdrawRequest();
    }

    /// @notice Claims a settled instant withdrawal request, returning assetToken to this contract.
    /// @dev Can only be called once the epoch has started and `instantWithdrawDelay` has elapsed.
    function completeInstantWithdraw() external whenNotPaused checkSlippage onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        epochVariant.claimInstantWithdrawRequest();
    }

    /// @notice Deposits assets into the farm (used for airdrops)
    /// @dev Note that in airdrops we do not know the amount of assets before the deposit,
    /// therefore we emit an event that contains twice the assets after the deposit
    function deposit() external virtual override(Farm, IFarm) onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        uint256 currentAssets = assets();
        if (currentAssets > cap) {
            revert CapExceeded(currentAssets, cap);
        }

        _deposit(0);

        /// @dev note that in airdrops we do not know the amount of assets before the deposit,
        /// therefore we emit an event that contains twice the assets after the deposit.
        emit AssetsUpdated(block.timestamp, currentAssets, currentAssets);
    }

    function _deposit(uint256 _amount) internal override {}

    /// @notice Withdraws the reference assetToken from the farm
    /// @param amount The amount of assetToken to withdraw
    /// @param to The address to send the withdrawn tokens to
    function withdraw(uint256 amount, address to)
        external
        virtual
        override(Farm, IFarm)
        onlyCoreRole(CoreRoles.FARM_MANAGER)
        whenNotPaused
    {
        uint256 assetsBefore = assets();
        _withdraw(amount, to);

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsBefore - amount);
    }

    function _withdraw(uint256 _amount, address _to) internal virtual override {
        IERC20(assetToken).safeTransfer(_to, _amount);
    }
}
