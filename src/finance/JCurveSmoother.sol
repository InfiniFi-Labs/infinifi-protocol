// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {YieldSharingV2} from "@finance/YieldSharingV2.sol";

/// @notice JCurveSmoother
/// This contract is used to smooth the yield spikes in the system.
/// When a farm has a large yield spike, instead of calling YieldSharing.accrue(),
/// this contract can be called to self-mint iUSD (bringing back the pending yield to 0),
/// and the iUSD held on this contract can then be periodically burnt, which will in turn
/// increase the pending yield over the interpolation period.
/// @dev this contract requires RECEIPT_TOKEN_MINTER and RECEIPT_TOKEN_BURNER roles.
/// @dev this naive interpolation logic can push (1-1/N)**N ~= 36% of the rewards to after
/// the interpolation period, if the accrueAndSmooth() function is called N times repeatedly
/// during the interpolation period. This was nevertheless chosen for code simplicity instead
/// of a piecewise linear interpolation of rewards whose gas cost would scale linearly with
/// the number of pending distributions.
/// @dev note that the vesting yield held by this contract, similarly to the YieldSharingV2's
/// escrow contract, isn't included in the slashing order. As a result, it could hold undistributed
/// rewards (i.e. pending profit) that would otherwise could have been used to mitigate losses.
contract JCurveSmoother is CoreControlled {
    using FixedPointMathLib for uint256;

    event InterpolationDurationUpdated(uint256 indexed timestamp, uint256 duration);
    event JCurveAccrued(uint256 indexed timestamp, uint256 amount);
    event JCurveDistribution(uint256 indexed timestamp, uint256 amount);

    /// @notice reference to the receipt token
    address public immutable receiptToken;
    /// @notice reference to the yield sharing contract
    address public immutable yieldSharing;

    /// @notice interpolation duration of jcurve
    uint256 public interpolationDuration = 14 days;

    struct Point {
        uint32 lastAccrued;
        uint32 lastClaimed;
        uint208 rate; // distribution per second, scaled with 18 additional decimals
    }

    /// @notice point used for interpolating rewards of the staked users
    Point public point = Point({lastAccrued: uint32(block.timestamp), lastClaimed: uint32(block.timestamp), rate: 0});

    constructor(address _core, address _receiptToken, address _yieldSharing) CoreControlled(_core) {
        receiptToken = _receiptToken;
        yieldSharing = _yieldSharing;
        emit InterpolationDurationUpdated(block.timestamp, interpolationDuration);
    }

    /// @notice set the interpolation duration of the jcurve rewards
    /// @dev Note that the rate of distribution will only change after the next distribute() call
    /// that is distributing a non-zero amount of rewards.
    function setInterpolationDuration(uint256 _duration) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        interpolationDuration = _duration;

        emit InterpolationDurationUpdated(block.timestamp, _duration);
    }

    /// @notice Accrue yield by self-minting iUSD and bringing back pending yield to 0
    /// @dev this function can only be called by the FARM_SWAP_CALLER, who is the role most
    /// likely to trigger spikes in assets() reported within the system because it is performing
    /// token conversions within farms.
    /// @param _accrue whether to accrue the yield to the yield sharing contract
    /// @param _maxYield the maximum amount of yield that should not go through smoothing
    function accrueAndSmooth(bool _accrue, uint256 _maxYield)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        distribute(false);

        /// @dev unaccruedYield returns a number of iUSD to mint or burn upon
        /// the next profit or loss distribution, so the unit is already correct.
        int256 unaccruedYield = YieldSharingV2(yieldSharing).unaccruedYield();

        // in case of losses, no smoothing is needed
        if (unaccruedYield > 0) {
            // amount of yield that should not go through smoothing
            uint256 yieldToSmooth = uint256(unaccruedYield) - Math.min(uint256(unaccruedYield), _maxYield);

            if (yieldToSmooth > 0) {
                // self-mint iUSD to increase totalSupply() & bring back pending yield to 0
                ReceiptToken(receiptToken).mint(address(this), yieldToSmooth);

                // update the interpolation rate with the new balance
                point.rate = uint208(vesting() * FixedPointMathLib.WAD / interpolationDuration);
                point.lastAccrued = uint32(block.timestamp);

                emit JCurveAccrued(block.timestamp, yieldToSmooth);
            }
        }

        if (_accrue) {
            YieldSharingV2(yieldSharing).accrue();
        }
    }

    /// @notice Number of jcurve rewards interpolating
    function vesting() public view returns (uint256) {
        return ReceiptToken(receiptToken).balanceOf(address(this));
    }

    /// @notice Number of jcurve rewards available to distribute right now
    function vested() public view returns (uint256) {
        uint256 _vesting = vesting();
        if (_vesting == 0) return 0;

        uint256 maxTs = Math.max(point.lastAccrued, point.lastClaimed);
        return Math.min(_vesting, uint256(point.rate) * (block.timestamp - maxTs) / FixedPointMathLib.WAD);
    }

    /// @notice Distribute the vested jcurve rewards (burn escrowed iUSD)
    function distribute(bool _accrue) public {
        uint256 _vested = vested();
        point.lastClaimed = uint32(block.timestamp);
        if (_vested != 0) {
            ReceiptToken(receiptToken).burn(_vested);
            emit JCurveDistribution(block.timestamp, _vested);
        }

        if (_accrue) {
            YieldSharingV2(yieldSharing).accrue();
        }
    }
}
