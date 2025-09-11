// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IOracle} from "@interfaces/IOracle.sol";
import {ISYToken} from "@interfaces/pendle/ISYToken.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IPendleMarket} from "@interfaces/pendle/IPendleMarket.sol";
import {IPendleOracle} from "@interfaces/pendle/IPendleOracle.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";
import {CoWSwapFarmBase} from "@integrations/farms/CoWSwapFarmBase.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title Pendle V2 Farm (V3)
/// @notice This contract is used to deploy assets to Pendle v2.
/// The V3 inherits from MultiAssetFarm and CoWSwapFarmBase. Investment into PTs is done in 2
/// steps: first, assetTokens have to be swapped to underlyingTokens using CoWSwap, then the
/// underlyingTokens can be swapped to PTs using Pendle's AMM. Divestment works the same way,
/// in the opposite direction.
/// Because the farm is a MultiAssetFarm, it is possible to move the underlyingTokens directly
/// between this farm and other farms, such that the swap fees to convert back to assetTokens is
/// not paid by the protocol every time there is a maturity event.
/// @dev Example deployment: PT-sUSDe-29MAY2025 market, USDC assetToken, sUSDe underlying token.
/// @dev It is V3 because yield token is considered same as underlying token
contract PendleV2FarmV3 is CoWSwapFarmBase, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    error PTAlreadyMatured(uint256 maturity);
    error PTNotMatured(uint256 maturity);
    error SwapFailed(bytes reason);

    event PTBought(
        uint256 indexed timestamp,
        uint256 timeToMaturity,
        uint256 yieldTokenIn,
        uint256 ptReceived,
        uint256 assetsSpent,
        uint256 assetsReceived,
        uint256 assetsAtMaturity
    );
    event PTSold(
        uint256 indexed timestamp,
        uint256 ptTokensIn,
        uint256 yieldTokensReceived,
        uint256 assetsSpent,
        uint256 assetsReceived
    );

    /// @notice Maturity of the Pendle market.
    uint256 public immutable maturity;

    /// @notice Reference to the Pendle market.
    address public immutable pendleMarket;

    /// @notice Reference to the Pendle oracle (for PT <-> underlying exchange rates).
    address public immutable pendleOracle;
    uint32 private constant _PENDLE_ORACLE_TWAP_DURATION = 1800;

    /// @notice Reference to the Pendle market's underlying token (the reference
    /// token PTs appreciate against).
    address public immutable underlyingToken;

    /// @notice Reference to the Pendle market's yield token (the token into which
    /// PTs convert at maturity)
    address public immutable yieldToken;

    /// @notice Reference to the Principal Token of the Pendle market.
    address public immutable ptToken;

    /// @notice Reference to the SY token of the Pendle market
    address public immutable syToken;

    /// @notice address of the Pendle router used for swaps
    address public pendleRouter;

    /// @notice Number of yieldTokens wrapped as PTs
    uint256 public totalWrappedYieldTokens;
    /// @notice Number of PTs received from wrapping yieldTokens
    uint256 public totalReceivedPTs;

    /// @notice Total yield already interpolated
    /// @dev this should be updated everytime we deposit and wrap assets
    uint256 public alreadyInterpolatedYield;

    /// @notice Timestamp of the last wrapping
    uint256 public lastWrappedTimestamp;

    /// @notice Discounting of assets at maturity for the value of PTs
    /// This is in place to account for potential swap losses at maturity, and has the effect
    /// of reducing the yield distributed while PTs are held, and causing a potential small
    /// yield spike when unwrapping PTs at maturity
    uint256 public maturityPTDiscount;

    constructor(
        address _core,
        address _assetToken,
        address _pendleMarket,
        address _pendleOracle,
        address _accounting,
        address _pendleRouter,
        address _settlementContract,
        address _vaultRelayer
    ) CoWSwapFarmBase(_settlementContract, _vaultRelayer) MultiAssetFarm(_core, _assetToken, _accounting) {
        pendleMarket = _pendleMarket;
        pendleOracle = _pendleOracle;
        pendleRouter = _pendleRouter;

        // read contracts and keep some immutable variables to save gas
        (syToken, ptToken,) = IPendleMarket(_pendleMarket).readTokens();
        (, underlyingToken,) = ISYToken(syToken).assetInfo();
        yieldToken = underlyingToken;

        maturity = IPendleMarket(_pendleMarket).expiry();

        // set default slippage tolerance to 0.3%
        maxSlippage = 0.997e18;
        // set default maturity discounting to 0.2%
        maturityPTDiscount = 0.998e18;

        // ensure pendle oracle is initialized for this market
        // https://docs.pendle.finance/Developers/Oracles/HowToIntegratePtAndLpOracle
        // this call will revert if the oracle is not initialized or if the cardinality
        // of the oracle has to be increased (if so, any eoa can do it on the Pendle contract
        // directly prior to deploying this farm).
        IPendleOracle(pendleOracle).getPtToAssetRate(_pendleMarket, _PENDLE_ORACLE_TWAP_DURATION);
    }

    function setPendleRouter(address _pendleRouter) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        pendleRouter = _pendleRouter;
    }

    /// @dev Be careful when setting this value, as calling it on a farm with invested PTs is going to cause a jump
    /// in the reported assets() value.
    function setMaturityPTDiscount(uint256 _maturityPTDiscount) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        maturityPTDiscount = _maturityPTDiscount;
    }

    function assetTokens() public view override returns (address[] memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = assetToken;
        tokens[1] = yieldToken;
        return tokens;
    }

    function isAssetSupported(address _asset) public view override returns (bool) {
        return _asset == assetToken || _asset == yieldToken;
    }

    /// @notice Returns the total assets in the farm
    /// before maturity, the assets are the sum of assets in the farm + assets wrapped + the interpolated yield
    /// after maturity, the assets are the sum of the assets() + the value of the PTs based on oracle prices
    /// @dev Note that the assets() function includes the current balance of assetTokens,
    /// this is because deposit()s and withdraw()als in this farm are handled asynchronously,
    /// as they have to go through swaps which calldata has to be generated offchain.
    /// This farm therefore holds its reserve in 3 tokens, assetToken, yieldTokens, and ptTokens.
    /// This farm's assets() reported does not take into account the slippage we might incur from
    /// converting assetTokens to yieldTokens and yieldTokens to ptTokens.
    function assets() public view override(MultiAssetFarm, IFarm) returns (uint256) {
        uint256 supportedAssetBalance = MultiAssetFarm.assets();

        if (block.timestamp < maturity) {
            // before maturity, interpolate yield
            return supportedAssetBalance + yieldTokensToAssets(totalWrappedYieldTokens) + interpolatingYield();
        }

        // after maturity, return the total USDC held in the farm +
        // the PTs value if any are still held
        uint256 balanceOfPTs = IERC20(ptToken).balanceOf(address(this));
        uint256 ptAssetsValue = 0;
        if (balanceOfPTs > 0) {
            // estimate the value of the PTs at maturity,
            // accounting for possible max slippage
            ptAssetsValue = ptToAssets(balanceOfPTs).mulWadDown(maturityPTDiscount);
        }
        return supportedAssetBalance + ptAssetsValue;
    }

    /// @notice swap a token in [assetToken, yieldToken] to a token out [assetToken, yieldToken]
    function signSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(_tokenIn == assetToken || _tokenIn == yieldToken, InvalidToken(_tokenIn));
        require(_tokenOut == assetToken || _tokenOut == yieldToken, InvalidToken(_tokenOut));
        require(_tokenIn != _tokenOut, InvalidToken(_tokenOut));

        return _checkSwapApproveAndSignOrder(_tokenIn, _tokenOut, _amountIn, _minAmountOut, maxSlippage);
    }

    /// @notice Wraps yieldTokens to PTs.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    /// @dev The caller is trusted to not be sandwiching the swap to steal yield.
    function wrapYieldTokenToPt(uint256 _yieldTokenIn, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(block.timestamp < maturity, PTAlreadyMatured(maturity));
        // update the already interpolated yield on each wrap
        alreadyInterpolatedYield = interpolatingYield();
        uint256 ptBalanceBefore = IERC20(ptToken).balanceOf(address(this));

        // do swap
        IERC20(yieldToken).forceApprove(pendleRouter, _yieldTokenIn);
        (bool success, bytes memory reason) = pendleRouter.call(_calldata);
        require(success, SwapFailed(reason));

        // check slippage
        uint256 ptBalanceAfter = IERC20(ptToken).balanceOf(address(this));
        uint256 ptReceived = ptBalanceAfter - ptBalanceBefore;
        uint256 minOut = _yieldTokenIn.mulWadDown(maxSlippage);
        uint256 actualOut = ptToYieldToken(ptReceived);
        require(actualOut >= minOut, SlippageTooHigh(minOut, actualOut));

        // update wrapped assets
        // @dev we are not doing totalWrappedYieldTokens += actualOut because we do not want to
        // report losses from buying PTs, as the PTs will earn yield towards maturity that should
        // make up for it.
        totalWrappedYieldTokens += _yieldTokenIn;
        totalReceivedPTs += ptReceived;
        lastWrappedTimestamp = block.timestamp;

        // emit event
        emit PTBought(
            block.timestamp,
            maturity - block.timestamp,
            _yieldTokenIn,
            ptReceived,
            yieldTokensToAssets(_yieldTokenIn),
            ptToAssets(ptReceived),
            ptReceived.mulWadDown(assetToPtUnderlyingRate())
        );
    }

    /// @notice Unwraps PTs to yieldTokens.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    function unwrapPtToYieldToken(uint256 _ptTokensIn, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        // MANUAL_REBALANCER role can bypass the maturity check and manually
        // exit positions before maturity.
        if (!core().hasRole(CoreRoles.MANUAL_REBALANCER, msg.sender)) {
            require(block.timestamp >= maturity, PTNotMatured(maturity));
        } else if (block.timestamp < maturity) {
            // early exit case: an address with MANUAL_REBALANCER can swap all the PTs
            // to yieldTokens before maturity, should it be needed.
            // a step jump will occur in reported assets(), because the contract conservatively
            // discounts for potential slippage during interpolation, but actual unwrap often
            // recovers more value.
            require(_ptTokensIn == totalReceivedPTs, SwapFailed("Must unwrap all"));
            totalWrappedYieldTokens = 0;
            totalReceivedPTs = 0;
            lastWrappedTimestamp = 0;
            alreadyInterpolatedYield = 0;
        }
        uint256 yieldTokensBefore = IERC20(yieldToken).balanceOf(address(this));

        // do swap
        IERC20(ptToken).forceApprove(pendleRouter, _ptTokensIn);
        (bool success, bytes memory reason) = pendleRouter.call(_calldata);
        require(success, SwapFailed(reason));

        // check slippage
        uint256 yieldTokensAfter = IERC20(yieldToken).balanceOf(address(this));
        uint256 yieldTokensReceived = yieldTokensAfter - yieldTokensBefore;
        uint256 minOut = ptToYieldToken(_ptTokensIn).mulWadDown(maxSlippage);
        require(yieldTokensReceived >= minOut, SlippageTooHigh(minOut, yieldTokensReceived));

        // emit event
        emit PTSold(
            block.timestamp,
            _ptTokensIn,
            yieldTokensReceived,
            _ptTokensIn.mulWadDown(assetToPtUnderlyingRate()),
            yieldTokensToAssets(yieldTokensReceived)
        );
    }

    function ptToYieldToken(uint256 _ptAmount) public view returns (uint256) {
        if (_ptAmount == 0) return 0;
        uint256 yieldTokenPrice = Accounting(accounting).price(yieldToken);
        uint256 underlyingPrice = Accounting(accounting).price(underlyingToken);
        return ptToUnderlying(_ptAmount).mulDivDown(underlyingPrice, yieldTokenPrice);
    }

    function yieldTokensToAssets(uint256 _yieldTokensAmount) public view returns (uint256) {
        uint256 assetPrice = Accounting(accounting).price(assetToken);
        uint256 yieldTokenPrice = Accounting(accounting).price(yieldToken);
        return _yieldTokensAmount.mulDivDown(yieldTokenPrice, assetPrice);
    }

    /// @dev e.g. for ptToken = PT-USDe-29MAY2025 and assetToken = USDC,
    /// this oracle returns the exchange rate of USDe (the underlying token) to USDC.
    /// Since USDe has 18 decimals and USDC has 6, and the exchange rate is ~1:1,
    /// the oracle should return a value ~= 1e6 because the USDC oracle returns 1e30
    /// and the USDe oracle returns 1e18.
    function assetToPtUnderlyingRate() public view returns (uint256) {
        uint256 assetPrice = Accounting(accounting).price(assetToken);
        uint256 underlyingPrice = Accounting(accounting).price(underlyingToken);
        return underlyingPrice.divWadDown(assetPrice);
    }

    /// @notice Converts a number of underlyingTokens to assetTokens based on oracle rates.
    function underlyingToAssets(uint256 _underlyingAmount) public view returns (uint256) {
        if (_underlyingAmount == 0) return 0;
        return _underlyingAmount.mulWadDown(assetToPtUnderlyingRate());
    }

    /// @notice Converts a number of PTs to assetTokens based on oracle rates.
    function ptToAssets(uint256 _ptAmount) public view returns (uint256) {
        if (_ptAmount == 0) return 0;
        return ptToUnderlying(_ptAmount).mulWadDown(assetToPtUnderlyingRate());
    }

    /// @notice Converts a number of PTs to underlyingTokens based on oracle rates.
    function ptToUnderlying(uint256 _ptAmount) public view returns (uint256) {
        if (_ptAmount == 0) return 0;
        // read oracles
        uint256 ptToUnderlyingRate =
            IPendleOracle(pendleOracle).getPtToAssetRate(pendleMarket, _PENDLE_ORACLE_TWAP_DURATION);
        // convert
        return _ptAmount.mulWadDown(ptToUnderlyingRate);
    }

    /// @notice Computes the yield to interpolate from the last deposit to maturity.
    /// @dev this function is and should only be called before maturity
    function interpolatingYield() public view returns (uint256) {
        // if no wrapping has been made yet, no yield to interpolate
        if (lastWrappedTimestamp == 0) return 0;
        uint256 balanceOfPTs = IERC20(ptToken).balanceOf(address(this));
        // if not PTs held, no need to interpolate
        if (balanceOfPTs == 0) return 0;

        // we want to interpolate the yield from the current time to maturity
        // to do that, we first need to compute how much USDC we should be able to get once maturity is reached
        // at maturity, 1 PT is worth 1 underlying PT asset (e.g. USDE)
        // so we can compute the amount of assets (eg USDC) we should get at maturity by using the assetToPtUnderlyingRate
        // in this example, assetToPtUnderlyingRate gives the price of USDE in USDC. probably close to 1:1
        uint256 maturityAssetAmount = balanceOfPTs.mulWadDown(assetToPtUnderlyingRate());
        // account for slippage, because unwrapping PTs => assets will cause some slippage using pendle's AMM
        maturityAssetAmount = maturityAssetAmount.mulWadDown(maturityPTDiscount);

        // compute the yield to interpolate, which is the target amount (maturityAssetAmount) minus the amount of assets
        // wrapped minus the already interpolated yield (can be != 0 if we made multiple wraps)
        uint256 totalWrappedAssets = yieldTokensToAssets(totalWrappedYieldTokens);
        int256 totalYieldRemainingToInterpolate =
            int256(maturityAssetAmount) - int256(totalWrappedAssets) - int256(alreadyInterpolatedYield);

        // in case the rate moved against us, we return the already interpolated yield
        if (totalYieldRemainingToInterpolate < 0) {
            return alreadyInterpolatedYield;
        }

        // cannot underflow because lastWrappedTimestamp cannot be after maturity as we cannot wrap after maturity
        // and lastWrappedTimestamp is always > 0 otherwise the first line of this function would have returned 0
        uint256 yieldPerSecond =
            (uint256(totalYieldRemainingToInterpolate) * FixedPointMathLib.WAD) / (maturity - lastWrappedTimestamp);
        uint256 secondsSinceLastWrap = block.timestamp - lastWrappedTimestamp;
        uint256 interpolatedYield = yieldPerSecond * secondsSinceLastWrap;
        return alreadyInterpolatedYield + interpolatedYield / FixedPointMathLib.WAD;
    }
}
