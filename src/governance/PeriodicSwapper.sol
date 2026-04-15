// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SwapFarmV2} from "@integrations/farms/SwapFarmV2.sol";
import {LockingController} from "@locking/LockingController.sol";

/// @title PeriodicSwapper
/// @notice Contract to periodically swap tokens
/// @dev Based on SwapFarmV2 contract to maximize code reuse, but this is not meant to be
/// a farm added to the registry, since this contract is not holding protocol funds.
/// @dev Needs FINANCE_MANAGER role to deposit rewards into the locking module.
contract PeriodicSwapper is SwapFarmV2 {
    using SafeERC20 for IERC20;

    address public immutable lockingController;
    address public immutable sellToken;
    address public immutable buyToken;

    error NotImplemented();
    error InvalidSellToken(address _expected, address _actual);
    error InvalidBuyToken(address _expected, address _actual);

    constructor(
        address _core,
        address _lockingController,
        address _assetToken,
        address _sellToken,
        address _buyToken,
        address _accounting,
        address _settlementContract,
        address _vaultRelayer
    ) SwapFarmV2(_core, _assetToken, _accounting, _settlementContract, _vaultRelayer) {
        lockingController = _lockingController;
        sellToken = _sellToken;
        buyToken = _buyToken;

        // ensure the buy token can be distributed as rewards on the lockingController
        address lockingReceiptToken = LockingController(_lockingController).receiptToken();
        require(_buyToken == lockingReceiptToken, InvalidBuyToken(lockingReceiptToken, _buyToken));
    }

    function distribute() external whenNotPaused {
        uint256 balance = IERC20(buyToken).balanceOf(address(this));
        if (balance == 0) return;

        IERC20(buyToken).forceApprove(lockingController, balance);
        LockingController(lockingController).depositRewards(balance);
    }

    /// Overrides to enforce that tokenIn == sellToken
    function _checkSlippage(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOut)
        internal
        view
        override
    {
        require(_tokenIn == sellToken, InvalidSellToken(sellToken, _tokenIn));
        super._checkSlippage(_tokenIn, _tokenOut, _amountIn, _amountOut);
    }

    function _validateSwap(CoWSwapData memory _data) internal view override {
        require(_data.tokenIn == sellToken, InvalidSellToken(sellToken, _data.tokenIn));
        super._validateSwap(_data);
    }

    /// ------------------------------------------------------------------------------
    /// Farm functions overrides to make sure the contract cannot leak funds earmarked
    /// for governance token holders to the protocol even if it is added to the
    /// registry by mistake.
    /// ------------------------------------------------------------------------------
    function assets() public pure override returns (uint256) {
        return 0;
    }

    function deposit() external virtual override {
        revert NotImplemented();
    }

    function withdraw(uint256, address) external virtual override {
        revert NotImplemented();
    }

    function withdrawSecondaryAsset(address, uint256, address) external virtual override {
        revert NotImplemented();
    }
}
