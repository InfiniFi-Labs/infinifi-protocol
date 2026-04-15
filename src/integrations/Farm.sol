// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice InfiniFi Farm base contract
abstract contract Farm is CoreControlled, IFarm {
    using FixedPointMathLib for uint256;

    address public immutable assetToken;

    /// @notice cap on the amount of assets that can be deposited into the farm
    uint256 public cap;

    /// @notice Max slippage for depositing and witdhrawing assets from the farm.
    /// @dev Stored as a percentage with 18 decimals of precision, of the minimum
    /// position size compared to the previous position size (so actually 1 - slippage).
    /// @dev Set to 0 to disable slippage checks.
    uint256 public maxSlippage;

    /// @notice reference to the rewards claimer contract
    address public rewardContract;

    error CapExceeded(uint256 newAmount, uint256 cap);
    error SlippageTooHigh(uint256 minAssetsOut, uint256 assetsReceived);
    error ZeroAddress(address);
    error RewardsNotEnabled();
    error RewardsClaimFailed();
    error RewardsClaimLostAssets();

    event CapUpdated(uint256 newCap);
    event MaxSlippageUpdated(uint256 newMaxSlippage);
    event RewardContractUpdated(uint256 indexed timestamp, address rewardContract);
    event Claimed(uint256 indexed timestamp, uint256 amount);

    constructor(address _core, address _assetToken) CoreControlled(_core) {
        assetToken = _assetToken;
        cap = type(uint256).max;

        // default to 99.9999%
        // most farms should not have deposits/withdrawals fees, unless explicitly
        // implemented, and should at worst round against depositors which should
        // only cause some wei of losses when our farms do a deposit/withdraw.
        maxSlippage = 0.999999e18;
    }

    /// @notice used to check slippage on vault operations
    modifier checkSlippage() {
        uint256 assetsBefore = assets();
        _;
        uint256 assetsAfter = assets();
        uint256 minAssetsAfter = assetsBefore.mulWadDown(maxSlippage);
        require(assetsAfter >= minAssetsAfter, SlippageTooHigh(minAssetsAfter, assetsAfter));
    }

    function setRewardContract(address _rewardContract) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_rewardContract != address(0), ZeroAddress(_rewardContract));
        rewardContract = _rewardContract;
        emit RewardContractUpdated(block.timestamp, _rewardContract);
    }

    /// @notice set the deposit cap of the farm
    function setCap(uint256 _newCap) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        cap = _newCap;
        emit CapUpdated(_newCap);
    }

    /// @notice set the max tolerated slippage for depositing and witdhrawing assets from the farm
    function setMaxSlippage(uint256 _maxSlippage) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        maxSlippage = _maxSlippage;
        emit MaxSlippageUpdated(_maxSlippage);
    }

    // --------------------------------------------------------------------
    // Accounting
    // --------------------------------------------------------------------

    function assets() public view virtual returns (uint256);

    // --------------------------------------------------------------------
    // Adapter logic
    // --------------------------------------------------------------------

    function maxDeposit() external view virtual returns (uint256) {
        uint256 currentAssets = assets();
        if (currentAssets >= cap) {
            return 0;
        }
        return cap - currentAssets;
    }

    function deposit() external virtual onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        uint256 assetsToDeposit = ERC20(assetToken).balanceOf(address(this));
        uint256 assetsBefore = assets();

        if (assetsBefore + assetsToDeposit > cap) {
            revert CapExceeded(assetsBefore + assetsToDeposit, cap);
        }

        _deposit(assetsToDeposit);

        uint256 assetsAfter = assets();
        uint256 assetsReceived = assetsAfter - assetsBefore;

        // check slippage
        uint256 minAssetsOut = assetsToDeposit.mulWadDown(maxSlippage);
        require(assetsReceived >= minAssetsOut, SlippageTooHigh(minAssetsOut, assetsReceived));

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsAfter);
    }

    function _deposit(uint256 assetsToDeposit) internal virtual;

    function withdraw(uint256 amount, address to) external virtual onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        uint256 assetsBefore = assets();
        uint256 receiverBalanceBefore = ERC20(assetToken).balanceOf(to);

        _withdraw(amount, to);

        uint256 assetsAfter = assets();
        uint256 receiverBalanceAfter = ERC20(assetToken).balanceOf(to);

        uint256 assetsSpent = assetsBefore - assetsAfter;
        uint256 receiverBalanceIncrease = receiverBalanceAfter - receiverBalanceBefore;
        assert(receiverBalanceIncrease == amount); // sanity check for _withdraw implementations, should never fail

        uint256 minAssetsOut = assetsSpent.mulWadDown(maxSlippage);
        require(amount >= minAssetsOut, SlippageTooHigh(minAssetsOut, amount));

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsAfter);
    }

    /// @dev MAY spend more than _amount of assets() if there is slippage or rounding errors.
    /// @dev MUST transfer exactly _amount of assets() to _to (or withdraw will revert)
    function _withdraw(uint256 _amount, address _to) internal virtual;

    // --------------------------------------------------------------------
    // Rewards claiming
    // --------------------------------------------------------------------
    function claimRewards(bytes memory _calldata) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        address _rewardContract = rewardContract;
        require(_rewardContract != address(0), RewardsNotEnabled());

        uint256 assetsBefore = assets();

        (bool success,) = _rewardContract.call(_calldata);
        require(success, RewardsClaimFailed());

        uint256 assetsAfter = assets();
        require(assetsAfter >= assetsBefore, RewardsClaimLostAssets());

        emit Claimed(block.timestamp, assetsAfter - assetsBefore);
    }
}
