// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {LockingController} from "@locking/LockingController.sol";
import {YieldVestingEscrow} from "@finance/YieldSharingV2.sol";

/// @notice InfiniFi YieldSharing contract V3
/// this V3 allows the reuse of an existing escrow, adds access control to the accrue() function,
/// and adds a function to flush the excess safety buffer.
contract YieldSharingV3 is CoreControlled {
    using FixedPointMathLib for uint256;

    error PerformanceFeeTooHigh(uint256 _percent);
    error PerformanceFeeRecipientIsZeroAddress(address _recipient);
    error TargetIlliquidRatioTooHigh(uint256 _ratio);
    error StakedTokenNotAvailable();

    /// @notice Fired when yield is accrued from frarms
    /// @param timestamp block timestamp of the accrual
    /// @param yield profit or loss in farms since last accrual
    event YieldAccrued(uint256 indexed timestamp, int256 yield);
    event InterpolationDurationUpdated(uint256 indexed timestamp, uint256 duration);
    event TargetIlliquidRatioUpdated(uint256 indexed timestamp, uint256 multiplier);
    event SafetyBufferSizeUpdated(uint256 indexed timestamp, uint256 value);
    event LiquidMultiplierUpdated(uint256 indexed timestamp, uint256 multiplier);
    event PerformanceFeeSettingsUpdated(uint256 indexed timestamp, uint256 percentage, address recipient);
    event ExcessSafetyBufferFlushed(uint256 indexed timestamp, address recipient, uint256 amount);

    uint256 public constant MAX_PERFORMANCE_FEE = 0.2e18; // 20%

    /// @notice reference to farm accounting contract
    address public accounting;

    /// @notice reference to receipt token
    address public receiptToken;

    /// @notice reference to staked token
    address public stakedToken;

    /// @notice reference to locking module
    address public lockingModule;

    /// @notice safety buffer amount.
    /// This amount of iUSD is held on the contract and consumed first in case of losses smaller
    /// than the safety buffer. It is also replenished first in case of profit, up to the buffer size.
    /// The buffer held could exceed safetyBufferSize if there are donations to this contract, or if
    /// the buffer size has been reduced since last profit distribution, or if there are no other
    /// users to distribute to.
    /// The safety buffer is meant to absorb small losses such as slippage or fees when
    /// deploying capital to productive farms.
    /// safety buffer can be emptied by governance through the use of emergencyAction().
    uint256 public safetyBufferSize;

    /// @notice optional performance fee, expressed as a percentage with 18 decimals.
    uint256 public performanceFee; // default to 0%

    /// @notice optional performance fee recipient
    address public performanceFeeRecipient;

    /// @notice multiplier for the liquid return, expressed as a percentage with 18 decimals.
    uint256 public liquidReturnMultiplier;

    /// @notice target illiquid ratio, expressed as a percentage with 18 decimals.
    /// This ratio is the minimum percent of illiquid holdings the protocol is targetting, and
    /// if there is a percentage of illiquid users lower than the targetIlliquidRatio, the protocol
    /// wil distribute additional rewards to the illiquid users until targetIlliquidRatio is reached.
    uint256 public targetIlliquidRatio; // default to 0

    struct StakedReceiptTokenCache {
        uint48 blockTimestamp;
        uint208 amount;
    }

    StakedReceiptTokenCache public stakedReceiptTokenCache;

    /// @notice escrow of rewards to staked users
    YieldVestingEscrow public escrow;

    /// @notice interpolation duration of rewards to staked users
    uint256 public interpolationDuration;

    struct Point {
        uint32 lastAccrued;
        uint32 lastClaimed;
        uint208 rate;
    }

    /// @notice point used for interpolating rewards of the staked users
    Point public point = Point({lastAccrued: uint32(block.timestamp), lastClaimed: uint32(block.timestamp), rate: 0});

    /// @notice Make deposits and withdrawals in the staked token revert unless set to true.
    bool public transient canEnterOrExitStakedToken;

    constructor() CoreControlled(address(1)) {}

    /// @notice initializer for deployment behind a proxy
    function initialize(
        address _core,
        address _accounting,
        address _receiptToken,
        address _stakedToken,
        address _lockingModule,
        address _escrow
    ) external {
        require(address(core()) == address(0));

        _setCore(_core);
        accounting = _accounting;
        receiptToken = _receiptToken;
        stakedToken = _stakedToken;
        lockingModule = _lockingModule;
        escrow = YieldVestingEscrow(_escrow);
        ReceiptToken(receiptToken).approve(_lockingModule, type(uint256).max);

        interpolationDuration = 8 hours;
        emit InterpolationDurationUpdated(block.timestamp, interpolationDuration);
        liquidReturnMultiplier = FixedPointMathLib.WAD;
        emit LiquidMultiplierUpdated(block.timestamp, liquidReturnMultiplier);
    }

    /// @notice set the safety buffer size
    /// @param _safetyBufferSize the new safety buffer size
    function setSafetyBufferSize(uint256 _safetyBufferSize) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        safetyBufferSize = _safetyBufferSize;
        emit SafetyBufferSizeUpdated(block.timestamp, _safetyBufferSize);
    }

    /// @notice set the performance fee and recipient
    function setPerformanceFeeAndRecipient(uint256 _percent, address _recipient)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        require(_percent <= MAX_PERFORMANCE_FEE, PerformanceFeeTooHigh(_percent));
        if (_percent > 0) {
            require(_recipient != address(0), PerformanceFeeRecipientIsZeroAddress(_recipient));
        }

        performanceFee = _percent;
        performanceFeeRecipient = _recipient;
        emit PerformanceFeeSettingsUpdated(block.timestamp, _percent, _recipient);
    }

    /// @notice set the liquid return multiplier
    function setLiquidReturnMultiplier(uint256 _multiplier) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        liquidReturnMultiplier = _multiplier;
        emit LiquidMultiplierUpdated(block.timestamp, _multiplier);
    }

    /// @notice set the target illiquid ratio
    function setTargetIlliquidRatio(uint256 _ratio) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_ratio <= FixedPointMathLib.WAD, TargetIlliquidRatioTooHigh(_ratio));
        targetIlliquidRatio = _ratio;
        emit TargetIlliquidRatioUpdated(block.timestamp, _ratio);
    }

    /// @notice set the interpolation duration of StakedToken rewards
    /// @dev Note that the rate of distribution will only change after the next accrue() call
    /// that is distributing a non-zero amount of rewards to the staked users.
    function setInterpolationDuration(uint256 _duration) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        interpolationDuration = _duration;
        emit InterpolationDurationUpdated(block.timestamp, _duration);
    }

    /// @notice returns the yield earned by the protocol since the last accrue() call.
    /// @return yield as an amount of receiptTokens.
    /// @dev Note that yield can be negative if the protocol farms have lost value, or if the
    /// oracle price of assets held in the protocol has decreased since last accrue() call,
    /// or if more ReceiptTokens entered circulation than assets entered the protocol.
    function unaccruedYield() public view returns (int256) {
        uint256 receiptTokenPrice = Accounting(accounting).price(receiptToken);
        uint256 assets = Accounting(accounting).totalAssetsValue(); // returns assets in USD

        uint256 assetsInReceiptTokens = assets.divWadDown(receiptTokenPrice);

        // casting to 'int256' is safe because type(int256).max is an irrealistically large amount of receiptTokens
        // forge-lint: disable-next-line(unsafe-typecast)
        return int256(assetsInReceiptTokens) - int256(ReceiptToken(receiptToken).totalSupply());
    }

    /// @notice accrue yield and handle profits & losses
    /// This function should bring back unaccruedYield() to 0 by minting receiptTokens into circulation (profit distribution)
    /// or burning receipt tokens (slashing) or updating the oracle price of the receiptToken if there
    /// are not enough first-loss capital stakers to slash.
    function _accrue() internal {
        distributeInterpolationRewards();

        int256 yield = unaccruedYield();
        // casting to 'uint256' is safe because of 'if'
        // forge-lint: disable-next-line(unsafe-typecast)
        if (yield > 0) _handlePositiveYield(uint256(yield), true, true);
        // casting to 'uint256' is safe because of 'else'
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (yield < 0) _handleNegativeYield(uint256(-yield));

        emit YieldAccrued(block.timestamp, yield);
    }

    function accrue() external whenNotPaused onlyCoreRole(CoreRoles.ACCRUE_YIELD) {
        _accrue();
    }

    function _getCachedStakedReceiptTokens() internal returns (uint256) {
        StakedReceiptTokenCache memory data = stakedReceiptTokenCache;
        if (uint256(data.blockTimestamp) == block.timestamp) {
            return uint256(data.amount);
        }
        uint256 amount = ReceiptToken(receiptToken).balanceOf(stakedToken);
        assert(amount <= type(uint208).max);

        // casting to 'uint48' is safe because type(uint48).max timestamp is very far in the future
        // forge-lint: disable-next-line(unsafe-typecast)
        stakedReceiptTokenCache.blockTimestamp = uint48(block.timestamp);
        // casting to 'uint208' is safe because of the assert above
        // forge-lint: disable-next-line(unsafe-typecast)
        stakedReceiptTokenCache.amount = uint208(amount);

        return amount;
    }

    // hook called by any deposits and withdrawals in siUSD vault, we revert if the
    // flag is not set to true. this will break 4626 compatibility of the vault for
    // deposits and withdrawals, but the gateway can set the flag and perform entry/
    // exits on behalf of the users.
    function getCachedStakedReceiptTokens() public returns (uint256) {
        require(canEnterOrExitStakedToken, StakedTokenNotAvailable());
        return _getCachedStakedReceiptTokens();
    }

    // gateway can set the flag to allow deposits and withdrawals in the siUSD vault
    function setCanEnterOrExitStakedToken(bool _value) external onlyCoreRole(CoreRoles.ENTRY_POINT) {
        canEnterOrExitStakedToken = _value;
    }

    /// @notice Number of rewards interpolating to staked users
    function vesting() public view returns (uint256) {
        return ReceiptToken(receiptToken).balanceOf(address(escrow));
    }

    /// @notice Number of rewards vested to staked users
    function vested() public view returns (uint256) {
        uint256 _vesting = vesting();
        if (_vesting == 0) return 0;

        uint256 maxTs = Math.max(point.lastAccrued, point.lastClaimed);
        return Math.min(_vesting, uint256(point.rate) * (block.timestamp - maxTs));
    }

    // send the vested rewards to the siUSD vault
    // called by the gateway before stake & unstake,
    // and here in the yieldSharing before accrue()
    function distributeInterpolationRewards() public {
        uint256 _vested = vested();
        point.lastClaimed = uint32(block.timestamp);
        if (_vested != 0) {
            escrow.send(receiptToken, stakedToken, _vested);
        }
    }

    /// @notice Yield sharing: split between iUSD lockin users & siUSD holders.
    /// If no users are locking or saving, the profit is minted on this contract and
    /// held idle so that the accrue() expected behavior of restoring protocol equity to 0
    /// is maintained. Funds minted on this contract in such a way can be unstuck by governance
    /// through the use of emergencyAction().
    /// @param _positiveYield the amount of profit to distribute
    /// @param _doMint whether to self-mint the profit before distribution
    /// @param _applyPerfFee whether to apply the performance fee
    function _handlePositiveYield(uint256 _positiveYield, bool _doMint, bool _applyPerfFee) internal {
        uint256 stakedReceiptTokens = _getCachedStakedReceiptTokens().mulWadDown(liquidReturnMultiplier);
        uint256 receiptTokenTotalSupply = ReceiptToken(receiptToken).totalSupply();
        uint256 targetIlliquidMinimum = receiptTokenTotalSupply.mulWadDown(targetIlliquidRatio);
        uint256 lockingReceiptTokens = LockingController(lockingModule).totalBalance();
        if (lockingReceiptTokens < targetIlliquidMinimum) {
            lockingReceiptTokens = targetIlliquidMinimum;
        }
        uint256 bondingMultiplier = LockingController(lockingModule).rewardMultiplier();
        lockingReceiptTokens = lockingReceiptTokens.mulWadDown(bondingMultiplier);
        uint256 totalReceiptTokens = stakedReceiptTokens + lockingReceiptTokens;

        // mint yield
        if (_doMint) ReceiptToken(receiptToken).mint(address(this), _positiveYield);

        // fill safety buffer first
        uint256 _safetyBufferSize = safetyBufferSize;
        if (_safetyBufferSize > 0) {
            uint256 safetyBuffer = ReceiptToken(receiptToken).balanceOf(address(this)) - _positiveYield;
            if (safetyBuffer < _safetyBufferSize) {
                if (safetyBuffer + _positiveYield > _safetyBufferSize) {
                    // there will be a leftover profit after filling the safety buffer, so we
                    // deduct the safety buffer contribution from the profits and continue
                    _positiveYield -= _safetyBufferSize - safetyBuffer;
                } else {
                    // do not do any further distribution and only replenish the safety buffer
                    return;
                }
            }
        }

        // performance fee
        uint256 _performanceFee = performanceFee;
        if (_performanceFee > 0 && _applyPerfFee) {
            uint256 fee = _positiveYield.mulWadDown(_performanceFee);
            if (fee > 0) {
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                ReceiptToken(receiptToken).transfer(performanceFeeRecipient, fee);
                _positiveYield -= fee;
            }
        }

        // compute splits
        if (totalReceiptTokens == 0) {
            // nobody to distribute to, do nothing and hold the tokens
            return;
        }

        // yield split to staked users
        uint256 stakingProfit = _positiveYield.mulDivDown(stakedReceiptTokens, totalReceiptTokens);
        if (stakingProfit > 0) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            ReceiptToken(receiptToken).transfer(address(escrow), stakingProfit);
            // casting to 'uint208' is safe because type(uint208).max would be an outrageously large rate per second
            // forge-lint: disable-next-line(unsafe-typecast)
            point.rate = uint208(vesting() / interpolationDuration);
            point.lastAccrued = uint32(block.timestamp);
        }

        // yield split to locking users
        uint256 lockingProfit = _positiveYield - stakingProfit;
        if (lockingProfit > 0) {
            LockingController(lockingModule).depositRewards(lockingProfit);
        }
    }

    /// @notice Loss propagation: iUSD locking users -> siUSD holders -> iUSD holders
    function _handleNegativeYield(uint256 _negativeYield) internal {
        // if there is a safety buffer, and the loss is smaller than the safety buffer,
        // consume it and do not apply any losses to users.
        uint256 safetyBuffer = ReceiptToken(receiptToken).balanceOf(address(this));
        if (safetyBuffer >= _negativeYield) {
            ReceiptToken(receiptToken).burn(_negativeYield);
            return;
        }

        // first, apply losses to locking users
        uint256 lockingReceiptTokens = LockingController(lockingModule).totalBalance();
        if (_negativeYield <= lockingReceiptTokens) {
            LockingController(lockingModule).applyLosses(_negativeYield);
            return;
        }
        LockingController(lockingModule).applyLosses(lockingReceiptTokens);
        _negativeYield -= lockingReceiptTokens;

        // second, apply negativeYield to siUSD holders
        uint256 stakedReceiptTokens = ReceiptToken(receiptToken).balanceOf(stakedToken);
        if (_negativeYield <= stakedReceiptTokens) {
            StakedToken(stakedToken).applyLosses(_negativeYield);
            return;
        }
        StakedToken(stakedToken).applyLosses(stakedReceiptTokens);
        _negativeYield -= stakedReceiptTokens;

        // lastly, apply losses to all iUSD in circulation
        uint256 totalSupply = ReceiptToken(receiptToken).totalSupply();
        address oracle = Accounting(accounting).oracle(receiptToken);
        uint256 price = FixedPriceOracle(oracle).price();
        uint256 newPrice = price.mulDivDown(totalSupply - _negativeYield, totalSupply);
        FixedPriceOracle(oracle).setPrice(newPrice);
    }

    function migrateSafetyBuffer(address _source) external onlyCoreRole(CoreRoles.GOVERNOR) {
        uint256 sourceBalance = ReceiptToken(receiptToken).balanceOf(_source);
        uint256 sourceAllowance = ReceiptToken(receiptToken).allowance(_source, address(this));
        uint256 amount = sourceAllowance < sourceBalance ? sourceAllowance : sourceBalance;
        if (amount > 0) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            ReceiptToken(receiptToken).transferFrom(_source, address(this), amount);
        }
    }

    /// @notice flush the excess safety buffer
    /// @param _recipient The recipient of the excess safety buffer
    /// @dev the recipient can be:
    /// - address(0) to distribute the excess as yield normally,
    /// - stakedToken to distribute the excess as yield to siUSD holders,
    /// - lockingModule to distribute the excess as yield to liUSD holders,
    /// - or any other address to send the excess to.
    /// @dev note that yield distributed through this function is ignoring the performance fee
    function flushExcessSafetyBuffer(address _recipient, uint256 _maxFlushAmount)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.ACCRUE_YIELD)
    {
        _accrue();

        uint256 balance = ReceiptToken(receiptToken).balanceOf(address(this));
        uint256 _safetyBufferSize = safetyBufferSize;
        uint256 excess = balance > _safetyBufferSize ? balance - _safetyBufferSize : 0;
        if (excess == 0) return;

        if (_maxFlushAmount > 0 && excess > _maxFlushAmount) excess = _maxFlushAmount;

        // case 1: recipient is address(0): distribute excess as yield normally
        if (_recipient == address(0)) {
            _handlePositiveYield(excess, false, false);
        }
        // case 1: recipient is siUSD: distribute excess as yield to siUSD holders
        else if (_recipient == stakedToken) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            ReceiptToken(receiptToken).transfer(address(escrow), excess);
            // casting to 'uint208' is safe because type(uint208).max would be
            // an outrageously large rate per second
            // forge-lint: disable-next-line(unsafe-typecast)
            point.rate = uint208(vesting() / interpolationDuration);
            point.lastAccrued = uint32(block.timestamp);
        }
        // case 2: recipient is lockingModule: distribute excess as yield to liUSD holders
        else if (_recipient == lockingModule) {
            LockingController(lockingModule).depositRewards(excess);
        }
        // case 3: recipient is other: send excess to recipient
        else {
            // receipt token always returns true or revert
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            ReceiptToken(receiptToken).transfer(_recipient, excess);
        }

        emit ExcessSafetyBufferFlushed(block.timestamp, _recipient, excess);
    }
}
