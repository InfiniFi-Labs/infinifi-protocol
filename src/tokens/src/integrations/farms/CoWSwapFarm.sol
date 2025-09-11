// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GPv2Settlement} from "@cowprotocol/contracts/GPv2Settlement.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {GPv2Order, IERC20 as ICoWERC20} from "@cowprotocol/contracts/libraries/GPv2Order.sol";

import {IOracle} from "@interfaces/IOracle.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";
import {CoWSwapFarmBase} from "@integrations/farms/CoWSwapFarmBase.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title CoWSwap Farm
/// @notice This contract is used to deploy assets using CoW Swap limit orders. Funds are deposited in the farm
/// in assetTokens, and are then swapped into and out of wrapTokens using CoW Swap.
/// @dev This farm is considered illiquid as swapping in & out will incur slippage.
contract CoWSwapFarm is CoWSwapFarmBase, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// @notice Reference to the wrap token (to which assetTokens are swapped).
    address public immutable wrapToken;

    /// @notice Duration of the farm (maturity() returns block.timestamp + duration)
    /// @dev This can be set to 0, treating the farm as a liquid farm, however there will be
    /// slippage to swap in & out of the farm, which acts as some kind of entrance & exit fees.
    /// Consider setting a duration that is at least long enough to earn yield that covers the swap fees.
    uint256 private immutable duration;

    constructor(
        address _core,
        address _assetToken,
        address _wrapToken,
        address _accounting,
        uint256 _duration,
        address _settlementContract,
        address _vaultRelayer
    ) CoWSwapFarmBase(_settlementContract, _vaultRelayer) MultiAssetFarm(_core, _assetToken, _accounting) {
        wrapToken = _wrapToken;
        duration = _duration;

        // set default slippage tolerance to 99.5%
        maxSlippage = 0.995e18;
    }

    function assetTokens() public view override returns (address[] memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = assetToken;
        tokens[1] = wrapToken;
        return tokens;
    }

    function isAssetSupported(address _asset) public view override returns (bool) {
        return _asset == assetToken || _asset == wrapToken;
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

    /// @notice Converts a number of wrapTokens to assetTokens based on oracle rates.
    function convertToAssets(uint256 _wrapTokenAmount) public view returns (uint256) {
        return convert(wrapToken, assetToken, _wrapTokenAmount);
    }

    /// @notice Converts a number of assetTokens to wrapTokens based on oracle rates.
    function convertToWrapTokens(uint256 _assetsAmount) public view returns (uint256) {
        return convert(assetToken, wrapToken, _assetsAmount);
    }

    /// @notice Wraps assetTokens as wrapTokens.
    function signWrapOrder(uint256 _assetsIn, uint256 _minWrapTokensOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        return _checkSwapApproveAndSignOrder(assetToken, wrapToken, _assetsIn, _minWrapTokensOut, maxSlippage);
    }

    /// @notice Unwraps wrapTokens to assetTokens.
    function signUnwrapOrder(uint256 _wrapTokensIn, uint256 _minAssetsOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        return _checkSwapApproveAndSignOrder(wrapToken, assetToken, _wrapTokensIn, _minAssetsOut, maxSlippage);
    }
}
