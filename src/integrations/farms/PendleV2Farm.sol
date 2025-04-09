// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {IOracle} from "@interfaces/IOracle.sol";
import {ISYToken} from "@interfaces/pendle/ISYToken.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IPendleMarket} from "@interfaces/pendle/IPendleMarket.sol";
import {IPendleOracle} from "@interfaces/pendle/IPendleOracle.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title Pendle V2 Farm
/// @notice This contract is used to deploy assets to Pendle v2

contract PendleV2Farm is Farm, IMaturityFarm {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    error PTAlreadyMatured(uint256 maturity);
    error PTNotMatured(uint256 maturity);
    error SwapFailed(bytes reason);
    error SlippageTooHigh(uint256 min, uint256 received);

    /// @notice Maturity of the Pendle market.
    uint256 public immutable maturity;

    /// @notice Reference to the Pendle market.
    address public immutable pendleMarket;

    /// @notice Reference to the Pendle oracle (for PT <-> underlying exchange rates).
    address public immutable pendleOracle;
    uint32 private constant _PENDLE_ORACLE_TWAP_DURATION = 3600;

    /// @notice Reference to the Principal Token of the Pendle market.
    address public immutable ptToken;

    /// @notice Reference to the SY token of the Pendle market
    address public immutable syToken;

    /// @notice Reference to the oracle for converting value of ptTokens to assetTokens.
    /// @dev e.g. for ptToken = PT-sUSDE-29MAY2025 and assetToken = USDC,
    /// this oracle returns the exchange rate of USDE (the underlying token) to USDC.
    /// Since USDE has 18 decimals and USDC has 6, and the exchange rate is ~1:1,
    /// the oracle should return a value ~= 1e6
    address public immutable assetToPtUnderlyingOracle;

    /// @notice Max slippage for wrapping and unwrapping assets <-> PTs.
    /// @dev Stored as a percentage with 18 decimals of precision, of the minimum
    /// position size compared to the previous position size (so actually 1 - maxSlippage).
    uint256 private constant _MAX_SLIPPAGE = 0.995e18; // 99.5%

    /// @notice Number of assets() wrapped as PTs
    uint256 private totalWrappedAssets;
    /// @notice Number of assets() unwrapped from PTs
    uint256 private totalUnwrappedAssets;
    /// @notice Number of PTs received from wrapping assets()
    uint256 private totalReceivedPTs;
    /// @notice Number of PTs unwrapped to assets()
    uint256 private totalRedeemedPTs;

    /// @notice Total yield already interpolated
    /// @dev this should be updated everytime we deposit and wrap assets
    uint256 private _alreadyInterpolatedYield;

    /// @notice Timestamp of the last wrapping
    uint256 private _lastWrappedTimestamp;

    constructor(
        address _core,
        address _assetToken,
        address _pendleMarket,
        address _pendleOracle,
        address _assetToPtUnderlyingOracle
    ) Farm(_core, _assetToken) {
        pendleMarket = _pendleMarket;
        pendleOracle = _pendleOracle;
        assetToPtUnderlyingOracle = _assetToPtUnderlyingOracle;

        // read contracts and keep some immutable variables to save gas
        (syToken, ptToken,) = IPendleMarket(_pendleMarket).readTokens();
        maturity = IPendleMarket(_pendleMarket).expiry();
    }

    /// @notice Returns the total assets in the farm
    /// before maturity, the assets are the sum of assets in the farm + assets wrapped + the interpolated yield
    /// after maturity, the assets are the sum of the assets() + the value of the PTs based on oracle prices
    function assets() public view override(Farm, IFarm) returns (uint256) {
        if (block.timestamp < maturity) {
            // before maturity, interpolate yield
            return super.assets() + totalWrappedAssets + _interpolatingYield();
        } else {
            // after maturity, return the total USDC held in the farm +
            // the PTs value if any are still held
            uint256 balanceOfPTs = ERC20(ptToken).balanceOf(address(this));
            uint256 ptAssetsValue = 0;
            if (balanceOfPTs > 0) {
                // estimate the value of the PTs at maturity,
                // accounting for possible max slippage
                ptAssetsValue = _ptToAssets(balanceOfPTs).mulWadDown(_MAX_SLIPPAGE);
            }
            return super.assets() + ptAssetsValue;
        }
    }

    /// @notice Current liquidity of the farm is the held assetTokens
    function liquidity() public view override returns (uint256) {
        return super.assets();
    }

    /// @notice Wraps assetTokens as PTs.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    /// @dev The caller is trusted to not be sandwiching the swap to steal yield.
    function wrapAssetToPt(uint256 _assetsIn, address _router, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(block.timestamp < maturity, PTAlreadyMatured(maturity));
        // update the already interpolated yield on each wrap
        _alreadyInterpolatedYield = _interpolatingYield();
        uint256 ptBalanceBefore = ERC20(ptToken).balanceOf(address(this));

        // do swap
        ERC20(assetToken).approve(_router, _assetsIn);
        (bool success, bytes memory reason) = _router.call(_calldata);
        require(success, SwapFailed(reason));

        // check slippage
        uint256 ptBalanceAfter = ERC20(ptToken).balanceOf(address(this));
        uint256 ptReceived = ptBalanceAfter - ptBalanceBefore;
        uint256 minAssetsOut = _assetsIn.mulWadDown(_MAX_SLIPPAGE);
        require(_ptToAssets(ptReceived) > minAssetsOut, SlippageTooHigh(minAssetsOut, _ptToAssets(ptReceived)));

        // update wrapped assets
        totalWrappedAssets += _assetsIn;
        totalReceivedPTs += ptReceived;
        _lastWrappedTimestamp = block.timestamp;
    }

    /// @notice Unwraps PTs to assetTokens.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    function unwrapPtToAsset(uint256 _ptTokensIn, address _router, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(block.timestamp >= maturity, PTNotMatured(maturity));
        uint256 assetsBefore = ERC20(assetToken).balanceOf(address(this));

        // do swap
        ERC20(ptToken).approve(_router, _ptTokensIn);
        (bool success, bytes memory reason) = _router.call(_calldata);
        require(success, SwapFailed(reason));

        // check slippage
        uint256 assetsAfter = ERC20(assetToken).balanceOf(address(this));
        uint256 assetsReceived = assetsAfter - assetsBefore;
        uint256 minAssetsOut = _ptToAssets(_ptTokensIn).mulWadDown(_MAX_SLIPPAGE);
        require(assetsReceived > minAssetsOut, SlippageTooHigh(minAssetsOut, assetsReceived));

        // update unwrapped assets
        totalUnwrappedAssets += assetsReceived;
        totalRedeemedPTs += _ptTokensIn;
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm.
    /// @dev See call to wrapAssetToPt() for the actual swap into Pendle PTs.
    function _deposit() internal view override {
        // prevent deposits to this farm after maturity is reached
        require(block.timestamp < maturity, PTAlreadyMatured(maturity));
    }

    /// @dev Return the max deposit amount for the underlying protocol
    function _underlyingProtocolMaxDeposit() internal view override returns (uint256) {
        // Get the cap for SY token
        uint256 syDepositCap = ISYToken(syToken).getAbsoluteSupplyCap() - ISYToken(syToken).getAbsoluteTotalSupply();

        // Convert the cap to PT token
        uint256 ptDepositCap = syDepositCap.divWadDown(
            IPendleOracle(pendleOracle).getPtToSyRate(pendleMarket, _PENDLE_ORACLE_TWAP_DURATION)
        );

        // Return the max deposit amount after converting PT to asset tokens
        return _ptToAssets(ptDepositCap);
    }

    /// @dev Withdrawal can only handle the held assetTokens (i.e. the liquidity()).
    /// @dev See call to unwrapPtToAsset() for the actual swap out of Pendle PTs.
    function _withdraw(uint256 _amount, address _to) internal override {
        ERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice Converts a number of PTs to assetTokens based on oracle rates.
    function _ptToAssets(uint256 _ptAmount) internal view returns (uint256) {
        // read oracles
        uint256 ptToUnderlyingRate =
            IPendleOracle(pendleOracle).getPtToAssetRate(pendleMarket, _PENDLE_ORACLE_TWAP_DURATION);
        uint256 assetToPtUnderlyingRate = IOracle(assetToPtUnderlyingOracle).price();
        // convert
        uint256 ptUnderlying = _ptAmount.mulWadDown(ptToUnderlyingRate);
        return ptUnderlying.mulWadDown(assetToPtUnderlyingRate);
    }

    /// @notice Computes the yield to interpolate from the last deposit to maturity.
    /// @dev this function is and should only be called before maturity
    function _interpolatingYield() internal view returns (uint256) {
        // if no wrapping has been made yet, no yield to interpolate
        if (_lastWrappedTimestamp == 0) return 0;
        uint256 balanceOfPTs = ERC20(ptToken).balanceOf(address(this));
        // if not PTs held, no need to interpolate
        if (balanceOfPTs == 0) return 0;

        // we want to interpolate the yield from the current time to maturity
        // to do that, we first need to compute how much USDC we should be able to get once maturity is reached
        // at maturity, 1 PT is worth 1 underlying PT asset (e.g. USDE)
        // so we can compute the amount of assets (eg USDC) we should get at maturity by using the assetToPtUnderlyingOracle
        // in this example, assetToPtUnderlyingOracle gives the price of USDE in USDC. probably close to 1:1
        uint256 assetToPtUnderlyingRate = IOracle(assetToPtUnderlyingOracle).price();
        uint256 maturityAssetAmount = balanceOfPTs.mulWadDown(assetToPtUnderlyingRate);
        // account for slippage, because unwrapping PTs => assets will cause some slippage using pendle's AMM
        maturityAssetAmount = maturityAssetAmount.mulWadDown(_MAX_SLIPPAGE);

        // compute the yield to interpolate, which is the target amount (maturityAssetAmount) minus the amount of assets wrapped
        // minus the already interpolated yield (can be != 0 if we made multiple wraps)
        uint256 totalYieldRemainingToInterpolate = maturityAssetAmount - totalWrappedAssets - _alreadyInterpolatedYield;

        // cannot underflow because _lastWrappedTimestamp cannot be after maturity as we cannot wrap after maturity
        // and _lastWrappedTimestamp is always > 0 otherwise the first line of this function would have returned 0
        uint256 yieldPerSecond = totalYieldRemainingToInterpolate / (maturity - _lastWrappedTimestamp);
        uint256 secondsSinceLastWrap = block.timestamp - _lastWrappedTimestamp;
        uint256 interpolatedYield = yieldPerSecond * secondsSinceLastWrap;
        return _alreadyInterpolatedYield + interpolatedYield;
    }
}
