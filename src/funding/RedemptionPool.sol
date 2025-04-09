// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {RedemptionQueue} from "@libraries/RedemptionQueue.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

/// @notice This contract is used to manage the redemption queue for a given collateral.
/// @dev Should be inherited by the LiabilityController
/// @dev This contract does not manage any token transfer or burn, it just manages the queue and the pending redemptions.
/// @dev handling tokens MUST be done by the contract inheriting this one.
abstract contract RedemptionPool {
    using RedemptionQueue for RedemptionQueue.RedemptionRequestsQueue;
    using FixedPointMathLib for uint256;

    /// ------------------- ERRORS -------------------
    error FundingAmountZero();
    error EnqueueAmountZero();
    error NoPendingClaims(address _recipient);
    error QueueTooLong();

    /// ------------------- EVENTS -------------------
    event RedemptionQueued(address indexed recipient, uint256 amount);
    event RedemptionPartiallyFunded(address indexed recipient, uint256 amount);
    event RedemptionFunded(address indexed recipient, uint256 amount);
    event RedemptionClaimed(address indexed recipient, uint256 amount);

    /// ------------------- STATE -------------------
    /// @notice the redemption queue
    RedemptionQueue.RedemptionRequestsQueue public queue;

    uint256 public constant MAX_QUEUE_LENGTH = 10000;

    /// @notice mapping from recipient => available claim
    mapping(address => uint256) public userPendingClaims;

    /// @notice total available redemptions
    /// @dev this is the amount of asset (USDC, ETH) that is currently redeemable and should be held by this contract
    uint256 public totalPendingClaims;

    /// @notice total enqueued redemptions
    /// @dev this is the amount of receipt token (iUSD, iETH) that is currently enqueued and waiting to be redeemed
    uint256 public totalEnqueuedRedemptions;

    /// @notice returns the length of the queue
    /// aka the number of ticket waiting to be funded
    function queueLength() public view returns (uint256) {
        return queue.length();
    }

    /// @notice fund the redemption queue. Receipt is iToken (iUSD, iETH), asset is the collateral token (USDC, ETH)
    /// @param _assetAmount the amount to fund, in collateral token
    /// @param _convertReceiptToAssetRatio the ratio to convert receipt token to collateral token, with WAD precision (1e18)
    /// @return (uint256, uint256) the first is the amount not used to fund the queue (0 if the queue fully absorbed the amount),
    /// the second is the amount of receipt token to burn because we have funded the tickets for this amount of receiptToken
    function _fundRedemptionQueue(uint256 _assetAmount, uint256 _convertReceiptToAssetRatio)
        internal
        returns (uint256, uint256)
    {
        require(_assetAmount > 0, FundingAmountZero());
        uint256 totalEnqueuedRedemptionsBefore = totalEnqueuedRedemptions;
        // amount can be way higher than the amount being asked (total value of all tickets in the queue)
        uint256 remainingAssets = _assetAmount;
        while (remainingAssets > 0 && !queue.empty()) {
            RedemptionQueue.RedemptionRequest memory request = queue.front();
            // compute amount of asset to be redeemed by the amount of receipt token
            uint256 assetRequired = uint256(request.amount).mulWadDown(_convertReceiptToAssetRatio);
            uint256 receiptToBurn = request.amount;
            if (assetRequired > remainingAssets) {
                assetRequired = remainingAssets;
                // here 'receiptToBurn' is the amount of remaining assets converted to receipt token using the ratio
                receiptToBurn = remainingAssets.divWadDown(_convertReceiptToAssetRatio);
                uint96 newReceiptAmount = request.amount - uint96(receiptToBurn);
                queue.updateFront(newReceiptAmount);

                emit RedemptionPartiallyFunded(request.recipient, remainingAssets);
            } else {
                queue.popFront();
                emit RedemptionFunded(request.recipient, assetRequired);
            }

            userPendingClaims[request.recipient] += assetRequired;
            totalPendingClaims += assetRequired;
            remainingAssets -= assetRequired;
            totalEnqueuedRedemptions -= receiptToBurn;
        }

        // the amount of receipt to burn is the difference between the total enqueued redemptions before and after the funding
        // if before we had 100 iUSD in the enqueued redemptions and after the funding we have 75 iUSD,
        // it means that 25 iUSD have been funded and thus 25 iUSD should be burned
        uint256 receiptAmountToBurn = totalEnqueuedRedemptionsBefore - totalEnqueuedRedemptions;
        return (remainingAssets, receiptAmountToBurn);
    }

    /// @notice claim the redemption for a given recipient
    /// @param _recipient the recipient of the redemption
    /// @return the amount of redemption claimed
    function _claimRedemption(address _recipient) internal returns (uint256) {
        uint256 amount = userPendingClaims[_recipient];
        require(amount > 0, NoPendingClaims(_recipient));

        userPendingClaims[_recipient] = 0;
        totalPendingClaims -= amount;

        emit RedemptionClaimed(_recipient, amount);
        return amount;
    }

    /// @notice enqueue a redemption request
    /// @param _recipient the recipient of the redemption
    /// @param _amount the amount of receiptToken to redeem
    function _enqueue(address _recipient, uint256 _amount) internal {
        // we limit the queue length to avoid possible out of gas exceptions when funding the queue
        // mainly a risk with griefing (stuffing the queue with a lot of small redemptions)
        // in case of griefing, the queue will be filled up to the max length, and any new enqueue will be rejected
        // in this case, we'll just have to fund the redemption queue to empty the queue (without risking an out of gas exception)
        // and then any new redemption request will be accepted
        require(queue.length() < MAX_QUEUE_LENGTH, QueueTooLong());
        require(_amount > 0, EnqueueAmountZero());
        totalEnqueuedRedemptions += _amount;
        queue.pushBack(RedemptionQueue.RedemptionRequest({amount: uint96(_amount), recipient: _recipient}));
        emit RedemptionQueued(_recipient, _amount);
    }
}
