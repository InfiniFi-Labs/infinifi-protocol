// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";

import {IStandardizedYield} from "@pendle/interfaces/IPAllActionV3.sol";

/// @title Pendle SY Farm
/// @notice Use the SY token's capacity to convert between in & out tokens.
/// This contract does not hold any Pendle tokens, it only use them to perform conversions.
contract PendleSYFarm is MultiAssetFarmV2, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    error InvalidToken(address token);

    IStandardizedYield public immutable sy;

    uint256 public immutable duration;

    constructor(address _core, address _assetToken, address _accounting, address _sy, uint256 _duration)
        MultiAssetFarmV2(_core, _assetToken, _accounting)
    {
        sy = IStandardizedYield(_sy);
        duration = _duration;

        _enableAsset(_assetToken);

        address[] memory tokensIn = sy.getTokensIn();
        for (uint256 i = 0; i < tokensIn.length; i++) {
            _enableAsset(tokensIn[i]);
        }

        address[] memory tokensOut = sy.getTokensOut();
        for (uint256 i = 0; i < tokensOut.length; i++) {
            _enableAsset(tokensOut[i]);
        }

        maxSlippage = 0.999e18; // default: max 10bps
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + duration;
    }

    function previewSwap(address _tokenIn, address _tokenOut, uint256 _amountIn) external view returns (uint256) {
        uint256 syReceived = sy.previewDeposit(_tokenIn, _amountIn);
        uint256 amountOut = sy.previewRedeem(_tokenOut, syReceived);
        return amountOut;
    }

    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        // check that the token in & our are different
        require(_tokenIn != _tokenOut, InvalidToken(_tokenIn));

        // check that the token out still has a valid oracle
        require(isAssetSupported(_tokenOut), InvalidToken(_tokenOut));

        // cross-check slippage with our oracles, do not fully rely on the SY
        uint256 minTokenOut = convert(_tokenIn, _tokenOut, _amountIn).mulWadDown(maxSlippage);

        // swap into SY
        if (_amountIn > 0) {
            IERC20(_tokenIn).forceApprove(address(sy), _amountIn);
            uint256 minSyOut = sy.previewDeposit(_tokenIn, _amountIn).mulWadDown(maxSlippage);
            sy.deposit(address(this), _tokenIn, _amountIn, minSyOut);
        }

        // swap out of SY
        uint256 syBalance = sy.balanceOf(address(this));
        sy.redeem(address(this), syBalance, _tokenOut, minTokenOut, false);
    }
}
