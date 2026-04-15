// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DoubleEndedQueue} from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";

import {ERC7540} from "@periphery/ERC7540.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {GatewayLib} from "@libraries/GatewayLib.sol";
import {IInfiniFiGateway} from "@interfaces/IInfiniFiGateway.sol";

/// @notice ERC7540 like implementation for locked position tokens
/// @dev Please understand that there are certain limitations:
/// 1. mint, withdraw - There is a decimal precission loss when converting usdc[e6] -> liusd[e18] and these methods should be avoided
/// 2. convertToShares is showing rates reported by the LockingController and not UnwindingModule.
///    concept of shares itself is weird since user does not hold any tokens while unwinding
///    it is recommended to use it specifically for expressing liUSD holdings as USDC
///    it can be used as an input to `mint` function with a slight precission loss
/// 3. Lacks cancellation logic which is a common pitfall in 7540 vaults
/// 4. Allows only single unwinding per block. This can cause frontrunning for DoS. Can be solved by having escrow contracts
contract LPTVault is ERC7540 {
    using GatewayLib for IInfiniFiGateway;
    using SafeERC20 for IERC20;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    event MinRedeemSharesUpdated(uint256 indexed _timestamp, uint256 _minRedeemShares);

    error NoPositions();
    error RedemptionNotClaimable(uint256 timestamp);
    error NoPartialExit(uint256 _sharesExpected, uint256 _sharesProvided);
    error MinimumSharesRequired(uint256 _minimum, uint256 _provided);

    uint256 public minRedeemShares = 10e18;

    uint256 public immutable unwindingEpochs;

    mapping(address controller => DoubleEndedQueue.Bytes32Deque) unwindings;

    constructor(
        address _core,
        address _gateway,
        address _assetToken,
        address _lockedPositionToken,
        uint256 _unwindingEpochs
    ) ERC7540(_core, _gateway, _assetToken, _lockedPositionToken) {
        unwindingEpochs = _unwindingEpochs;
    }

    function setMinRedeemShares(uint256 _minRedeemShares) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        minRedeemShares = _minRedeemShares;
        emit MinRedeemSharesUpdated(block.timestamp, _minRedeemShares);
    }

    function convertToShares(uint256 _assets) public view override returns (uint256) {
        if (_assets == 0) return 0;
        uint256 receiptAmount = gateway.assetToReceipt(_assets);
        return gateway.receiptToLocked(receiptAmount, unwindingEpochs);
    }

    function convertToAssets(uint256 _shares) public view override returns (uint256) {
        if (_shares == 0) return 0;
        uint256 receiptAmount = gateway.lockedToReceipt(_shares, unwindingEpochs);
        return gateway.receiptToAsset(receiptAmount);
    }

    function pendingRedeemRequest(uint256, address _controller) public view override returns (uint256 shares) {
        DoubleEndedQueue.Bytes32Deque storage _unwindings = unwindings[_controller];
        uint256 unwindingsLength = _unwindings.length();
        if (unwindingsLength == 0) return 0;

        for (uint256 i = 0; i < unwindingsLength; i++) {
            uint256 unwindingTimestamp = uint256(_unwindings.at(i));
            (uint256 receiptTokens, bool withdrawable) = gateway.unwindingPosition(address(this), unwindingTimestamp);
            // skip first item if it is withdrawable as it is now in `claimable` state
            if (withdrawable && i == 0) continue;
            shares += gateway.receiptToLocked(receiptTokens, unwindingEpochs);
        }
    }

    function claimableRedeemRequest(uint256, address _controller) public view override returns (uint256 shares) {
        DoubleEndedQueue.Bytes32Deque storage _unwindings = unwindings[_controller];
        if (_unwindings.length() == 0) return 0;

        (uint256 receiptTokens, bool withdrawable) =
            gateway.unwindingPosition(address(this), uint256(_unwindings.at(0)));
        return withdrawable ? gateway.receiptToLocked(receiptTokens, unwindingEpochs) : 0;
    }

    /// @notice Starts unwinding on a specific position.
    /// Note that this starts unwinding the given amount of `_shares`
    /// and will only allow redeem of the exact amount passed along here
    /// @dev Unwinding Module will revert if there is an attempt to unwind in the same block with UserUnwindingInProgress
    function _requestRedeem(uint256 _shares, address _controller, address _owner)
        internal
        override
        returns (uint256 requestId)
    {
        require(_shares >= minRedeemShares, MinimumSharesRequired(minRedeemShares, _shares));
        unwindings[_controller].pushBack(bytes32(block.timestamp));
        IERC20(share).safeTransferFrom(_owner, address(this), _shares);
        IERC20(share).forceApprove(address(gateway), _shares);
        gateway.startUnwinding(_shares, uint32(unwindingEpochs));
        return 0;
    }

    function _deposit(uint256 _assets, address _receiver, address _controller)
        internal
        override
        returns (uint256 shares)
    {
        deposits[_controller] -= _assets;
        IERC20(asset).forceApprove(address(gateway), _assets);
        uint256 lpTokenBalance = balanceOf(address(_receiver));
        gateway.mintAndLock(address(_receiver), _assets, uint32(unwindingEpochs));
        return balanceOf(address(_receiver)) - lpTokenBalance;
    }

    function _withdraw(uint256 _assets, address _receiver, address _controller)
        internal
        override
        returns (uint256 shares)
    {
        DoubleEndedQueue.Bytes32Deque storage _unwindings = unwindings[_controller];
        require(_unwindings.length() > 0, NoPositions());

        uint256 requiredSharesOut = claimableRedeemRequest(0, _controller);

        uint256 expectedAssetsOut = convertToAssets(requiredSharesOut);
        require(expectedAssetsOut == _assets, NoPartialExit(expectedAssetsOut, _assets));

        uint256 unwindingTimestamp = uint256(_unwindings.popFront());
        (uint256 receiptTokens, bool withdrawable) = gateway.unwindingPosition(address(this), unwindingTimestamp);
        require(withdrawable, RedemptionNotClaimable(unwindingTimestamp));

        gateway.withdraw(unwindingTimestamp);
        uint256 minAssetsOut = gateway.receiptToAsset(receiptTokens);
        IERC20(gateway.receiptToken()).forceApprove(address(gateway), receiptTokens);
        gateway.redeem(_receiver, receiptTokens, minAssetsOut);
        return requiredSharesOut;
    }

    function _redeem(uint256 _shares, address _controller, address _receiver)
        internal
        override
        returns (uint256 assetsOut)
    {
        DoubleEndedQueue.Bytes32Deque storage _unwindings = unwindings[_controller];
        require(_unwindings.length() > 0, NoPositions());
        uint256 expectedAssetsOut = convertToAssets(claimableRedeemRequest(0, _controller));
        require(
            convertToAssets(_shares) == expectedAssetsOut,
            NoPartialExit(claimableRedeemRequest(0, _controller), _shares)
        );

        uint256 unwindingTimestamp = uint256(_unwindings.popFront());
        (uint256 receiptTokens, bool withdrawable) = gateway.unwindingPosition(address(this), unwindingTimestamp);
        require(withdrawable, RedemptionNotClaimable(unwindingTimestamp));

        gateway.withdraw(unwindingTimestamp);
        uint256 minAssetsOut = gateway.receiptToAsset(receiptTokens);
        IERC20(gateway.receiptToken()).forceApprove(address(gateway), receiptTokens);
        return gateway.redeem(_receiver, receiptTokens, minAssetsOut);
    }
}
