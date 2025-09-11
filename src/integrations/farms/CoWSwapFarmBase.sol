// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GPv2Settlement} from "@cowprotocol/contracts/GPv2Settlement.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {GPv2Order, IERC20 as ICoWERC20} from "@cowprotocol/contracts/libraries/GPv2Order.sol";

import {Farm} from "@integrations/Farm.sol";
import {Accounting} from "@finance/Accounting.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";

/// @title CoWSwap Farm Base
abstract contract CoWSwapFarmBase is MultiAssetFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    event OrderSigned(
        uint256 indexed timestamp, bytes orderUid, GPv2Order.Data order, uint32 validTo, uint256 buyAmount
    );

    error SwapCooldown();
    error InvalidToken(address token);
    error InvalidAmountIn(uint256 amountIn);
    error InvalidAmountOut(uint256 minOut, uint256 provided);

    /// @notice timestamp of last order
    uint256 public lastOrderSignTimestamp = 1;
    /// @notice cooldown period between order signings
    uint256 public constant _SIGN_COOLDOWN = 20 minutes;

    /// @notice address of the GPv2Settlement contract
    address public immutable settlementContract;

    /// @notice address of the GPv2VaultRelayer contract
    address public immutable vaultRelayer;

    constructor(address _settlementContract, address _vaultRelayer) {
        settlementContract = _settlementContract;
        vaultRelayer = _vaultRelayer;
    }

    /// @notice Converts a number of tokens to another token based on oracle rates.
    function convert(address _tokenIn, address _tokenOut, uint256 _amountIn) public view returns (uint256) {
        uint256 tokenInPrice = Accounting(accounting).price(_tokenIn);
        uint256 tokenOutPrice = Accounting(accounting).price(_tokenOut);
        return _amountIn.mulDivDown(tokenInPrice, tokenOutPrice);
    }

    function _checkSwapApproveAndSignOrder(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        uint256 _maxSlippage
    ) internal returns (bytes memory) {
        require(_amountIn > 0 && _amountIn <= IERC20(_tokenIn).balanceOf(address(this)), InvalidAmountIn(_amountIn));
        require(isAssetSupported(_tokenOut), InvalidToken(_tokenOut));

        require(block.timestamp > lastOrderSignTimestamp + _SIGN_COOLDOWN, SwapCooldown());
        lastOrderSignTimestamp = block.timestamp;

        uint256 minOutSlippage = convert(_tokenIn, _tokenOut, _amountIn).mulWadDown(_maxSlippage);
        require(_minAmountOut >= minOutSlippage, InvalidAmountOut(minOutSlippage, _minAmountOut));

        IERC20(_tokenIn).forceApprove(vaultRelayer, _amountIn);
        return _signOrder(_order(_tokenIn, _tokenOut, _amountIn, _minAmountOut));
    }

    function _order(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: ICoWERC20(_tokenIn),
            buyToken: ICoWERC20(_tokenOut),
            receiver: address(this),
            sellAmount: _amountIn,
            buyAmount: _minAmountOut,
            validTo: uint32(block.timestamp + _SIGN_COOLDOWN),
            // keccak256 {"appCode":"infiniFi","version":"1.0.0","metadata":{}}
            appData: 0x3cac71ef99d0dfbf5b937334b5b7ab672b679ba2bbd4d6fe8e0c54a2dab31109,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _signOrder(GPv2Order.Data memory order) internal returns (bytes memory) {
        GPv2Settlement settlement = GPv2Settlement(payable(settlementContract));
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        GPv2Order.packOrderUidParams(orderUid, orderDigest, address(this), order.validTo);
        settlement.setPreSignature(orderUid, true);

        emit OrderSigned(block.timestamp, orderUid, order, order.validTo, order.buyAmount);
        return orderUid;
    }
}
