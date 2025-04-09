// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {IOracle} from "@interfaces/IOracle.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title Swap Farm
/// @notice This contract is used to deploy assets using a swap router. Funds are deposited in the farm
/// in assetTokens, and are then swapped into and out of wrapTokens. This can be used to swap between USDC
/// assetTokens into yield-bearing USD-denominated tokens (e.g. treasuries, mmfs, etc).
/// @dev This farm is considered illiquid as swapping in & out will incur slippage.
contract SwapFarm is Farm, IMaturityFarm {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    error SwapFailed(bytes returnData);
    error SwapCooldown();
    error SlippageTooHigh(uint256 minAssetsOut, uint256 assetsReceived);

    /// @notice Reference to the wrap token (to which assetTokens are swapped).
    address public immutable wrapToken;

    /// @notice Reference to an oracle for the wrap token (for wrapToken <-> assetToken exchange rates).
    address public immutable wrapTokenOracle;

    /// @notice Max slippage for wrapping and unwrapping assetTokens <-> wrapTokens.
    /// @dev Stored as a percentage with 18 decimals of precision, of the minimum
    /// position size compared to the previous position size (so actually 1 - maxSlippage).
    uint256 private constant _MAX_SLIPPAGE = 0.995e18; // 99.5%

    /// @notice timestamp of last swap
    uint256 public lastSwap = 1;
    /// @notice cooldown period after a swap before another swap can be performed
    uint256 public constant _SWAP_COOLDOWN = 10 minutes;

    constructor(address _core, address _assetToken, address _wrapToken, address _wrapTokenOracle)
        Farm(_core, _assetToken)
    {
        wrapToken = _wrapToken;
        wrapTokenOracle = _wrapTokenOracle;
    }

    /// @notice Maturity is virtually set as "always in the future" to reflect
    /// that there are swap fees to exit the farm.
    /// In reality we can always swap out, so maturity should be block.timestamp, but these farms
    /// should be treated as illiquid & having a maturity in the future is a good compromise,
    /// because we don't want to allocate funds there unless they stay for at least enough time
    /// to earn yield that covers the swap fees (that act as some kind of entrance & exit fees).
    function maturity() public view override returns (uint256) {
        return block.timestamp + 30 days;
    }

    /// @notice Returns the total assets in the farm
    function assets() public view override(Farm, IFarm) returns (uint256) {
        uint256 wrapTokenAssetsValue = convertToAssets(ERC20(wrapToken).balanceOf(address(this)));
        return super.assets() + wrapTokenAssetsValue;
    }

    /// @notice Current liquidity of the farm is the held assetTokens.
    function liquidity() public view override returns (uint256) {
        return super.assets();
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm.
    /// @dev See call to wrapAssets() for the actual swap into wrapTokens.
    function _deposit() internal view override {}

    /// @dev Withdrawal can only handle the held assetTokens (i.e. the liquidity()).
    /// @dev See call to unwrapAssets() for the actual swap out of wrapTokens.
    function _withdraw(uint256 _amount, address _to) internal override {
        ERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice Converts a number of wrapTokens to assetTokens based on oracle rates.
    function convertToAssets(uint256 _wrapTokenAmount) public view returns (uint256) {
        uint256 wrapTokenToAssetRate = IOracle(wrapTokenOracle).price();
        return _wrapTokenAmount.divWadDown(wrapTokenToAssetRate);
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
        require(block.timestamp > lastSwap + _SWAP_COOLDOWN, SwapCooldown());
        lastSwap = block.timestamp;
        uint256 wrapTokenBalanceBefore = ERC20(wrapToken).balanceOf(address(this));

        // do swap
        ERC20(assetToken).approve(_router, _assetsIn);
        (bool success, bytes memory returnData) = _router.call(_calldata);
        require(success, SwapFailed(returnData));

        // check slippage
        uint256 wrapTokenReceived = ERC20(wrapToken).balanceOf(address(this)) - wrapTokenBalanceBefore;
        uint256 minAssetsOut = _assetsIn.mulWadDown(_MAX_SLIPPAGE);
        uint256 assetsReceived = convertToAssets(wrapTokenReceived);
        require(assetsReceived > minAssetsOut, SlippageTooHigh(minAssetsOut, assetsReceived));
    }

    /// @notice Unwraps wrapTokens to assetTokens.
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage.
    function unwrapAssets(uint256 _wrapTokenAmount, address _router, bytes memory _calldata)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        require(block.timestamp > lastSwap + _SWAP_COOLDOWN, SwapCooldown());
        lastSwap = block.timestamp;
        uint256 assetsBefore = ERC20(assetToken).balanceOf(address(this));

        // do swap
        ERC20(wrapToken).approve(_router, _wrapTokenAmount);
        (bool success, bytes memory returnData) = _router.call(_calldata);
        require(success, SwapFailed(returnData));

        // check slippage
        uint256 assetsReceived = ERC20(assetToken).balanceOf(address(this)) - assetsBefore;
        uint256 minAssetsOut = convertToAssets(_wrapTokenAmount).mulWadDown(_MAX_SLIPPAGE);
        require(assetsReceived > minAssetsOut, SlippageTooHigh(minAssetsOut, assetsReceived));
    }
}
