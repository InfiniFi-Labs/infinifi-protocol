// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {IOracle} from "@interfaces/IOracle.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title Swap Farm
/// @notice This contract is used to deploy assets using a swap router. Funds are deposited in the farm
/// in assetTokens, and are then swapped into and out of wrapTokens. This can be used to swap between USDC
/// assetTokens into yield-bearing USD-denominated tokens (e.g. treasuries, mmfs, etc).
/// @dev This farm is considered illiquid as swapping in & out will incur slippage.
contract SwapFarm is Farm, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    error SwapFailed(bytes returnData);
    error SwapCooldown();
    error RouterNotEnabled(address router);

    event SetEnabledRouter(uint256 timestamp, address router, bool enabled);

    /// @notice Reference to the wrap token (to which assetTokens are swapped).
    address public immutable wrapToken;

    /// @notice Reference to accounting contract.
    address public immutable accounting;

    /// @notice Duration of the farm (maturity() returns block.timestamp + duration)
    /// @dev This can be set to 0, treating the farm as a liquid farm, however there will be
    /// slippage to swap in & out of the farm, which acts as some kind of entrance & exit fees.
    /// Consider setting a duration that is at least long enough to earn yield that covers the swap fees.
    uint256 private immutable duration;

    /// @notice Mapping of routers that can be used to swap assetTokens <-> wrapTokens.
    mapping(address => bool) public enabledRouters;

    /// @notice timestamp of last swap
    uint256 public lastSwap = 1;
    /// @notice cooldown period after a swap before another swap can be performed
    uint256 public constant _SWAP_COOLDOWN = 4 hours;

    constructor(address _core, address _assetToken, address _wrapToken, address _accounting, uint256 _duration)
        Farm(_core, _assetToken)
    {
        wrapToken = _wrapToken;
        accounting = _accounting;
        duration = _duration;

        // set default slippage tolerance to 99.5%
        maxSlippage = 0.995e18;
    }

    /// @notice Maturity is virtually set as "always in the future" to reflect
    /// that there are swap fees to exit the farm.
    /// In reality we can always swap out, so maturity should be block.timestamp, but these farms
    /// should be treated as illiquid & having a maturity in the future is a good compromise,
    /// because we don't want to allocate funds there unless they stay for at least enough time
    /// to earn yield that covers the swap fees (that act as some kind of entrance & exit fees).
    function maturity() public view override returns (uint256) {
        return block.timestamp + duration;
    }

    /// @notice Returns the total assets in the farm
    /// @dev Note that the assets() function includes the current balance of assetTokens,
    /// this is because deposit()s and withdraw()als in this farm are handled asynchronously,
    /// as they have to go through swaps which calldata has to be generated offchain.
    /// This farm therefore holds its reserve in 2 tokens, assetToken and wrapToken.
    function assets() public view virtual override(Farm, IFarm) returns (uint256) {
        uint256 assetTokenBalance = IERC20(assetToken).balanceOf(address(this));
        uint256 wrapTokenAssetsValue = convertToAssets(IERC20(wrapToken).balanceOf(address(this)));
        return assetTokenBalance + wrapTokenAssetsValue;
    }

    /// @notice Current liquidity of the farm is the held assetTokens.
    function liquidity() public view override returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this));
    }

    /// @notice Allows governance to manage the whitelist of routers to be used by the
    /// keeper with FARM_SWAP_CALLER role.
    function setEnabledRouter(address _router, bool _enabled) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        enabledRouters[_router] = _enabled;
        emit SetEnabledRouter(block.timestamp, _router, _enabled);
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm.
    /// @dev See call to wrapAssets() for the actual swap into wrapTokens.
    function _deposit(uint256) internal view override {}

    function deposit() external view override(Farm, IFarm) onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {}

    /// @dev Withdrawal can only handle the held assetTokens (i.e. the liquidity()).
    /// @dev See call to unwrapAssets() for the actual swap out of wrapTokens.
    function _withdraw(uint256 _amount, address _to) internal override {
        IERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice Converts a number of wrapTokens to assetTokens based on oracle rates.
    function convertToAssets(uint256 _wrapTokenAmount) public view returns (uint256) {
        uint256 assetTokenPrice = Accounting(accounting).price(assetToken);
        uint256 wrapTokenPrice = Accounting(accounting).price(wrapToken);
        return _wrapTokenAmount.mulDivDown(wrapTokenPrice, assetTokenPrice);
    }

    /// @notice Wraps assetTokens as wrapTokens.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    /// @dev The caller is trusted to not be sandwiching the swap to steal yield.
    function wrapAssets(uint256 _assetsIn, address _router, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(enabledRouters[_router], RouterNotEnabled(_router));
        require(block.timestamp > lastSwap + _SWAP_COOLDOWN, SwapCooldown());
        lastSwap = block.timestamp;
        uint256 wrapTokenBalanceBefore = IERC20(wrapToken).balanceOf(address(this));

        // do swap
        IERC20(assetToken).forceApprove(_router, _assetsIn);
        (bool success, bytes memory returnData) = _router.call(_calldata);
        require(success, SwapFailed(returnData));

        // check slippage
        uint256 wrapTokenReceived = IERC20(wrapToken).balanceOf(address(this)) - wrapTokenBalanceBefore;
        uint256 minAssetsOut = _assetsIn.mulWadDown(maxSlippage);
        uint256 assetsReceived = convertToAssets(wrapTokenReceived);
        require(assetsReceived >= minAssetsOut, SlippageTooHigh(minAssetsOut, assetsReceived));

        // optional hook to handle staking
        _afterWrap(wrapTokenReceived);
    }

    function _afterWrap(uint256 /*_wrapTokenReceived*/ ) internal virtual {}

    /// @notice Unwraps wrapTokens to assetTokens.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    function unwrapAssets(uint256 _wrapTokenAmount, address _router, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(enabledRouters[_router], RouterNotEnabled(_router));
        require(block.timestamp > lastSwap + _SWAP_COOLDOWN, SwapCooldown());
        lastSwap = block.timestamp;
        uint256 assetsBefore = IERC20(assetToken).balanceOf(address(this));

        // optional hook to handle unstaking
        _beforeUnwrap(_wrapTokenAmount);

        // do swap
        IERC20(wrapToken).forceApprove(_router, _wrapTokenAmount);
        (bool success, bytes memory returnData) = _router.call(_calldata);
        require(success, SwapFailed(returnData));

        // check slippage
        uint256 assetsReceived = IERC20(assetToken).balanceOf(address(this)) - assetsBefore;
        uint256 minAssetsOut = convertToAssets(_wrapTokenAmount).mulWadDown(maxSlippage);
        require(assetsReceived >= minAssetsOut, SlippageTooHigh(minAssetsOut, assetsReceived));
    }

    function _beforeUnwrap(uint256 /*_wrapTokenAmount*/ ) internal virtual {}
}
