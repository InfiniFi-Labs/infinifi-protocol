// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {IPPYLpOracle as IPendleOracle} from "@pendle/interfaces/IPPYLpOracle.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {CoWSwapBase} from "@integrations/CoWSwapBase.sol";
import {IPendleV2FarmV3} from "@interfaces/IPendleV2FarmV3.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

import {PendleStructGen} from "@libraries/PendleStructGen.sol";
import {
    IPYieldToken,
    IPPrincipalToken,
    IStandardizedYield,
    IPAllActionV3,
    IPMarket
} from "@pendle/interfaces/IPAllActionV3.sol";

/// @title Pendle V2 Farm (V3)
/// @notice Integrates with Pendle v2 for yield token strategies
/// @dev This contract manages Principal Tokens (PTs) and provides yield interpolation mechanisms
/// @dev Inherits from MultiAssetFarm for multi-asset support and CoWSwapFarmBase for MEV protection
/// ## Yield Mechanism:
/// - Before maturity: PTs trade at discount, yield is interpolated linearly
/// - At maturity: PTs redeem 1:1 for yield tokens, creating yield spike
/// - Maturity discount factor accounts for potential swap losses
contract PendleV2FarmV3 is MultiAssetFarmV2, CoWSwapBase, ReentrancyGuard, IPendleV2FarmV3 {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using FixedPointMathLib for uint256;

    IPYieldToken public immutable YT;
    IPPrincipalToken public immutable PT;
    IStandardizedYield public immutable SY;

    /// @notice Maturity timestamp of the Pendle market when PTs can be redeemed for underlying tokens
    uint256 public immutable maturity;

    /// @notice Reference to the Pendle market contract for this specific yield token
    IPMarket public immutable pendleMarket;

    /// @notice Reference to the Pendle oracle used for PT to underlying asset exchange rates
    address public immutable pendleOracle;

    /// @notice TWAP duration for Pendle oracle queries (30 minutes)
    uint32 private constant _PENDLE_ORACLE_TWAP_DURATION = 1800;

    /// @notice The underlying asset token that PTs will be 1-1 with at maturity
    /// @dev NOTE: Always make sure that pivot token is not rebasing
    address public immutable pivotToken;

    /// @notice Address of the Pendle router used for executing swaps and PT operations
    IPAllActionV3 public pendleRouter;

    /// @notice Address that receives PTs when transferred from this farm
    address public ptReceiver;

    /// @notice Total number of PTs currently held by this farm (tracked for reconciliation)
    uint256 public totalReceivedPTs;

    /// @notice Minimum PT balance difference required to trigger reconciliation
    /// @dev Used to handle airdrops, external transfers, or accounting discrepancies
    uint256 public ptThreshold;

    /// @notice Discount factor applied to PT values at maturity to account for swap slippage
    /// @dev Reduces reported yield during PT holding period and creates yield spike at unwrap
    uint256 public maturityPTDiscount;

    /// @notice Timestamp of the last accrual rate update for yield interpolation
    uint256 public lastCheckpointTimestamp;

    /// @notice Rate at which yield accrues per second, denominated in assetTokens
    uint256 public accrualRate;

    /// @notice Total amount of assets currently wrapped as PTs, in assetTokens
    uint256 public totalWrappedAssets;

    /// @notice Initializes the PendleV2FarmV3 contract
    /// @param _core Address of the InfiniFi core contract
    /// @param _assetToken Primary asset token for this farm (e.g., USDC)
    /// @param _pendleMarket Address of the Pendle market for the target yield token
    /// @param _pendleOracle Address of the Pendle oracle for PT pricing
    /// @param _accounting Address of the accounting contract for price conversions
    /// @param _pendleRouter Address of the Pendle router for executing swaps
    /// @param _settlementContract Address of the CoW Protocol settlement contract
    /// @param _vaultRelayer Address of the CoW Protocol vault relayer
    /// @dev Validates that the Pendle market is properly initialized and oracle is ready
    /// @dev Sets up supported asset tokens from the SY's tokensIn and tokensOut arrays
    constructor(
        address _core,
        address _assetToken,
        address _pendleMarket,
        address _pendleOracle,
        address _accounting,
        address _pendleRouter,
        address _settlementContract,
        address _vaultRelayer
    ) CoWSwapBase(_settlementContract, _vaultRelayer, true) MultiAssetFarmV2(_core, _assetToken, _accounting) {
        pendleOracle = _pendleOracle;
        pendleMarket = IPMarket(_pendleMarket);
        pendleRouter = IPAllActionV3(_pendleRouter);

        // read expiry
        maturity = pendleMarket.expiry();
        // read contracts and keep some immutable variables to save gas
        (SY, PT, YT) = pendleMarket.readTokens();
        (, pivotToken,) = SY.assetInfo();

        address[] memory tokensIn = SY.getTokensIn();
        address[] memory tokensOut = SY.getTokensOut();

        _enableAsset(_assetToken);
        _enableAsset(pivotToken);

        for (uint256 i = 0; i < tokensIn.length; i++) {
            _enableAsset(tokensIn[i]);
        }

        for (uint256 i = 0; i < tokensOut.length; i++) {
            _enableAsset(tokensOut[i]);
        }

        // set default threshold 10 PTs
        ptThreshold = 10 * 10 ** (PT.decimals());
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

    /// @notice Ensures the farm's PT balance is reconciled before executing operations
    /// @dev Prevents operations when there's a significant discrepancy between tracked and actual PT balances
    /// @dev Allows small differences up to ptThreshold to account for rounding errors
    modifier onlyReconciled() {
        _checkIsReconciled();
        _;
    }

    /// @notice Updates the Pendle router address used for swaps
    /// @param _pendleRouter New address of the Pendle router
    /// @dev Only callable by PROTOCOL_PARAMETERS role
    function setPendleRouter(address _pendleRouter) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        pendleRouter = IPAllActionV3(_pendleRouter);
        emit PendleRouterUpdated(block.timestamp, _pendleRouter);
    }

    /// @notice Sets the discount factor applied to PT values at maturity
    /// @param _maturityPTDiscount New discount factor (1e18 = 100%, 0.998e18 = 99.8%)
    /// @dev WARNING: Changing this on a farm with invested PTs will cause a jump in reported assets()
    /// @dev Only callable by PROTOCOL_PARAMETERS role
    function setMaturityPTDiscount(uint256 _maturityPTDiscount) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        maturityPTDiscount = _maturityPTDiscount;
        _handleBalanceChange(0);
        emit MaturityPTDiscountUpdated(block.timestamp, _maturityPTDiscount);
    }

    /// @notice Sets the threshold for PT reconciliation
    /// @param _ptThreshold New threshold
    /// @dev Only callable by PROTOCOL_PARAMETERS role
    function setPtThreshold(uint256 _ptThreshold) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        ptThreshold = _ptThreshold;
        emit PTThresholdUpdated(block.timestamp, _ptThreshold);
    }

    /// @notice Sets the address that will receive PTs when transferred from this farm
    /// @param _ptReceiver Address to receive transferred PTs
    /// @dev Cannot be set to this contract's address
    /// @dev Only callable by PROTOCOL_PARAMETERS role
    function setPTReceiver(address _ptReceiver) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_ptReceiver != address(this), PTReceiverIsSelf());
        ptReceiver = _ptReceiver;
        emit PTReceiverChanged(block.timestamp, _ptReceiver);
    }

    function assets() public view override returns (uint256) {
        uint256 supportedAssetBalance = MultiAssetFarmV2.assets();
        uint256 ptAssetsValue = ptToAssetsAtMaturity(totalReceivedPTs).mulWadDown(maturityPTDiscount) - remainingYield();

        return supportedAssetBalance + ptAssetsValue;
    }

    /// @notice Calculates the remaining yield that will be distributed until maturity
    /// @return Amount of yield remaining to be distributed, in assetTokens
    /// @dev Returns 0 if maturity has already passed
    function remainingYield() public view returns (uint256) {
        if (block.timestamp >= maturity) return 0;
        return accrualRate.mulWadDown(maturity - block.timestamp);
    }

    /// @notice Calculates the interpolated yield that is already reported by the farm
    /// @dev Returns 0 if maturity has already passed
    function interpolatedYield() public view returns (uint256) {
        if (block.timestamp >= maturity) return 0;
        if (block.timestamp <= lastCheckpointTimestamp) return 0;
        return accrualRate.mulWadUp(block.timestamp - lastCheckpointTimestamp);
    }

    /// ============================================================
    /// Wrap/Unwrap supported tokens to PTs
    /// ============================================================

    /// @notice Wraps supported tokens into Pendle Principal Tokens (PTs)
    /// @param _tokenIn Token to wrap (must be valid input for the SY)
    /// @param _amountIn Amount of tokens to wrap
    /// @dev Uses Pendle router to swap tokens for PTs with slippage protection
    /// @dev Can be called multiple times with partial amounts to reduce slippage
    /// @dev Transaction can be submitted privately to avoid MEV attacks
    /// @dev Only callable before maturity and by FARM_SWAP_CALLER role
    function wrapToPt(address _tokenIn, uint256 _amountIn)
        external
        whenNotPaused
        nonReentrant
        onlyReconciled
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        _validateAmount(_tokenIn, _amountIn);
        require(block.timestamp < maturity, PTAlreadyMatured(maturity));
        require(isAssetSupported(_tokenIn) && SY.isValidTokenIn(_tokenIn), InvalidToken(_tokenIn));

        // do swap
        IERC20(_tokenIn).forceApprove(address(pendleRouter), _amountIn);
        (uint256 ptReceived,,) = pendleRouter.swapExactTokenForPt(
            address(this),
            address(pendleMarket),
            0,
            PendleStructGen.createDefaultApprox(),
            PendleStructGen.createTokenInputStruct(_tokenIn, _amountIn),
            PendleStructGen.createEmptyLimitOrder()
        );

        _checkSlippageIn(_tokenIn, _amountIn, ptReceived);

        uint256 assetAmountIn = convert(_tokenIn, assetToken, _amountIn);
        _handleBalanceChange(int256(assetAmountIn));

        emit PTWrapped(block.timestamp, _tokenIn, _amountIn, ptReceived, assetAmountIn);
    }

    /// @notice Unwraps Pendle Principal Tokens (PTs) into supported tokens
    /// @param _tokenOut Token to receive (must be valid output for the SY)
    /// @param _ptTokensIn Amount of PTs to unwrap
    /// @dev Uses Pendle router to swap PTs for tokens with slippage protection
    /// @dev Before maturity: swaps PTs for tokens on the market
    /// @dev After maturity: redeems PTs directly for supported out tokens
    /// @dev MANUAL_REBALANCER role can unwrap before maturity for emergency exits
    /// @dev Only callable by FARM_SWAP_CALLER role
    function unwrapFromPt(address _tokenOut, uint256 _ptTokensIn)
        external
        whenNotPaused
        nonReentrant
        onlyReconciled
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        _validateAmount(address(PT), _ptTokensIn);
        require(isAssetSupported(_tokenOut) && SY.isValidTokenOut(_tokenOut), InvalidToken(_tokenOut));

        // MANUAL_REBALANCER role can bypass the maturity check and manually
        // exit positions before maturity.
        if (!core().hasRole(CoreRoles.MANUAL_REBALANCER, msg.sender)) {
            require(block.timestamp >= maturity, PTNotMatured(maturity));
        }

        uint256 tokensOut = 0;
        // do swap
        IERC20(PT).forceApprove(address(pendleRouter), _ptTokensIn);
        if (block.timestamp < maturity) {
            (tokensOut,,) = pendleRouter.swapExactPtForToken(
                address(this),
                address(pendleMarket),
                _ptTokensIn,
                PendleStructGen.createTokenOutputStruct(_tokenOut, 0),
                PendleStructGen.createEmptyLimitOrder()
            );
        } else {
            (tokensOut,) = pendleRouter.redeemPyToToken(
                address(this), address(YT), _ptTokensIn, PendleStructGen.createTokenOutputStruct(_tokenOut, 0)
            );
        }

        _checkSlippageOut(_tokenOut, _ptTokensIn, tokensOut);

        uint256 assetsOut = convert(_tokenOut, assetToken, tokensOut);
        _handleBalanceChange(-int256(assetsOut));

        emit PTUnwrapped(block.timestamp, _tokenOut, _ptTokensIn, tokensOut, assetsOut);
    }

    /// @notice Wraps tokens into PTs using custom Pendle router calldata
    /// @param _tokenIn Token to wrap (must be supported by the farm)
    /// @param _amountIn Amount of tokens to wrap
    /// @param _calldata Custom calldata for Pendle router execution
    /// @dev Allows for custom swap parameters and advanced Pendle operations
    /// @dev Can be called multiple times with partial amounts to reduce slippage
    /// @dev Transaction can be submitted privately to avoid MEV attacks
    /// @dev Only callable before maturity and by FARM_SWAP_CALLER role
    function wrapToPt(address _tokenIn, uint256 _amountIn, bytes memory _calldata)
        external
        whenNotPaused
        nonReentrant
        onlyReconciled
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        _validateAmount(_tokenIn, _amountIn);
        require(block.timestamp < maturity, PTAlreadyMatured(maturity));
        require(isAssetSupported(_tokenIn), InvalidToken(_tokenIn));

        uint256 ptBalanceBefore = PT.balanceOf(address(this));

        // do swap
        IERC20(_tokenIn).forceApprove(address(pendleRouter), _amountIn);
        (bool success, bytes memory reason) = address(pendleRouter).call(_calldata);
        require(success, SwapFailed(reason));

        // check slippage
        uint256 ptBalanceAfter = PT.balanceOf(address(this));
        uint256 ptReceived = ptBalanceAfter - ptBalanceBefore;

        _checkSlippageIn(_tokenIn, _amountIn, ptReceived);

        // tokens are returned from SY getTokensOut
        uint256 assetAmountIn = convert(_tokenIn, assetToken, _amountIn);
        _handleBalanceChange(int256(assetAmountIn));

        emit PTZappedIn(block.timestamp, _tokenIn, _amountIn, ptReceived, assetAmountIn);
    }

    /// @notice Unwraps PTs into tokens using custom Pendle router calldata
    /// @param _tokenOut Token to receive (must be supported by the farm)
    /// @param _ptTokensIn Amount of PTs to unwrap
    /// @param _calldata Custom calldata for Pendle router execution
    /// @dev Allows for custom swap parameters and advanced Pendle operations
    /// @dev MANUAL_REBALANCER role can unwrap before maturity for emergency exits
    /// @dev Only callable by FARM_SWAP_CALLER role
    function unwrapFromPt(address _tokenOut, uint256 _ptTokensIn, bytes memory _calldata)
        external
        whenNotPaused
        nonReentrant
        onlyReconciled
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        _validateAmount(address(PT), _ptTokensIn);
        require(isAssetSupported(_tokenOut), InvalidToken(_tokenOut));
        // MANUAL_REBALANCER role can bypass the maturity check and manually
        // exit positions before maturity.
        if (!core().hasRole(CoreRoles.MANUAL_REBALANCER, msg.sender)) {
            require(block.timestamp >= maturity, PTNotMatured(maturity));
        }

        uint256 tokensBefore = IERC20(_tokenOut).balanceOf(address(this));

        // do swap
        IERC20(PT).forceApprove(address(pendleRouter), _ptTokensIn);
        (bool success, bytes memory reason) = address(pendleRouter).call(_calldata);
        require(success, SwapFailed(reason));

        // check slippage
        uint256 tokensAfter = IERC20(_tokenOut).balanceOf(address(this));
        uint256 tokensOut = tokensAfter - tokensBefore;

        _checkSlippageOut(_tokenOut, _ptTokensIn, tokensOut);

        uint256 assetsOut = convert(_tokenOut, assetToken, tokensOut);
        _handleBalanceChange(-int256(assetsOut));

        emit PTZappedOut(block.timestamp, _tokenOut, tokensOut, _ptTokensIn, assetsOut);
    }

    /// @notice Transfers PTs to the configured receiver and reconciles accounting
    /// @param _amount Amount of PTs to transfer
    /// @dev HIGHLY SENSITIVE: Transfers PTs and updates accounting on both farms
    /// @dev Requires ptReceiver to be set and implements reconciliation
    /// @dev Only callable by FARM_SWAP_CALLER role
    function transferPt(uint256 _amount, bool _reconcile)
        external
        whenNotPaused
        onlyReconciled
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        _validateAmount(address(PT), _amount);
        require(ptReceiver != address(0), PTReceiverNotSet());

        IERC20(PT).safeTransfer(ptReceiver, _amount);

        int256 assetsValue = _estimateAssetsValue(-int256(_amount));
        _handleBalanceChange(assetsValue);

        if (_reconcile) {
            PendleV2FarmV3(ptReceiver).reconcilePt();
        }

        emit PTTransferred(block.timestamp, ptReceiver, _amount, uint256(-assetsValue));
    }

    /// @notice Reconciles tracked balances with actual token balances
    /// @dev This function should be called to handle PT airdrops, external transfers, or any
    /// scenario where the actual PT balance differs from the tracked balance.
    function reconcilePt() external whenNotPaused nonReentrant {
        uint256 balanceOfPTs = PT.balanceOf(address(this));
        int256 ptDifference = int256(balanceOfPTs) - int256(totalReceivedPTs);

        uint256 ptDifferenceAbs = uint256(ptDifference > 0 ? ptDifference : -ptDifference);
        require(ptDifferenceAbs >= ptThreshold, NoPTsToReconcile(ptDifference));

        int256 assetsValue = _estimateAssetsValue(ptDifference);
        _handleBalanceChange(assetsValue);

        emit PTReconciled(block.timestamp, assetsValue, ptDifference);
    }

    /// @notice Signs a CoW Protocol swap order for supported asset tokens
    /// @param _tokenIn Token to swap from
    /// @param _tokenOut Token to swap to
    /// @param _amountIn Amount of input token to swap
    /// @param _minAmountOut Minimum amount of output token expected
    /// @return Calldata for the CoW Protocol swap order
    /// @dev Both tokens must be supported and have oracles
    /// @dev Only callable by FARM_SWAP_CALLER role
    function signSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        _validateAmount(_tokenIn, _amountIn);
        CoWSwapBase.CoWSwapData memory _data =
            CoWSwapBase.CoWSwapData(_tokenIn, _tokenOut, _amountIn, _minAmountOut, maxSlippage);

        return _checkSwapApproveAndSignOrder(_data);
    }

    /// ============================================================
    /// PT Conversions to asset tokens
    /// ============================================================

    /// @notice Converts PTs to assetTokens using Pendle oracle rates
    /// @param _ptAmount Amount of PTs to convert
    /// @return Equivalent amount in assetTokens
    /// @dev Uses Pendle oracle TWAP for spot pricing
    /// @dev Returns 0 if oracle rate is unavailable
    function ptToAssets(uint256 _ptAmount) public view returns (uint256) {
        if (_ptAmount == 0) return 0;

        uint256 ptToSyAssetTokenRate =
            IPendleOracle(pendleOracle).getPtToAssetRate(address(pendleMarket), _PENDLE_ORACLE_TWAP_DURATION);

        if (ptToSyAssetTokenRate == 0) return 0;
        uint256 syAssetTokenAmount = _ptAmount.mulWadDown(ptToSyAssetTokenRate);
        return convert(pivotToken, assetToken, syAssetTokenAmount);
    }

    /// @notice Calculates the asset value of a given amount of PTs, at maturity
    /// @param _ptAmount Amount of PTs to value
    /// @return PT value in assetTokens
    /// @dev At maturity, PTs have a 1:1 conversion with pivot token, and PT token has the
    /// same amount of decimals as the pivot token, therefore we can do a conversion from
    /// pivot token to asset token to price the PTs at maturity.
    /// @dev this returns a raw value where maturityPTDiscount is not applied
    function ptToAssetsAtMaturity(uint256 _ptAmount) public view returns (uint256) {
        return convert(pivotToken, assetToken, _ptAmount);
    }

    /// ============================================================
    /// Internal functions
    /// ============================================================

    /// @notice Updates farm accounting when PT balance changes
    /// @param _assetsIn Change in assets (positive for deposits, negative for withdrawals)
    /// @dev Updates accrual rate and interpolation parameters for yield distribution
    /// @dev Clears accrual data after maturity as no more yield can be earned
    function _handleBalanceChange(int256 _assetsIn) internal {
        uint256 ptBalance = PT.balanceOf(address(this));
        totalReceivedPTs = ptBalance;
        if (block.timestamp >= maturity) {
            delete accrualRate;
            delete totalWrappedAssets;
            return;
        }

        uint256 currentAssets = totalWrappedAssets + interpolatedYield();

        if (_assetsIn > 0) {
            currentAssets += uint256(_assetsIn);
        } else {
            currentAssets = _safeSubtract(currentAssets, uint256(-_assetsIn));
        }

        uint256 assetsAtMaturity = ptToAssetsAtMaturity(ptBalance).mulWadDown(maturityPTDiscount);
        uint256 yieldDifference = _safeSubtract(assetsAtMaturity, currentAssets);
        uint256 _accrualRate = yieldDifference.divWadUp(maturity - block.timestamp);

        accrualRate = _accrualRate;
        lastCheckpointTimestamp = block.timestamp;
        totalWrappedAssets = assetsAtMaturity - yieldDifference;
    }

    /// @notice estimates asset value based on the current exchange rate between:
    /// the PTs held and the assets reported by the farm
    function _estimateAssetsValue(int256 _ptAmount) internal view returns (int256) {
        if (block.timestamp >= maturity) return 0;

        // farm must have actived wrap to be able to give estimates
        require(totalWrappedAssets > 0, FarmNotUsed(totalReceivedPTs, totalWrappedAssets));
        require(totalReceivedPTs > 0, FarmNotUsed(totalReceivedPTs, totalWrappedAssets));

        uint256 currentAssets = totalWrappedAssets + interpolatedYield();
        uint256 assetsAtMaturity = ptToAssetsAtMaturity(totalReceivedPTs);
        uint256 currentRatio = currentAssets.divWadUp(assetsAtMaturity);

        if (_ptAmount > 0) {
            uint256 _assetAmount = uint256(_ptAmount).mulWadDown(currentRatio);
            return int256(convert(pivotToken, assetToken, _assetAmount));
        }

        uint256 assetAmount = uint256(-_ptAmount).mulWadDown(currentRatio);
        return -int256(convert(pivotToken, assetToken, assetAmount));
    }

    /// @inheritdoc CoWSwapBase
    function _validateSwap(CoWSwapData memory _data) internal virtual override {
        require(isAssetSupported(_data.tokenIn), InvalidToken(_data.tokenIn));
        require(isAssetSupported(_data.tokenOut), InvalidToken(_data.tokenOut));
        require(_data.tokenIn != _data.tokenOut, InvalidToken(_data.tokenOut));

        uint256 minOutSlippage = convert(_data.tokenIn, _data.tokenOut, _data.amountIn).mulWadDown(_data.maxSlippage);
        require(_data.minAmountOut > minOutSlippage, SlippageTooHigh(minOutSlippage, _data.minAmountOut));
    }

    /// @notice Validates slippage for unwrap operations
    /// @param _tokenOut Token received from unwrapping
    /// @param _amountIn Amount of PTs unwrapped
    /// @param _amountOut Amount of tokens received
    /// @dev Ensures actual output meets minimum slippage requirements
    function _checkSlippageOut(address _tokenOut, uint256 _amountIn, uint256 _amountOut) private view {
        uint256 minOut = ptToAssets(_amountIn).mulWadDown(maxSlippage);
        uint256 assetsOut = convert(_tokenOut, assetToken, _amountOut);
        require(assetsOut >= minOut, SlippageTooHigh(minOut, assetsOut));
    }

    /// @notice Validates slippage for wrap operations
    /// @param _tokenIn Token used for wrapping
    /// @param _amountIn Amount of tokens wrapped
    /// @param _amountOut Amount of PTs received
    /// @dev Ensures actual output meets minimum slippage requirements
    function _checkSlippageIn(address _tokenIn, uint256 _amountIn, uint256 _amountOut) private view {
        uint256 assetsOut = convert(_tokenIn, assetToken, _amountIn);
        uint256 minOut = assetsOut.mulWadDown(maxSlippage);
        uint256 actualOut = ptToAssets(_amountOut);
        require(actualOut >= minOut, SlippageTooHigh(minOut, actualOut));
    }

    /// @notice Validates that the specified amount is valid and available
    /// @param _asset Address of the token to check
    /// @param _amount Amount to validate
    /// @dev Ensures amount is positive and doesn't exceed the contract's balance
    function _validateAmount(address _asset, uint256 _amount) internal view {
        require(_amount > 0, InvalidAmountIn(_amount));
        uint256 balance = IERC20(_asset).balanceOf(address(this));
        require(_amount <= balance, InsufficientBalance(_asset, _amount));
    }

    /// @notice Ensures the farm's PT balance is reconciled before executing operations
    /// @dev Prevents operations when there's a significant discrepancy between tracked and actual PT balances
    /// @dev In case there were no deposits in the farm or no unwraps allows operations
    /// @dev Allows small differences up to ptThreshold to account for rounding errors
    function _checkIsReconciled() internal view {
        if (totalReceivedPTs == 0) return;

        uint256 balanceOfPTs = PT.balanceOf(address(this));
        if (balanceOfPTs != totalReceivedPTs) {
            int256 ptDifference = int256(balanceOfPTs) - int256(totalReceivedPTs);
            uint256 ptDifferenceAbs = uint256(ptDifference > 0 ? ptDifference : -ptDifference);
            require(ptDifferenceAbs <= ptThreshold, FarmNotReconciled(totalReceivedPTs, balanceOfPTs));
        }
    }

    /// @notice Safely subtracts two numbers, returning 0 if underflow would occur
    /// @param _a First number
    /// @param _b Second number to subtract
    /// @return Result of subtraction or 0 if underflow
    /// @dev Used for approximations where underflow is acceptable
    function _safeSubtract(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a > _b ? _a - _b : 0;
    }
}
