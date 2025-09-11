// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBeforeRedeemHook {
    /// @param _to the address to redeem to
    /// @param _receiptAmountIn the amount of receipt tokens to redeem
    /// @param _assetAmountOut the amount of asset tokens to receive
    function beforeRedeem(address _to, uint256 _receiptAmountIn, uint256 _assetAmountOut) external;
}

/// @notice Interface for an InfiniFi Redeem Controller contract
interface IRedeemController {
    /// @notice error emitted when the redemption amount is too low
    error RedeemAmountTooLow(uint256 _amountIn, uint256 _minRedemptionAmount);

    /// @notice event emitted when before redeem hook is changed by the governance
    event BeforeRedeemHookChanged(uint256 indexed timestamp, address hook);
    /// @notice event emitted when minimum redemption amount is updated
    event MinRedemptionAmountUpdated(uint256 indexed timestamp, uint256 amount);

    /// @notice event emitted upon a redemption
    event Redeem(uint256 indexed timestamp, address indexed to, address asset, uint256 amountIn, uint256 amountOut);

    /// @notice calculate the amount of assetToken() out for a given `amountIn` of receiptToken()
    /// @param _receiptAmount the amount of receiptTokens to redeem for assetTokens
    /// @return the amount of assetTokens received
    function receiptToAsset(uint256 _receiptAmount) external view returns (uint256);

    /// @notice redeem `amountIn` receiptToken() for `amountOut` assetToken() and send to address `to`
    /// @param _to the address to send the assetToken to
    /// @param _receiptAmountIn the amount of receiptTokens to redeem for assetTokens
    /// @return the amount of assetTokens received
    function redeem(address _to, uint256 _receiptAmountIn) external returns (uint256);
}
