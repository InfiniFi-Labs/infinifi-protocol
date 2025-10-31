// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GPv2Settlement} from "@cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2Order, IERC20 as ICoWERC20} from "@cowprotocol/contracts/libraries/GPv2Order.sol";

/// @title Raw CoWSwap Base
/// Allows implementations to submit sell orders to cowswap
abstract contract CoWSwapBase {
    using SafeERC20 for IERC20;

    struct CoWSwapData {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 maxSlippage;
    }

    event OrderSigned(
        uint256 indexed timestamp, bytes orderUid, GPv2Order.Data order, uint32 validTo, uint256 buyAmount
    );

    error SwapCooldown();
    error InvalidToken(address token);
    error InvalidAmountIn(uint256 amountIn);
    error InvalidAmountOut(uint256 minOut, uint256 provided);

    /// @notice cooldown period between order signings
    uint256 public constant _SIGN_COOLDOWN = 20 minutes;

    /// @notice timestamp of last order
    uint256 public lastOrderSignTimestamp = 1;

    /// @notice if orders can not be submitted inside _SIGN_COOLDOWN window
    bool public immutable enforceCooldown;

    /// @notice address of the GPv2Settlement contract
    address public immutable settlementContract;

    /// @notice address of the GPv2VaultRelayer contract
    address public immutable vaultRelayer;

    constructor(address _settlementContract, address _vaultRelayer, bool _enforceCooldown) {
        settlementContract = _settlementContract;
        vaultRelayer = _vaultRelayer;
        enforceCooldown = _enforceCooldown;
    }

    function _validateSwap(CoWSwapData memory _data) internal virtual;

    function _checkSwapApproveAndSignOrder(CoWSwapData memory _data) internal returns (bytes memory) {
        if (enforceCooldown) {
            require(block.timestamp > lastOrderSignTimestamp + _SIGN_COOLDOWN, SwapCooldown());
            lastOrderSignTimestamp = block.timestamp;
        }

        _validateSwap(_data);
        IERC20(_data.tokenIn).forceApprove(vaultRelayer, _data.amountIn);
        return _signOrder(_order(_data));
    }

    function _order(CoWSwapData memory _data) private view returns (GPv2Order.Data memory) {
        return GPv2Order.Data({
            sellToken: ICoWERC20(_data.tokenIn),
            buyToken: ICoWERC20(_data.tokenOut),
            receiver: address(this),
            sellAmount: _data.amountIn,
            buyAmount: _data.minAmountOut,
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

    function _signOrder(GPv2Order.Data memory order) private returns (bytes memory) {
        GPv2Settlement settlement = GPv2Settlement(payable(settlementContract));
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        GPv2Order.packOrderUidParams(orderUid, orderDigest, address(this), order.validTo);
        settlement.setPreSignature(orderUid, true);

        emit OrderSigned(block.timestamp, orderUid, order, order.validTo, order.buyAmount);
        return orderUid;
    }
}
