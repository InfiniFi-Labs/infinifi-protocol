// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GPv2Settlement} from "@cowprotocol/contracts/GPv2Settlement.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {GPv2Order, IERC20 as ICoWERC20} from "@cowprotocol/contracts/libraries/GPv2Order.sol";

import {Farm} from "@integrations/Farm.sol";
import {IOracle} from "@interfaces/IOracle.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title CoWSwap Farm
/// @notice This contract is used to deploy assets using CoW Swap limit orders. Funds are deposited in the farm
/// in assetTokens, and are then swapped into and out of wrapTokens using CoW Swap.
/// @dev This farm is considered illiquid as swapping in & out will incur slippage.
contract CoWSwapFarm is Farm, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    event OrderSigned(
        uint256 indexed timestamp, bytes orderUid, GPv2Order.Data order, uint32 validTo, uint256 buyAmount
    );

    error SwapCooldown();
    error InvalidAmountIn(uint256 amountIn);
    error InvalidAmountOut(uint256 minOut, uint256 provided);

    /// @notice Reference to the wrap token (to which assetTokens are swapped).
    address public immutable wrapToken;

    /// @notice Reference to accounting contract.
    address public immutable accounting;

    /// @notice Duration of the farm (maturity() returns block.timestamp + duration)
    /// @dev This can be set to 0, treating the farm as a liquid farm, however there will be
    /// slippage to swap in & out of the farm, which acts as some kind of entrance & exit fees.
    /// Consider setting a duration that is at least long enough to earn yield that covers the swap fees.
    uint256 private immutable duration;

    /// @notice timestamp of last order
    uint256 public lastOrderSignTimestamp = 1;
    /// @notice cooldown period between order signings
    uint256 public constant _SIGN_COOLDOWN = 20 minutes;

    /// @notice address of the GPv2Settlement contract
    address public immutable settlementContract;

    /// @notice address of the GPv2VaultRelayer contract
    address public immutable vaultRelayer;

    constructor(
        address _core,
        address _assetToken,
        address _wrapToken,
        address _accounting,
        uint256 _duration,
        address _settlementContract,
        address _vaultRelayer
    ) Farm(_core, _assetToken) {
        wrapToken = _wrapToken;
        accounting = _accounting;
        duration = _duration;
        settlementContract = _settlementContract;
        vaultRelayer = _vaultRelayer;

        // set default slippage tolerance to 99.5%
        maxSlippage = 0.995e18;
    }

    /// @notice Maturity is virtually set as "always in the future" to reflect
    /// that there are swap fees to exit the farm.
    /// In reality we can always swap out, so maturity should be block.timestamp, but these farms
    /// should be treated as illiquid & having a maturity in the future is a good compromise,
    /// because we don't want to allocate funds there unless they stay for at least enough time
    /// to earn yield that covers the swap fees (that act as some kind of entrance & exit fees).
    function maturity() public view override returns (uint256) {
        return block.timestamp + duration;
    }

    /// @notice Returns the total assets in the farm
    /// @dev Note that the assets() function includes the current balance of assetTokens,
    /// this is because deposit()s and withdraw()als in this farm are handled asynchronously,
    /// as they have to go through swaps which calldata has to be generated offchain.
    /// This farm therefore holds its reserve in 2 tokens, assetToken and wrapToken.
    function assets() public view override(Farm, IFarm) returns (uint256) {
        uint256 assetTokenBalance = IERC20(assetToken).balanceOf(address(this));
        uint256 wrapTokenAssetsValue = convertToAssets(IERC20(wrapToken).balanceOf(address(this)));
        return assetTokenBalance + wrapTokenAssetsValue;
    }

    /// @notice Current liquidity of the farm is the held assetTokens.
    function liquidity() public view override returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this));
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm.
    /// @dev See call to wrapAssets() for the actual swap into wrapTokens.
    function _deposit(uint256) internal view override {}

    function deposit() external view override(Farm, IFarm) onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        _deposit(0);
    }

    /// @dev Withdrawal can only handle the held assetTokens (i.e. the liquidity()).
    /// @dev See call to unwrapAssets() for the actual swap out of wrapTokens.
    function _withdraw(uint256 _amount, address _to) internal override {
        IERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice Converts a number of wrapTokens to assetTokens based on oracle rates.
    function convertToAssets(uint256 _wrapTokenAmount) public view returns (uint256) {
        uint256 assetTokenPrice = Accounting(accounting).price(assetToken);
        uint256 wrapTokenPrice = Accounting(accounting).price(wrapToken);
        return _wrapTokenAmount.mulDivDown(wrapTokenPrice, assetTokenPrice);
    }

    /// @notice Converts a number of assetTokens to wrapTokens based on oracle rates.
    function convertToWrapTokens(uint256 _assetsAmount) public view returns (uint256) {
        uint256 assetTokenPrice = Accounting(accounting).price(assetToken);
        uint256 wrapTokenPrice = Accounting(accounting).price(wrapToken);
        return _assetsAmount.mulDivDown(assetTokenPrice, wrapTokenPrice);
    }

    /// @notice Wraps assetTokens as wrapTokens.
    function signWrapOrder(uint256 _assetsIn, uint256 _minWrapTokensOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(_assetsIn > 0 && _assetsIn <= liquidity(), InvalidAmountIn(_assetsIn));

        require(block.timestamp > lastOrderSignTimestamp + _SIGN_COOLDOWN, SwapCooldown());
        lastOrderSignTimestamp = block.timestamp;

        uint256 minOutSlippage = convertToWrapTokens(_assetsIn).mulWadDown(maxSlippage);
        require(_minWrapTokensOut >= minOutSlippage, InvalidAmountOut(minOutSlippage, _minWrapTokensOut));

        IERC20(assetToken).forceApprove(vaultRelayer, _assetsIn);
        return _signOrder(_order(assetToken, wrapToken, _assetsIn, _minWrapTokensOut));
    }

    /// @notice Unwraps wrapTokens to assetTokens.
    function signUnwrapOrder(uint256 _wrapTokensIn, uint256 _minAssetsOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(
            _wrapTokensIn > 0 && _wrapTokensIn <= IERC20(wrapToken).balanceOf(address(this)),
            InvalidAmountIn(_wrapTokensIn)
        );

        require(block.timestamp > lastOrderSignTimestamp + _SIGN_COOLDOWN, SwapCooldown());
        lastOrderSignTimestamp = block.timestamp;

        uint256 minOutSlippage = convertToAssets(_wrapTokensIn.mulWadDown(maxSlippage));
        require(_minAssetsOut >= minOutSlippage, InvalidAmountOut(minOutSlippage, _minAssetsOut));

        IERC20(wrapToken).forceApprove(vaultRelayer, _wrapTokensIn);
        return _signOrder(_order(wrapToken, assetToken, _wrapTokensIn, _minAssetsOut));
    }

    function _order(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        internal
        view
        returns (GPv2Order.Data memory)
    {
        return GPv2Order.Data({
            sellToken: ICoWERC20(_tokenIn),
            buyToken: ICoWERC20(_tokenOut),
            receiver: address(this),
            sellAmount: _amountIn,
            buyAmount: _minAmountOut,
            validTo: uint32(block.timestamp + _SIGN_COOLDOWN),
            // keccak256 {"appCode":"infiniFi","version":"1.0.0","metadata":{}}
            appData: 0x3cac71ef99d0dfbf5b937334b5b7ab672b679ba2bbd4d6fe8e0c54a2dab31109,
            feeAmount: 0,
            kind: GPv2Order.KIND_SELL,
            partiallyFillable: false,
            sellTokenBalance: GPv2Order.BALANCE_ERC20,
            buyTokenBalance: GPv2Order.BALANCE_ERC20
        });
    }

    function _signOrder(GPv2Order.Data memory order) internal returns (bytes memory) {
        GPv2Settlement settlement = GPv2Settlement(payable(settlementContract));
        bytes32 orderDigest = GPv2Order.hash(order, settlement.domainSeparator());
        bytes memory orderUid = new bytes(GPv2Order.UID_LENGTH);
        GPv2Order.packOrderUidParams(orderUid, orderDigest, address(this), order.validTo);
        settlement.setPreSignature(orderUid, true);

        emit OrderSigned(block.timestamp, orderUid, order, order.validTo, order.buyAmount);
        return orderUid;
    }
}
