// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAfterMintHook {
    function afterMint(address _to, uint256 _assetsIn, uint256 _receiptTokensOut) external;
}

/// @notice Interface for an InfiniFi Staking Controller contract
interface IMintController {
    /// @notice error emitted when the minting amount is too low
    error MintAmountTooLow(uint256 _amountIn, uint256 _minMintAmount);

    /// @notice event emitted upon a minting
    event Mint(uint256 indexed timestamp, address indexed to, address asset, uint256 amountIn, uint256 amountOut);

    /// @notice calculate the amount of receiptToken() out for a given `amountIn` of assetToken()
    /// @param _assetAmount the amount of assetTokens to convert to receiptTokens
    /// @return the amount of receiptTokens received
    function assetToReceipt(uint256 _assetAmount) external view returns (uint256);

    /// @notice mint `amountOut` receiptToken() to address `to` for `amountIn` assetToken()
    /// @param _to the address to mint the receiptToken to
    /// @param _assetAmountIn the amount of assetTokens to spend for minting receiptTokens
    /// @param _restrict whether to restrict the actions of the recipient
    /// @return the amount of receiptTokens minted
    function mint(address _to, uint256 _assetAmountIn, bool _restrict) external returns (uint256);
}
