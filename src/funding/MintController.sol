// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {IMintController, IAfterMintHook} from "@interfaces/IMintController.sol";

/// @notice Idle Farm that allows users to deposit new funds into the system.
/// This contract reports assets like a Farm for standardized accounting.
contract MintController is Farm, IMintController {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    /// @notice reference to the ReceiptToken contract
    address public immutable receiptToken;

    /// @notice reference to the Accounting contract
    address public immutable accounting;

    /// @notice minimum mint amount
    /// @dev can be set to a different number by GOVERNOR role
    uint256 public minAssetAmount = 1;

    /// @notice address to call in the afterMint hook
    address public afterMintHook;

    constructor(address _core, address _assetToken, address _receiptToken, address _accounting)
        Farm(_core, _assetToken)
    {
        receiptToken = _receiptToken;
        accounting = _accounting;
    }

    /// @notice sets the minimum mint amount
    function setMinAssetAmount(uint256 _minAssetAmount) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_minAssetAmount > 0, AssetAmountTooLow(_minAssetAmount, 1));
        minAssetAmount = _minAssetAmount;
        emit MinAssetAmountUpdated(block.timestamp, _minAssetAmount);
    }

    /// @notice sets the afterMintHook
    function setAfterMintHook(address _afterMintHook) external onlyCoreRole(CoreRoles.GOVERNOR) {
        afterMintHook = _afterMintHook;
        emit AfterMintHookChanged(block.timestamp, _afterMintHook);
    }

    /// @notice calculate the amount of receiptToken() out for a given `amountIn` of assetToken()
    function assetToReceipt(uint256 _assetAmount) public view returns (uint256) {
        uint256 assetTokenPrice = Accounting(accounting).price(assetToken);
        uint256 receiptTokenPrice = Accounting(accounting).price(receiptToken);

        uint256 convertRatio = receiptTokenPrice.divWadUp(assetTokenPrice);
        return _assetAmount.divWadDown(convertRatio);
    }

    /// @notice returns the assets held by the mint controller
    function assets() public view override returns (uint256) {
        return ERC20(assetToken).balanceOf(address(this));
    }

    /// @notice returns the liquidity of the mint controller
    function liquidity() public view override returns (uint256) {
        return ERC20(assetToken).balanceOf(address(this));
    }

    /// @notice introduce new receiptTokens into circulation in exchange of assetTokens
    function mint(address _to, uint256 _assetAmountIn)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.ENTRY_POINT)
        returns (uint256)
    {
        require(_assetAmountIn >= minAssetAmount, AssetAmountTooLow(_assetAmountIn, minAssetAmount));
        uint256 receiptAmountOut = assetToReceipt(_assetAmountIn);

        // pull assets & mint receipt tokens to recipient
        // external calls to the assetToken are trusted
        ERC20(assetToken).safeTransferFrom(msg.sender, address(this), _assetAmountIn);
        ReceiptToken(receiptToken).mint(_to, receiptAmountOut);

        // handle afterMint hook if any
        address _afterMintHook = afterMintHook;
        if (_afterMintHook != address(0)) {
            IAfterMintHook(_afterMintHook).afterMint(_to, _assetAmountIn);
        }

        emit Mint(block.timestamp, _to, assetToken, _assetAmountIn, receiptAmountOut);
        return receiptAmountOut;
    }

    function _deposit(uint256) internal override {} // noop

    function deposit() external override onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        // override to remove checks on cap & slippage
        _deposit(0);
    }

    function _withdraw(uint256 _amount, address _to) internal override {
        ERC20(assetToken).safeTransfer(_to, _amount);
    }

    function withdraw(uint256 amount, address to)
        external
        override
        onlyCoreRole(CoreRoles.FARM_MANAGER)
        whenNotPaused
    {
        // override to remove check on slippage
        _withdraw(amount, to);
    }
}
