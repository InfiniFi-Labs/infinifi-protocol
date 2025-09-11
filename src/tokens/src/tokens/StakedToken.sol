// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {YieldSharing} from "@finance/YieldSharing.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {ERC20, IERC20, ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice InfiniFi Staked Token.
/// @dev be carefull, as this contract is an ERC4626, the "assets" keyword is used to refer to the underlying token
/// in this case, it's the ReceiptToken. It's a bit confusing because "asset" is the word we use to refer to the backing token (USDC)
/// everywhere else in the code
contract StakedToken is ERC4626, CoreControlled {
    using EpochLib for uint256;

    /// @notice error thrown when there are pending losses unapplied
    /// if you observe this error as a user, call YieldSharing.accrue() before
    /// attempting a withdrawal from the vault.
    error PendingLossesUnapplied();

    /// @notice emitted when a loss is applied to the vault
    /// @dev epoch could be 0 if the principal of the vault has to be slashed
    event VaultLoss(uint256 indexed timestamp, uint256 epoch, uint256 assets);
    /// @notice emitted when a profit is applied to the vault
    event VaultProfit(uint256 indexed timestamp, uint256 epoch, uint256 assets);

    /// @notice reference to the YieldSharing contract
    address public yieldSharing;

    /// @notice rewards to distribute per epoch
    /// @dev epochRewards can only contain future rewards in the next epoch,
    /// and not further in the future - see `depositRewards()`.
    mapping(uint256 epoch => uint256 rewards) public epochRewards;

    constructor(address _core, address _receiptToken)
        CoreControlled(_core)
        ERC20(string.concat("Staked ", ERC20(_receiptToken).name()), string.concat("s", ERC20(_receiptToken).symbol()))
        ERC4626(IERC20(_receiptToken))
    {}

    /// @notice allows governor to update the yieldSharing reference
    function setYieldSharing(address _yieldSharing) external onlyCoreRole(CoreRoles.GOVERNOR) {
        yieldSharing = _yieldSharing;
    }

    /// ---------------------------------------------------------------------------
    /// Overrides
    /// ---------------------------------------------------------------------------

    function maxMint(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxMint(_receiver);
    }

    function maxDeposit(address _receiver) public view override returns (uint256) {
        if (paused()) {
            return 0;
        }
        return super.maxDeposit(_receiver);
    }

    function maxRedeem(address _receiver) public view override returns (uint256) {
        if (paused() || YieldSharing(yieldSharing).unaccruedYield() < 0) {
            return 0;
        }
        return super.maxRedeem(_receiver);
    }

    function maxWithdraw(address _receiver) public view override returns (uint256) {
        if (paused() || YieldSharing(yieldSharing).unaccruedYield() < 0) {
            return 0;
        }
        return super.maxWithdraw(_receiver);
    }

    // override vault deposits & withdrawals to hook into yieldSharing, so
    // that yieldSharing can cache the number of receiptTokens staked in StakedToken
    // and avoid intra-block manipulations during yield distribution.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        YieldSharing(yieldSharing).getCachedStakedReceiptTokens();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        YieldSharing(yieldSharing).getCachedStakedReceiptTokens();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /// ---------------------------------------------------------------------------
    /// Loss Management
    /// ---------------------------------------------------------------------------

    /// @notice Slash losses in future epoch rewards, current epoch rewards, and principal.
    /// @dev note that this function might behave slightly differently than expected, for the sake
    /// of simplicity in the slashing logic.
    /// Take the following example:
    /// - 1500 assets in "vault principal"
    /// - 300 in current epoch rewards (150 already available, 150 still vesting)
    /// - 50 in next epoch rewards
    /// -> totalAssets() = 1650.
    /// If a loss of 250 occurs, you might expect the slashing to remove :
    /// - 50 tokens in next epoch rewards (200 loss still remaining)
    /// - 150 tokens in current epoch vesting rewards (50 loss still remaining)
    /// - 50 tokens in principal (0 loss remaining)
    /// -> resulting in a totalAssets() of 1500 - 50 (principal slash)
    ///    + 150 (vested current epoch rewards) = 1600.
    ///    and no remaining rewards towards the end of the epoch.
    /// However, the actual behavior will be:
    /// - 50 tokens in next epoch rewards (200 loss still remaining)
    /// - 200 tokens in current epoch vesting rewards (0 loss remaining)
    ///   current epoch rewards updated to 300 - 200 = 100
    /// -> resulting in a totalAssets() of 1500 + 50 (vested current epoch rewards) = 1550.
    ///    and a remaining rewards interpolation of 50 until the end of the epoch, resulting
    ///    in a totalAssets() at the end of the epoch of 1600.
    /// This is a slight inconsistency between how losses are applied and how rewards are
    /// interpolated/reported in totalAssets(). Operationally, the interpolating rewards should be
    /// small compared to the vault's TVL, and slashing events should be rare, so this simplified
    /// logic is acceptable.
    function applyLosses(uint256 _amount) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        // any future rewards are slashed first
        // first, slash next epoch rewards
        _amount = _slashEpochRewards(block.timestamp.nextEpoch(), _amount);
        if (_amount == 0) return;
        // second, slash current epoch rewards
        _amount = _slashEpochRewards(block.timestamp.epoch(), _amount);
        if (_amount == 0) return;
        // lastly, slash the principal of the vault
        ReceiptToken(asset()).burn(_amount);
        emit VaultLoss(block.timestamp, 0, _amount);
    }

    /// @notice Slash rewards for a given epoch
    function _slashEpochRewards(uint256 _epoch, uint256 _amount) internal returns (uint256) {
        uint256 _epochRewards = epochRewards[_epoch];
        if (_epochRewards >= _amount) {
            epochRewards[_epoch] = _epochRewards - _amount;
            ReceiptToken(asset()).burn(_amount);
            emit VaultLoss(block.timestamp, _epoch, _amount);
            _amount = 0;
        } else {
            epochRewards[_epoch] = 0;
            ReceiptToken(asset()).burn(_epochRewards);
            emit VaultLoss(block.timestamp, _epoch, _epochRewards);
            _amount -= _epochRewards;
        }
        return _amount;
    }

    /// ---------------------------------------------------------------------------
    /// Profit Smoothing
    /// ---------------------------------------------------------------------------

    function depositRewards(uint256 _amount) external onlyCoreRole(CoreRoles.FINANCE_MANAGER) {
        ERC20(asset()).transferFrom(msg.sender, address(this), _amount);
        uint256 epoch = block.timestamp.nextEpoch();
        epochRewards[epoch] += _amount;
        emit VaultProfit(block.timestamp, epoch, _amount);
    }

    /// @notice returns the amount of rewards for the current epoch minus the rewards that are already available
    function _unavailableCurrentEpochRewards() internal view returns (uint256) {
        uint256 currentEpoch = block.timestamp.epoch();
        uint256 currentEpochRewards = epochRewards[currentEpoch]; // safe upcast
        uint256 elapsed = block.timestamp - currentEpoch.epochToTimestamp();
        uint256 availableEpochRewards = (currentEpochRewards * elapsed) / EpochLib.EPOCH;
        return currentEpochRewards - availableEpochRewards;
    }

    /// @notice returns the total assets, excluding the rewards that are not available yet
    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() - epochRewards[block.timestamp.nextEpoch()] - _unavailableCurrentEpochRewards();
    }
}
