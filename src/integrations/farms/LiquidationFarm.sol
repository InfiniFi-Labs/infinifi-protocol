// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {PLSmoother} from "@finance/PLSmoother.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";
import {ManualRebalancer} from "@integrations/farms/movement/ManualRebalancer.sol";

/// @title LiquidationFarm
/// @notice Farm adapter that allows bidding on liquidations, and generally any atomic operations
/// that generate increases in assets() for the farm.
/// @dev This farm requires the following roles to be granted:
///      - MANUAL_REBALANCER: Required to pull funds from other farms via ManualRebalancer
///      - FINANCE_MANAGER: Required to call smoother for profit smoothing
contract LiquidationFarm is MultiAssetFarmV2 {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// @notice Maximum multiplier for smoothDuration relative to config.smoothingDuration
    uint256 public constant _MAX_SMOOTH_DURATION_MULTIPLIER = 10;
    /// @notice Maximum absolute smooth duration
    uint256 public constant _MAX_SMOOTH_DURATION_ABSOLUTE = 365 days;

    /// @notice Whitelist data structure for allowed liquidation calls
    struct WhitelistData {
        address target;
        bytes4 selector;
        address tokenToReceive;
        uint256 smoothingDuration;
    }

    /// @notice Emitted when a liquidation is executed successfully
    /// @param timestamp The block timestamp when the liquidation occurred
    /// @param token The token received from the liquidation
    /// @param spent The number of assetTokens spent to perform the liquidation
    /// @param profit The instantaneous profit denominated in assetTokens
    /// @param duration The smoothing duration of the profit
    event LiquidationExecuted(
        uint256 indexed timestamp, address token, uint256 spent, uint256 profit, uint256 duration
    );

    event WhitelistedCallUpdated(uint256 indexed timestamp, WhitelistData config, bool allowed);

    error LengthMismatch();
    error InvalidAmount(uint256 amount);
    error CallNotWhitelisted(WhitelistData config);
    error LiquidationFailed(bytes reason);
    error InvalidCallDataLength();
    error UnprofitableOperation(uint256 assetsBefore, uint256 totalPulled, uint256 assetsAfter);
    error InsufficientProfit(uint256 min, uint256 actual);
    error InvalidSmoothDuration(uint256 min, uint256 max, uint256 actual);

    address public immutable manualRebalancer;
    address public immutable receiptToken;
    address public immutable smoother;

    /// @notice Mapping of whitelisted calls: keccak256(WhitelistData) => allowed
    mapping(bytes32 => bool) public whitelistedCalls;

    /// @notice Constructor for LiquidationFarm
    /// @param _core The address of the core contract
    /// @param _assetToken The primary asset token for this farm
    /// @param _accounting The address of the accounting contract
    /// @param _manualRebalancer The address of the ManualRebalancer contract
    /// @param _receiptToken The address of the ReceiptToken contract
    /// @param _smoother The address of the PLSmoother contract for profit smoothing
    constructor(
        address _core,
        address _assetToken,
        address _accounting,
        address _manualRebalancer,
        address _receiptToken,
        address _smoother
    ) MultiAssetFarmV2(_core, _assetToken, _accounting) {
        manualRebalancer = _manualRebalancer;
        receiptToken = _receiptToken;
        smoother = _smoother;
    }

    /// @notice Set whether a specific call is whitelisted
    /// @param data The whitelist data containing target, selector, tokenToReceive, and smoothingDuration
    /// @param allowed Whether the call should be allowed
    function setWhitelistedCall(WhitelistData calldata data, bool allowed)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        require(
            data.smoothingDuration > 0 && data.smoothingDuration <= _MAX_SMOOTH_DURATION_ABSOLUTE,
            InvalidSmoothDuration(0, _MAX_SMOOTH_DURATION_ABSOLUTE, data.smoothingDuration)
        );
        whitelistedCalls[keccak256(abi.encode(data))] = allowed;
        if (allowed && !isAssetSupported(data.tokenToReceive)) {
            _enableAsset(data.tokenToReceive);
        }
        emit WhitelistedCallUpdated(block.timestamp, data, allowed);
    }

    /// @notice Execute a liquidation by pulling funds from farms, calling a target, ensuring profit,
    /// and smoothing the profit over the duration.
    function liquidate(
        address[] calldata farms,
        uint256[] calldata amounts,
        WhitelistData calldata config,
        bytes calldata data,
        uint256 minProfit, // in assetTokens
        uint256 smoothDuration
    ) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        require(farms.length == amounts.length, LengthMismatch());

        // Validate the smooth duration
        {
            uint256 maxSmoothDuration = config.smoothingDuration * _MAX_SMOOTH_DURATION_MULTIPLIER;
            require(
                smoothDuration >= config.smoothingDuration && smoothDuration <= maxSmoothDuration
                    && smoothDuration <= _MAX_SMOOTH_DURATION_ABSOLUTE,
                InvalidSmoothDuration(config.smoothingDuration, maxSmoothDuration, smoothDuration)
            );
        }

        // Validate the call is whitelisted
        require(data.length >= 4, InvalidCallDataLength());
        require(
            whitelistedCalls[keccak256(abi.encode(config))] && bytes4(data) == config.selector,
            CallNotWhitelisted(config)
        );

        uint256 assetsBefore = assets();

        // Pull funds from farms to this contract
        uint256 totalPulled;
        for (uint256 i = 0; i < farms.length; i++) {
            // prevent 0 & uint256.max amounts because these have special behaviors in the ManualRebalancer
            // logic (movement of liquidity() and assets() instead of the arg amount).
            require(amounts[i] != 0 && amounts[i] != type(uint256).max, InvalidAmount(amounts[i]));
            uint256 pulled = ManualRebalancer(manualRebalancer).singleMovement(farms[i], address(this), amounts[i]);
            totalPulled += pulled;
        }

        // Execute the call
        {
            IERC20(assetToken).forceApprove(config.target, totalPulled);
            (bool success, bytes memory result) = config.target.call(data);
            require(success, LiquidationFailed(result));
            IERC20(assetToken).forceApprove(config.target, 0);
        }

        // Verify profit
        uint256 receiptTokenProfit;
        {
            uint256 assetsAfter = assets();
            require(
                assetsAfter > assetsBefore + totalPulled, UnprofitableOperation(assetsBefore, totalPulled, assetsAfter)
            );
            uint256 assetTokenProfit = assetsAfter - assetsBefore - totalPulled;
            require(assetTokenProfit >= minProfit, InsufficientProfit(minProfit, assetTokenProfit));

            // Emit event
            emit LiquidationExecuted(
                block.timestamp, config.tokenToReceive, totalPulled, assetTokenProfit, smoothDuration
            );

            // Compute profit in receiptToken terms
            uint256 assetTokenPrice = Accounting(accounting).price(assetToken);
            uint256 receiptTokenPrice = Accounting(accounting).price(receiptToken);
            receiptTokenProfit = assetTokenProfit.mulDivDown(assetTokenPrice, receiptTokenPrice);
        }

        // Smooth the profit over the duration
        PLSmoother(smoother).smoothProfit(receiptTokenProfit, smoothDuration);
    }

    /// @notice Move asset tokens to another farm
    /// @dev this is useful after a liquidation to move the surplus asset tokens
    function moveAsset(address to, uint256 amount) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        ManualRebalancer(manualRebalancer).singleMovement(address(this), to, amount);
    }

    function moveSecondaryAsset(address to, uint256 amount, address token)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        ManualRebalancer(manualRebalancer).singleMovementSecondaryAsset(address(this), to, token, amount);
    }
}
