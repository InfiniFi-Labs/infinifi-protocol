// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapData, TokenInput, TokenOutput, ApproxParams, LimitOrderData} from "@pendle/interfaces/IPAllActionV3.sol";

/// Set of utils to help work with Pendle Router
library PendleStructGen {
    /// @notice create a simple TokenInput struct without using any aggregators.
    function createTokenInputStruct(address tokenIn, uint256 netTokenIn) internal pure returns (TokenInput memory) {
        SwapData memory emptySwap;
        return TokenInput({
            tokenIn: tokenIn,
            netTokenIn: netTokenIn,
            tokenMintSy: tokenIn,
            pendleSwap: address(0),
            swapData: emptySwap
        });
    }

    /// @notice create a simple TokenOutput struct without using any aggregators.
    function createTokenOutputStruct(address tokenOut, uint256 minTokenOut)
        internal
        pure
        returns (TokenOutput memory)
    {
        SwapData memory emptySwap;
        return TokenOutput({
            tokenOut: tokenOut,
            minTokenOut: minTokenOut,
            tokenRedeemSy: tokenOut,
            pendleSwap: address(0),
            swapData: emptySwap
        });
    }

    /// @notice DefaultApprox means no off-chain preparation is involved, more gas consuming (~ 180k gas)
    function createDefaultApprox() internal pure returns (ApproxParams memory) {
        return ApproxParams(0, type(uint256).max, 0, 256, 1e14);
    }

    function createEmptyLimitOrder() internal pure returns (LimitOrderData memory emptyLimit) {}
}
