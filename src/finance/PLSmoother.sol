// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice PLSmoother
/// This contract is used to smooth the yield spikes in the system.
/// This smoother use piecewise linear interpolation, it holds in storage a list of linear
/// interpolations of yield distributions.
/// @dev this contract requires RECEIPT_TOKEN_MINTER and RECEIPT_TOKEN_BURNER roles.
/// @dev note that the vesting yield held by this contract, similarly to the YieldSharingV2's
/// escrow contract, isn't included in the slashing order. As a result, it could hold undistributed
/// rewards (i.e. pending profit) that would otherwise could have been used to mitigate losses.
contract PLSmoother is CoreControlled {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    event SmoothProfitRecorded(uint256 indexed timestamp, uint256 amount, uint256 duration);
    event Accrued(uint256 indexed timestamp, uint256 amount);

    error InvalidDuration();
    error HashCollision();

    /// @notice Smoothing data structure for tracking profit vesting
    struct SmoothingData {
        uint256 startTimestamp;
        uint256 duration;
        uint256 amount;
        uint256 burned;
    }

    /// @notice reference to the receipt token
    address public immutable receiptToken;

    /// @notice Enumerable set storing smoothing period identifiers
    EnumerableSet.Bytes32Set private smoothingItems;

    /// @notice Mapping from smoothing period hash to smoothing data
    mapping(bytes32 => SmoothingData) private smoothingData;

    constructor(address _core, address _receiptToken) CoreControlled(_core) {
        receiptToken = _receiptToken;
    }

    /// @notice Store smoothing data for a profit smoothing period and mint receipt tokens
    /// @param receiptTokenProfit The amount of receipt tokens to smooth
    /// @param duration The duration over which to smooth the profit
    function smoothProfit(uint256 receiptTokenProfit, uint256 duration)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FINANCE_MANAGER)
    {
        require(duration > 0, InvalidDuration());
        bytes32 itemHash = keccak256(abi.encodePacked(block.timestamp, msg.sender, receiptTokenProfit, duration));
        require(smoothingItems.add(itemHash), HashCollision());
        smoothingData[itemHash] =
            SmoothingData({startTimestamp: block.timestamp, duration: duration, amount: receiptTokenProfit, burned: 0});

        ReceiptToken(receiptToken).mint(address(this), receiptTokenProfit);
        emit SmoothProfitRecorded(block.timestamp, receiptTokenProfit, duration);
    }

    /// @notice Returns the total amount of profit vesting
    function vesting() external view returns (uint256) {
        return ReceiptToken(receiptToken).balanceOf(address(this));
    }

    /// @notice Returns the amount of profit currently accruing per second
    function vestingPerSecond() external view returns (uint256) {
        uint256 perSecond = 0;
        uint256 n = smoothingItems.length();
        for (uint256 i = 0; i < n; i++) {
            SmoothingData memory data = smoothingData[smoothingItems.at(i)];
            // post-deployment note: should use > && <= to exactly match the logic in vested(),
            // but this is not a big deal as the difference is only 1 second
            if (block.timestamp >= data.startTimestamp && block.timestamp < data.startTimestamp + data.duration) {
                perSecond += data.amount / data.duration;
            }
        }
        return perSecond;
    }

    /// @notice Returns the amount of profit that has vested and can be accrued
    function vested() public view returns (uint256) {
        uint256 _vested;
        uint256 n = smoothingItems.length();
        for (uint256 i = 0; i < n; i++) {
            SmoothingData memory data = smoothingData[smoothingItems.at(i)];

            uint256 elapsed = block.timestamp - data.startTimestamp;
            uint256 itemVested;
            if (elapsed >= data.duration) {
                itemVested = data.amount;
            } else {
                itemVested = (data.amount * elapsed) / data.duration;
            }
            itemVested -= data.burned;
            _vested += itemVested;
        }

        return _vested;
    }

    /// @notice Burns the vested amount of receipt tokens held by this contract
    function accrue() external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        uint256 _vested = vested();
        if (_vested == 0) return;

        uint256 remainingToBurn = _vested;
        uint256 i = smoothingItems.length();
        while (i > 0 && remainingToBurn > 0) {
            --i;
            bytes32 itemHash = smoothingItems.at(i);
            SmoothingData storage data = smoothingData[itemHash];

            uint256 elapsed = block.timestamp - data.startTimestamp;
            uint256 itemVested;
            if (elapsed >= data.duration) {
                itemVested = data.amount;
            } else {
                itemVested = (data.amount * elapsed) / data.duration;
            }
            itemVested -= data.burned;

            if (itemVested > 0) {
                data.burned += itemVested;
                remainingToBurn -= itemVested;
            }

            if (data.burned == data.amount) {
                smoothingItems.remove(itemHash);
                delete smoothingData[itemHash];
            }
        }

        assert(remainingToBurn == 0);
        ReceiptToken(receiptToken).burn(_vested);

        emit Accrued(block.timestamp, _vested);
    }
}
