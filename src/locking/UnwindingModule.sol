// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {LockingController} from "@locking/LockingController.sol";

struct UnwindingPosition {
    uint256 shares; // shares of receiptTokens of the position
    uint32 fromEpoch; // epoch when the position started unwinding
    uint32 toEpoch; // epoch when the position will end unwinding
    uint256 fromRewardWeight; // reward weight at the start of the unwinding
    uint256 rewardWeightDecrease; // reward weight decrease per epoch between fromEpoch and toEpoch
}

struct GlobalPoint {
    uint32 epoch; // epoch of the global point
    uint256 totalRewardWeight; // total reward weight in the contract
    uint256 totalRewardWeightDecrease; // total reward weight decrease per epoch
    uint256 rewardShares; // number of receiptTokens rewards distributed on the epoch (stored as shares)
}

contract UnwindingModule is CoreControlled {
    using EpochLib for uint256;
    using FixedPointMathLib for uint256;

    error TransferFailed();
    error UserNotUnwinding();
    error UserUnwindingNotStarted();
    error UserUnwindingInprogress();
    error InvalidUnwindingEpochs(uint32 value);

    /// @notice address of the receipt token
    address public immutable receiptToken;

    /// ----------------------------------------------------------------------------
    /// STATE
    /// ----------------------------------------------------------------------------

    /// @notice total shares of locked tokens in the contract
    uint256 public totalShares;

    /// @notice total amount of receipt tokens in the contract, excluding donations
    uint256 public totalReceiptTokens;

    /// @notice slashing index, starts at 1e18 and decreases every time there is a slash
    uint256 public slashIndex = FixedPointMathLib.WAD;

    /// @notice mapping of unwinding positions
    mapping(bytes32 id => UnwindingPosition position) public positions;

    /// @notice last global point's epoch for direct access
    uint32 public lastGlobalPointEpoch;

    /// @notice mapping of epoch to global point
    mapping(uint32 epoch => GlobalPoint point) public globalPoints;

    /// @notice mapping of epoch to positive slope changes
    mapping(uint32 epoch => uint256 increase) public rewardWeightIncreases;

    /// @notice mapping of epoch to negative slope changes
    mapping(uint32 epoch => uint256 decrease) public rewardWeightDecreases;

    /// ----------------------------------------------------------------------------
    /// CONSTRUCTOR
    /// ----------------------------------------------------------------------------

    constructor(address _core, address _receiptToken) CoreControlled(_core) {
        receiptToken = _receiptToken;

        uint32 currentEpoch = uint32(block.timestamp.epoch());
        lastGlobalPointEpoch = currentEpoch;
        globalPoints[currentEpoch] =
            GlobalPoint({epoch: currentEpoch, totalRewardWeight: 0, totalRewardWeightDecrease: 0, rewardShares: 0});
    }

    /// ----------------------------------------------------------------------------
    /// READ METHODS
    /// ----------------------------------------------------------------------------

    /// @notice returns the current reward weight
    function totalRewardWeight() external view returns (uint256) {
        GlobalPoint memory point = _getLastGlobalPoint();
        return point.totalRewardWeight.mulWadDown(slashIndex);
    }

    /// @notice returns the balance of a user
    function balanceOf(address _user, uint256 _startUnwindingTimestamp) public view returns (uint256) {
        UnwindingPosition memory position = positions[_unwindingId(_user, _startUnwindingTimestamp)];
        if (position.fromEpoch == 0) return 0;

        // apply rewards
        GlobalPoint memory globalPoint;
        uint256 userRewardWeight = position.fromRewardWeight;
        uint256 userShares = position.shares;
        uint256 currentEpoch = block.timestamp.epoch();
        for (uint32 epoch = position.fromEpoch - 1; epoch <= currentEpoch; epoch++) {
            // if a real global point exists, use it
            // there is always a real global point for the position.fromEpoch,
            // because a global point is saved to storage when a position starts unwinding.
            GlobalPoint memory epochGlobalPoint = globalPoints[epoch];
            if (epochGlobalPoint.epoch != 0) globalPoint = epochGlobalPoint;

            // add shares to the user for their earned rewards
            // note that the userRewardWeight is not increased proportionally to the rewards
            // received, which means that rewards are not compounding during unwinding.
            userShares += globalPoint.rewardShares.mulDivDown(userRewardWeight, globalPoint.totalRewardWeight);

            // prepare a virtual global point for the next iteration
            globalPoint.totalRewardWeightDecrease -= rewardWeightIncreases[epoch];
            globalPoint.totalRewardWeightDecrease += rewardWeightDecreases[epoch];
            globalPoint.totalRewardWeight -= globalPoint.totalRewardWeightDecrease;
            globalPoint.epoch = epoch + 1;
            globalPoint.rewardShares = 0;

            // if during the position's unwinding period, the reward weight should decrease
            if (epoch >= position.fromEpoch && epoch < position.toEpoch) {
                userRewardWeight -= position.rewardWeightDecrease;
            }
        }

        return _sharesToAmount(userShares);
    }

    /// ----------------------------------------------------------------------------
    /// WRITE METHODS
    /// ----------------------------------------------------------------------------

    /// @notice Start unwinding a locked position
    function startUnwinding(address _user, uint256 _receiptTokens, uint32 _unwindingEpochs, uint256 _rewardWeight)
        external
        onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER)
    {
        bytes32 id = _unwindingId(_user, block.timestamp);
        require(positions[id].fromEpoch == 0, UserUnwindingInprogress());

        uint256 rewardWeight = _rewardWeight.divWadDown(slashIndex);
        uint256 targetRewardWeight = _receiptTokens.divWadDown(slashIndex);
        uint256 totalDecrease = rewardWeight - targetRewardWeight;
        uint256 rewardWeightDecrease = totalDecrease / uint256(_unwindingEpochs);
        uint256 roundingLoss = totalDecrease - (rewardWeightDecrease * uint256(_unwindingEpochs));
        rewardWeight -= roundingLoss;

        uint32 nextEpoch = uint32(block.timestamp.nextEpoch());
        uint256 newShares = _amountToShares(_receiptTokens);
        uint32 endEpoch = nextEpoch + _unwindingEpochs;
        positions[id] = UnwindingPosition({
            shares: newShares,
            fromEpoch: nextEpoch,
            toEpoch: endEpoch,
            fromRewardWeight: rewardWeight,
            rewardWeightDecrease: rewardWeightDecrease
        });

        totalShares += newShares;
        totalReceiptTokens += _receiptTokens;

        GlobalPoint memory point = _getLastGlobalPoint();
        point.totalRewardWeight += rewardWeight;
        _updateGlobalPoint(point);
        rewardWeightDecreases[nextEpoch] += rewardWeightDecrease;
        rewardWeightIncreases[endEpoch] += rewardWeightDecrease;
    }

    /// @notice Cancel an ongoing unwinding
    function cancelUnwinding(address _user, uint256 _startUnwindingTimestamp, uint32 _newUnwindingEpochs)
        external
        onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER)
    {
        uint32 currentEpoch = uint32(block.timestamp.epoch());
        bytes32 id = _unwindingId(_user, _startUnwindingTimestamp);
        UnwindingPosition memory position = positions[id];
        require(position.toEpoch > 0 && currentEpoch < position.toEpoch, UserNotUnwinding());
        require(currentEpoch >= position.fromEpoch, UserUnwindingNotStarted());

        uint256 userBalance = balanceOf(_user, _startUnwindingTimestamp);
        uint256 elapsedEpochs = currentEpoch - position.fromEpoch;
        uint256 userRewardWeight = position.fromRewardWeight - elapsedEpochs * position.rewardWeightDecrease;

        {
            // scope some state writing to avoid stack too deep
            GlobalPoint memory point = _getLastGlobalPoint();
            point.totalRewardWeightDecrease -= position.rewardWeightDecrease;
            point.totalRewardWeight -= userRewardWeight;
            _updateGlobalPoint(point);
            rewardWeightIncreases[position.toEpoch] -= position.rewardWeightDecrease;

            delete positions[id];

            totalShares -= position.shares;
            totalReceiptTokens -= userBalance;
        }

        uint32 remainingEpochs = position.toEpoch - currentEpoch;
        require(_newUnwindingEpochs >= remainingEpochs, InvalidUnwindingEpochs(_newUnwindingEpochs));
        IERC20(receiptToken).approve(msg.sender, userBalance);
        LockingController(msg.sender).createPosition(userBalance, _newUnwindingEpochs, _user);
    }

    /// @notice Withdraw after an unwinding period has completed
    function withdraw(uint256 _startUnwindingTimestamp, address _owner)
        external
        onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER)
    {
        uint32 currentEpoch = uint32(block.timestamp.epoch());
        bytes32 id = _unwindingId(_owner, _startUnwindingTimestamp);
        UnwindingPosition memory position = positions[id];
        require(position.toEpoch > 0, UserNotUnwinding());
        require(currentEpoch >= position.toEpoch, UserUnwindingInprogress());

        uint256 userBalance = balanceOf(_owner, _startUnwindingTimestamp);
        uint256 userRewardWeight =
            position.fromRewardWeight - (position.toEpoch - position.fromEpoch) * position.rewardWeightDecrease;
        delete positions[id];

        GlobalPoint memory point = _getLastGlobalPoint();
        point.totalRewardWeight -= userRewardWeight;
        _updateGlobalPoint(point);

        totalShares -= position.shares;
        totalReceiptTokens -= userBalance;

        require(IERC20(receiptToken).transfer(_owner, userBalance), TransferFailed());
    }

    /// ----------------------------------------------------------------------------
    /// INTERNAL UTILS
    /// ----------------------------------------------------------------------------

    function _unwindingId(address _user, uint256 _blockTimestamp) internal pure returns (bytes32) {
        return keccak256(abi.encode(_user, _blockTimestamp));
    }

    function _amountToShares(uint256 _amount) internal view returns (uint256) {
        uint256 _totalReceiptTokens = totalReceiptTokens;
        return _totalReceiptTokens == 0 ? _amount : _amount.mulDivDown(totalShares, _totalReceiptTokens);
    }

    function _sharesToAmount(uint256 _shares) internal view returns (uint256) {
        if (_shares == 0) return 0;
        return _shares.mulDivDown(totalReceiptTokens, totalShares);
    }

    function _getLastGlobalPoint() internal view returns (GlobalPoint memory) {
        GlobalPoint memory point = globalPoints[lastGlobalPointEpoch];
        // apply slope changes
        uint32 currentEpoch = uint32(block.timestamp.epoch());
        for (uint32 epoch = point.epoch; epoch < currentEpoch; epoch++) {
            point.totalRewardWeightDecrease -= rewardWeightIncreases[epoch];
            point.totalRewardWeightDecrease += rewardWeightDecreases[epoch];
            point.totalRewardWeight -= point.totalRewardWeightDecrease;
            point.epoch = epoch + 1;
            point.rewardShares = 0;
        }
        return point;
    }

    function _updateGlobalPoint(GlobalPoint memory point) internal {
        globalPoints[point.epoch] = point;
        lastGlobalPointEpoch = point.epoch;
    }

    /// ----------------------------------------------------------------------------
    /// REWARDS MANAGEMENT WRITE METHODS
    /// ----------------------------------------------------------------------------

    function depositRewards(uint256 _amount) external onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        if (_amount == 0) return;

        GlobalPoint memory point = _getLastGlobalPoint();
        uint256 rewardShares = _amountToShares(_amount);
        point.rewardShares += rewardShares;
        _updateGlobalPoint(point);

        totalShares += rewardShares;
        totalReceiptTokens += _amount;
    }

    function applyLosses(uint256 _amount) external onlyCoreRole(CoreRoles.LOCKED_TOKEN_MANAGER) {
        if (_amount == 0) return;

        uint256 _totalReceiptTokens = totalReceiptTokens;

        ERC20Burnable(receiptToken).burn(_amount);

        slashIndex = slashIndex.mulDivDown(_totalReceiptTokens - _amount, _totalReceiptTokens);
        totalReceiptTokens = _totalReceiptTokens - _amount;
    }
}
