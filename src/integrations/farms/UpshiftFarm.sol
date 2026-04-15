// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IUpshiftVault} from "@interfaces/upshift/IUpshiftVault.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";
import {IFarm, IMaturityFarm} from "@interfaces/IMaturityFarm.sol";

contract UpshiftFarm is MultiAssetFarmV2, IMaturityFarm {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Emitted when assets are deposited into the vault
    /// @param timestamp The block timestamp when the deposit occurred
    /// @param assets The amount of assets deposited
    /// @param shares The amount of shares received
    event VaultDeposit(uint256 indexed timestamp, uint256 assets, uint256 shares);

    /// @notice Emitted when a redemption request is made to the vault
    /// @param timestamp The block timestamp when the request was made
    /// @param shares The amount of shares to redeem
    /// @param assetsOut The amount of assets expected to be received
    /// @param year The year component of the claimable date
    /// @param month The month component of the claimable date
    /// @param day The day component of the claimable date
    event VaultRequestRedeem(
        uint256 indexed timestamp, uint256 shares, uint256 assetsOut, uint256 year, uint256 month, uint256 day
    );

    /// @notice Emitted when an instant redemption is made to the vault
    /// @param timestamp The block timestamp when the redemption occurred
    /// @param shares The amount of shares redeemed
    event VaultInstantRedeem(uint256 indexed timestamp, uint256 shares);

    /// @notice Emitted when assets are claimed from the vault
    /// @param timestamp The block timestamp when the claim occurred
    /// @param year The year component of the claimed date
    /// @param month The month component of the claimed date
    /// @param day The day component of the claimed date
    /// @param shares The amount of shares burned
    /// @param assets The amount of assets received
    event VaultClaim(
        uint256 indexed timestamp, uint256 year, uint256 month, uint256 day, uint256 shares, uint256 assets
    );

    error TimestampMismatch(uint256 _expected, uint256 _actual);
    error AssetsIntegrityBroken(uint256 _expected, uint256 _received);

    /// @notice The address of the Upshift vault
    address public immutable vault;

    /// @notice Set of pending claim dates encoded as bytes32
    EnumerableSet.Bytes32Set private pendingClaimsKeys;

    /// @notice Constructor for UpshiftFarm
    /// @param _core The address of the core contract
    /// @param _vault The address of the Upshift vault
    /// @param _accounting The address of the accounting contract
    constructor(address _core, address _vault, address _accounting)
        MultiAssetFarmV2(_core, ERC4626(_vault).asset(), _accounting)
    {
        require(_hasOracle(assetToken), InvalidAsset(assetToken));
        // set default slippage tolerance to 99.5%
        maxSlippage = 0.995e18;
        vault = _vault;
    }

    /// @notice maturity of this farm can be a bit further in the future
    ///         depending on the lag duration given by the vault
    /// @dev Adding 1 week buffer just to make it at least 1 week duration asset
    function maturity() public view returns (uint256) {
        return block.timestamp + 1 weeks + IUpshiftVault(vault).lagDuration();
    }

    /// @notice Returns the total value of all assets held by the farm
    /// @dev Includes vault shares converted to assets and pending claims
    /// @return The total assets in terms of the underlying asset token
    function assets() public view override(IFarm, MultiAssetFarmV2) returns (uint256) {
        uint256 vaultShares = IERC20(vault).balanceOf(address(this));
        uint256 currentAssets = ERC4626(vault).convertToAssets(vaultShares) + super.assets();

        uint256 pendingClaimsKeysLength = pendingClaimsKeys.length();
        for (uint256 i = 0; i < pendingClaimsKeysLength; i++) {
            (uint256 year, uint256 month, uint256 day) = decodeISODate(pendingClaimsKeys.at(i));
            currentAssets += IUpshiftVault(vault).getClaimableAmountByReceiver(year, month, day, address(this));
        }
        return currentAssets;
    }

    /// @notice Returns all pending claim keys
    /// @return An array of encoded ISO dates
    function pendingClaims() external view returns (bytes32[] memory) {
        return pendingClaimsKeys.values();
    }

    /// @notice Encodes a year, month, and day into a bytes32 ISO date format
    /// @param _year The year
    /// @param _month The month
    /// @param _day The day
    /// @return The encoded ISO date
    function encodeISODate(uint256 _year, uint256 _month, uint256 _day) public pure returns (bytes32) {
        return bytes32((_year << 16) | (_month << 8) | _day);
    }

    /// @notice Decodes a bytes32 ISO date format into year, month, and day
    /// @param _encoded The encoded ISO date
    /// @return year The year
    /// @return month The month
    /// @return day The day
    function decodeISODate(bytes32 _encoded) public pure returns (uint256, uint256, uint256) {
        uint256 x = uint256(_encoded);
        return (uint256(uint16(x >> 16)), uint256(uint8(x >> 8)), uint256(uint8(x)));
    }

    /// @notice Deposits assets into the Upshift vault
    /// @param _assets The amount of assets to deposit
    function vaultDeposit(uint256 _assets)
        external
        checkSlippage
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        IERC20(assetToken).forceApprove(address(vault), _assets);
        uint256 shares = ERC4626(vault).deposit(_assets, address(this));

        emit VaultDeposit(block.timestamp, _assets, shares);
    }

    /// @notice Requests to redeem shares from the Upshift vault
    /// @dev Request is instant when `lagDuration` is set to 0.
    ///      In case it isn't, the request will be enqueued.
    ///      There is option to use instantRedeem but it charges a fee.
    /// @param _shares The amount of shares to redeem
    function vaultRequestRedeem(uint256 _shares)
        external
        checkSlippage
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        (uint256 _year, uint256 _month, uint256 _day, uint256 expectedClaimTimestamp) =
            IUpshiftVault(vault).getWithdrawalEpoch();

        uint256 claimableAssetsBefore =
            IUpshiftVault(vault).getClaimableAmountByReceiver(_year, _month, _day, address(this));

        (uint256 assetsOut, uint256 claimTimestamp) =
            IUpshiftVault(vault).requestRedeem(_shares, address(this), address(this));

        if (IUpshiftVault(vault).lagDuration() > 0) {
            // Should never happen but in case there is a discrepancy good to guard us.
            require(expectedClaimTimestamp == claimTimestamp, TimestampMismatch(expectedClaimTimestamp, claimTimestamp));

            uint256 claimableAssets = IUpshiftVault(vault)
                .getClaimableAmountByReceiver(_year, _month, _day, address(this)) - claimableAssetsBefore;

            pendingClaimsKeys.add(encodeISODate(_year, _month, _day));
            require(claimableAssets == assetsOut, AssetsIntegrityBroken(assetsOut, claimableAssets));
        }

        emit VaultRequestRedeem(block.timestamp, _shares, assetsOut, _year, _month, _day);
    }

    /// @notice Performs an instant redemption of shares from the Upshift vault
    /// @dev Instant redemption charges a fee for instant liquidity.
    /// @param _shares The amount of shares to redeem
    function vaultInstantRedeem(uint256 _shares)
        external
        checkSlippage
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        IUpshiftVault(vault).instantRedeem(_shares, address(this), address(this));

        emit VaultInstantRedeem(block.timestamp, _shares);
    }

    /// @notice Claims assets from the Upshift vault for a specific date
    /// @param _year The year component of the claim date
    /// @param _month The month component of the claim date
    /// @param _day The day component of the claim date
    function vaultClaim(uint256 _year, uint256 _month, uint256 _day)
        external
        checkSlippage
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        (uint256 shares, uint256 assetsClaimed) = IUpshiftVault(vault).claim(_year, _month, _day, address(this));
        pruneKeys();

        emit VaultClaim(block.timestamp, _year, _month, _day, shares, assetsClaimed);
    }

    /// @notice Prunes the pending claims keys that no longer have claimable amounts
    function pruneKeys() public {
        for (uint256 i = 0; i < pendingClaimsKeys.length();) {
            bytes32 encoded = pendingClaimsKeys.at(i);
            (uint256 year, uint256 month, uint256 day) = decodeISODate(encoded);
            uint256 amount = IUpshiftVault(vault).getClaimableAmountByReceiver(year, month, day, address(this));

            if (amount > 0) ++i;
            else pendingClaimsKeys.remove(encoded);
        }
    }
}
