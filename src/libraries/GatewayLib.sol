// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {IERC20, ERC4626, Math} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {EpochLib} from "@libraries/EpochLib.sol";
import {YieldSharingV2} from "@finance/YieldSharingV2.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {IInfiniFiGateway} from "@interfaces/IInfiniFiGateway.sol";
import {LockingController, MintController, RedeemController} from "@gateway/InfiniFiGatewayV1.sol";

/// RT - Receipt Token
/// ST - Staked Token
/// LPT - Locked Position Token
library GatewayLib {
    using Math for uint256;
    using FixedPointMathLib for uint256;

    error NoStakedToken();
    error NoReceiptToken();
    error NoLockedPositionToken(uint256 _unwindingEpochs);

    /// ----------------------------------------------------------------------------
    /// Token Getters
    /// ----------------------------------------------------------------------------

    function lockedPositionToken(IInfiniFiGateway _gateway, uint256 _unwindingEpochs)
        internal
        view
        returns (address lpToken)
    {
        lpToken = LockingController(_gateway.getAddress("lockingController")).shareToken(uint32(_unwindingEpochs));
        require(lpToken != address(0), NoLockedPositionToken(_unwindingEpochs));
    }

    function stakedToken(IInfiniFiGateway _gateway) internal view returns (address _stakedToken) {
        _stakedToken = _gateway.getAddress("stakedToken");
        require(_stakedToken != address(0), NoStakedToken());
    }

    function receiptToken(IInfiniFiGateway _gateway) internal view returns (address _receiptToken) {
        _receiptToken = _gateway.getAddress("receiptToken");
        require(_receiptToken != address(0), NoReceiptToken());
    }

    /// ----------------------------------------------------------------------------
    /// Conversion methods
    /// ----------------------------------------------------------------------------

    /// @notice Converts _amountIn of receipt tokens to staked tokens
    /// @param _gateway reference
    /// @param _amountIn receipt token amount
    function receiptToStaked(IInfiniFiGateway _gateway, uint256 _amountIn) internal view returns (uint256) {
        if (_amountIn == 0) return 0;

        address yieldSharing = _gateway.getAddress("yieldSharing");
        uint256 totalAssets = ERC4626(stakedToken(_gateway)).totalAssets() + YieldSharingV2(yieldSharing).vested();
        uint256 totalSupply = ERC4626(stakedToken(_gateway)).totalSupply();

        return _amountIn.mulDiv(totalSupply + 1, totalAssets + 1, Math.Rounding.Floor);
    }

    /// @notice Converts _amountIn of staked tokens to receipt tokens
    /// @param _gateway reference
    /// @param _amountIn staked token amount
    function stakedToReceipt(IInfiniFiGateway _gateway, uint256 _amountIn) internal view returns (uint256) {
        if (_amountIn == 0) return 0;

        address yieldSharing = _gateway.getAddress("yieldSharing");
        uint256 totalAssets = ERC4626(stakedToken(_gateway)).totalAssets() + YieldSharingV2(yieldSharing).vested();
        uint256 totalSupply = ERC4626(stakedToken(_gateway)).totalSupply();

        return _amountIn.mulDiv(totalAssets + 1, totalSupply + 1, Math.Rounding.Floor);
    }

    /// @notice Converts _amountIn of receipt tokens to amount of locked position tokens
    /// @param _gateway gateway reference
    /// @param _amountIn amount of receipt tokens
    /// @param _unwindingEpochs plain number of unwinding epochs [1,2,3,etc]
    function receiptToLocked(IInfiniFiGateway _gateway, uint256 _amountIn, uint256 _unwindingEpochs)
        internal
        view
        returns (uint256)
    {
        if (_amountIn == 0) return 0;
        LockingController lockingController = LockingController(_gateway.getAddress("lockingController"));

        (address lptAddress, uint256 totalReceiptTokens,) = lockingController.buckets(uint32(_unwindingEpochs));
        uint256 totalShares = IERC20(lptAddress).totalSupply();
        if (totalShares == 0) return _amountIn;
        return _amountIn.mulDivDown(totalShares, totalReceiptTokens);
    }

    /// @notice How many receipt tokens we get when exchanged for locked position token _amountIn
    /// @dev It is not possible to do this conversion right away
    /// however it is a useful reference for getting the current lpt value
    /// @param _gateway gateway reference
    /// @param _amountIn amount of locked position tokens
    /// @param _unwindingEpochs plain number of unwinding epochs [1,2,3,etc]
    function lockedToReceipt(IInfiniFiGateway _gateway, uint256 _amountIn, uint256 _unwindingEpochs)
        internal
        view
        returns (uint256)
    {
        if (_amountIn == 0) return 0;
        LockingController lockingController = LockingController(_gateway.getAddress("lockingController"));
        (address lptAddress, uint256 totalReceiptTokens,) = lockingController.buckets(uint32(_unwindingEpochs));
        uint256 totalShares = IERC20(lptAddress).totalSupply();
        if (totalShares == 0) return _amountIn;
        return _amountIn.mulDivDown(totalReceiptTokens, totalShares);
    }

    /// @notice Converts _amountIn of asset token to receipt token
    /// @param _gateway reference
    /// @param _amountIn amount of asset tokens
    function assetToReceipt(IInfiniFiGateway _gateway, uint256 _amountIn) internal view returns (uint256) {
        if (_amountIn == 0) return 0;
        return MintController(_gateway.getAddress("mintController")).assetToReceipt(_amountIn);
    }

    /// @notice Converts _amountIn of receipt token to asset token
    /// @param _gateway reference
    /// @param _amountIn amount of receipt tokens
    function receiptToAsset(IInfiniFiGateway _gateway, uint256 _amountIn) internal view returns (uint256) {
        if (_amountIn == 0) return 0;
        return RedeemController(_gateway.getAddress("redeemController")).receiptToAsset(_amountIn);
    }

    /// ----------------------------------------------------------------------------
    /// Unwinding data
    /// ----------------------------------------------------------------------------

    /// @notice returns useful data about user unwinding position
    function unwindingPosition(IInfiniFiGateway _gateway, address _owner, uint256 _startTimestamp)
        internal
        view
        returns (uint256 receiptTokens, bool withdrawable)
    {
        UnwindingModule unwindingModule = UnwindingModule(_gateway.getAddress("unwindingModule"));

        bytes32 unwindingKey = keccak256(abi.encode(_owner, _startTimestamp));
        receiptTokens = unwindingModule.balanceOf(_owner, _startTimestamp);

        (,, uint32 toEpoch,,) = unwindingModule.positions(unwindingKey);
        return (receiptTokens, EpochLib.epoch(block.timestamp) >= toEpoch);
    }
}
