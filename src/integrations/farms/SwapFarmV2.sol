// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {CoWSwapBase} from "@integrations/CoWSwapBase.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";

/// @title SwapFarmV2
/// @notice Farm contract that supports token swapping through CoW Protocol and other aggregators
/// @dev This contract extends MultiAssetFarmV2 and CoWSwapFarmBaseV2 to provide swap functionality
/// @dev It supports both CoW Protocol orders and direct aggregator swaps with configurable pairs
contract SwapFarmV2 is MultiAssetFarmV2, CoWSwapBase {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    event TokensSwapped(
        uint256 indexed timestamp, address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _amountOut
    );

    /// @notice Configuration for token pair swap settings
    struct PairConfig {
        uint64 lastSwap;
        /// @dev Timestamp of the last swap for this pair
        uint64 cooldown;
        /// @dev Cooldown period between swaps for this pair
        uint128 maxSlippage;
    }

    /// @notice Emitted when a router is enabled or disabled
    /// @param timestamp The block timestamp when the router status was changed
    /// @param router The address of the router that was enabled/disabled
    /// @param enabled True if the router was enabled, false if disabled
    event SetEnabledRouter(uint256 timestamp, address router, bool enabled);

    /// @notice Thrown when a swap operation fails
    /// @param _reason The reason for the swap failure
    error SwapFailed(bytes _reason);

    /// @notice Thrown when trying to use a disabled router
    /// @param _router The address of the disabled router
    error RouterNotEnabled(address _router);

    /// @notice Thrown when an invalid cooldown period is provided
    /// @param _cooldown The invalid cooldown value
    error InvalidCooldown(uint256 _cooldown);

    /// @notice Thrown when slippage configuration is invalid
    /// @param _configuredSlipage The configured slippage value
    /// @param _maxSlippage The maximum allowed slippage value
    error InvalidSlippage(uint256 _configuredSlipage, uint256 _maxSlippage);

    /// @notice Maximum allowed cooldown period for swap pairs (12 hours)
    uint256 public constant _MAX_COOLDOWN = 12 hours;

    /// @notice Mapping of routers that can be used to swap tokens
    mapping(address => bool) public enabledRouters;

    /// @notice Mapping of token pairs to their swap configuration
    mapping(bytes32 _key => PairConfig _value) pairConfig;

    /// @notice Constructor for SwapFarmV2
    /// @param _core The address of the core contract
    /// @param _assetToken The primary asset token for this farm
    /// @param _accounting The address of the accounting contract
    /// @param _settlementContract The address of the GPv2Settlement contract
    /// @param _vaultRelayer The address of the GPv2VaultRelayer contract
    constructor(
        address _core,
        address _assetToken,
        address _accounting,
        address _settlementContract,
        address _vaultRelayer
    ) CoWSwapBase(_settlementContract, _vaultRelayer, false) MultiAssetFarmV2(_core, _assetToken, _accounting) {
        // set default slippage tolerance to 99.5%
        maxSlippage = 0.995e18;
    }

    /// @dev Modifier to validate that both tokens in a swap pair are valid and supported
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    modifier validTokenPair(address _tokenIn, address _tokenOut) {
        require(_tokenIn != _tokenOut, InvalidToken(_tokenOut));
        require(isAssetSupported(_tokenIn), InvalidToken(_tokenIn));
        require(isAssetSupported(_tokenOut), InvalidToken(_tokenOut));
        _;
    }

    /// @dev Modifier to validate swap configuration and enforce cooldown periods
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    modifier withValidConfig(address _tokenIn, address _tokenOut) {
        bytes32 key = getSwapPairKey(_tokenIn, _tokenOut);
        PairConfig storage config = pairConfig[key];
        // do not allow swap pairs to exchange too often
        require(block.timestamp > config.lastSwap + config.cooldown, SwapCooldown());
        // enforce pair slippage to respect general level slippage
        require(config.maxSlippage >= maxSlippage, InvalidSlippage(config.maxSlippage, maxSlippage));
        _;
        config.lastSwap = uint64(block.timestamp);
    }

    /// @notice Allows governance to manage the whitelist of routers to be used by the
    /// keeper with FARM_SWAP_CALLER role
    /// @param _router The address of the router to enable/disable
    /// @param _enabled True to enable the router, false to disable
    function setEnabledRouter(address _router, bool _enabled) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        enabledRouters[_router] = _enabled;
        emit SetEnabledRouter(block.timestamp, _router, _enabled);
    }

    /// @notice Sets the configuration of the selected swap pair
    /// @dev !!! Direction is not important for _tokenIn and _tokenOut
    /// @dev note that this can be used to reset the cooldown but it is behind 1 day timelock
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @param _cooldown The cooldown period between swaps for this pair
    /// @param _slippage The maximum slippage tolerance for this pair (in WAD format)
    function setPairConfig(address _tokenIn, address _tokenOut, uint256 _cooldown, uint256 _slippage)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        require(isAssetSupported(_tokenIn), InvalidToken(_tokenIn));
        require(isAssetSupported(_tokenOut), InvalidToken(_tokenOut));
        require(_slippage >= maxSlippage, InvalidSlippage(_slippage, maxSlippage));
        require(_cooldown <= _MAX_COOLDOWN, InvalidCooldown(_cooldown));

        bytes32 _key = getSwapPairKey(_tokenIn, _tokenOut);
        pairConfig[_key] = PairConfig({
            lastSwap: uint64(block.timestamp - _cooldown - 1),
            cooldown: uint64(_cooldown),
            maxSlippage: uint128(_slippage)
        });
    }

    /// @notice Generates a unique key for a token pair (direction-independent)
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @return A unique bytes32 key for the token pair
    function getSwapPairKey(address _tokenIn, address _tokenOut) public pure returns (bytes32) {
        (address a, address b) = _tokenIn > _tokenOut ? (_tokenIn, _tokenOut) : (_tokenOut, _tokenIn);
        return keccak256(abi.encodePacked(a, b));
    }

    /// @notice Returns the configuration for a specific token pair
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @return The PairConfig for the specified token pair
    function getSwapPairConfig(address _tokenIn, address _tokenOut) public view returns (PairConfig memory) {
        bytes32 key = getSwapPairKey(_tokenIn, _tokenOut);
        return pairConfig[key];
    }

    /// @notice Performs a CoW Protocol order signature
    /// @dev The caller is trusted to not be sandwiching the swap to steal yield
    /// @dev There is a prevention measure which sets a cooldown between swap pairs
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @param _amountIn The amount of input tokens to swap
    /// @param _minAmountOut The minimum amount of output tokens expected
    /// @return The signed order UID
    function signSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        external
        whenNotPaused
        withValidConfig(_tokenIn, _tokenOut)
        validTokenPair(_tokenIn, _tokenOut)
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(_amountIn > 0, InvalidAmountIn(_amountIn));
        require(_amountIn <= IERC20(_tokenIn).balanceOf(address(this)), InvalidAmountIn(_amountIn));

        uint256 slippage = getSwapPairConfig(_tokenIn, _tokenOut).maxSlippage;

        CoWSwapBase.CoWSwapData memory _data =
            CoWSwapBase.CoWSwapData(_tokenIn, _tokenOut, _amountIn, _minAmountOut, slippage);

        return _checkSwapApproveAndSignOrder(_data);
    }

    /// @notice Swaps one supported token to another using an enabled aggregator router
    /// @dev The transaction may be submitted privately to avoid sandwiching, and the function
    /// can be called multiple times with partial amounts to help reduce slippage
    /// @dev The caller is trusted to not be sandwiching the swap to steal yield
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @param _amountIn The amount of input tokens to swap
    /// @param _router The address of the aggregator router to use
    /// @param _calldata The calldata to send to the router
    function swapWithAggregator(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        address _router,
        bytes memory _calldata
    )
        external
        whenNotPaused
        withValidConfig(_tokenIn, _tokenOut)
        validTokenPair(_tokenIn, _tokenOut)
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        _preChecks(_tokenIn, _amountIn, _router);

        uint256 tokensReceived = _doSwap(_tokenIn, _tokenOut, _amountIn, _router, _calldata);

        _postChecks(_tokenIn, _tokenOut, _amountIn, tokensReceived);

        emit TokensSwapped(block.timestamp, _tokenIn, _amountIn, _tokenOut, tokensReceived);
    }

    /// @notice pre-check for aggregator swaps
    function _preChecks(address _tokenIn, uint256 _amountIn, address _router) internal view {
        require(enabledRouters[_router], RouterNotEnabled(_router));
        require(_amountIn > 0, InvalidAmountIn(_amountIn));
        require(_amountIn <= IERC20(_tokenIn).balanceOf(address(this)), InvalidAmountIn(_amountIn));
    }

    function _doSwap(address _tokenIn, address _tokenOut, uint256 _amountIn, address _router, bytes memory _calldata)
        internal
        returns (uint256 tokensReceived)
    {
        uint256 tokenOutBalanceBefore = IERC20(_tokenOut).balanceOf(address(this));

        IERC20(_tokenIn).forceApprove(_router, _amountIn);
        (bool success, bytes memory returnData) = _router.call(_calldata);
        require(success, SwapFailed(returnData));

        tokensReceived = IERC20(_tokenOut).balanceOf(address(this)) - tokenOutBalanceBefore;
    }

    function _postChecks(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 tokensReceived)
        internal
        view
    {
        require(tokensReceived > 0, InvalidAmountOut(0, tokensReceived));
        _checkSlippage(_tokenIn, _tokenOut, _amountIn, tokensReceived);
    }

    /// @dev Internal function to check if the swap output meets slippage requirements
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @param _amountIn The amount of input tokens
    /// @param _amountOut The actual amount of output tokens received
    function _checkSlippage(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _amountOut) internal view {
        uint256 slippage = getSwapPairConfig(_tokenIn, _tokenOut).maxSlippage;
        uint256 minAmountOut = convert(_tokenIn, _tokenOut, _amountIn).mulWadDown(slippage);
        require(_amountOut >= minAmountOut, SlippageTooHigh(minAmountOut, _amountOut));
    }

    /// @dev Internal function to validate CoW Protocol swap data
    /// @param _data The swap data to validate
    function _validateSwap(CoWSwapData memory _data) internal view override {
        // check slippage
        uint256 minOutSlippage = convert(_data.tokenIn, _data.tokenOut, _data.amountIn).mulWadDown(_data.maxSlippage);
        require(_data.minAmountOut > minOutSlippage, SlippageTooHigh(minOutSlippage, _data.minAmountOut));
    }
}
