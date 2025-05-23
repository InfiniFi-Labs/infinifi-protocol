// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAfterMintHook {
    /// @notice event emitted when asset rebalance threshold is updated by the governance
    event AssetRebalanceThresholdUpdated(uint256 indexed timestamp, uint256 amount);

    /// @param _to the address to mint to
    /// @param _assetsIn the amount of assets deposited
    function afterMint(address _to, uint256 _assetsIn) external;
}

/// @notice Interface for an InfiniFi Staking Controller contract
interface IMintController {
    /// @notice error emitted when the asset amount is too low
    error AssetAmountTooLow(uint256 _amountIn, uint256 _minAssetAmount);

    /// @notice event emitted when afterMintHook is changed
    event AfterMintHookChanged(uint256 indexed timestamp, address hook);

    /// @notice event emitted when minimum asset amount is updated by the governance
    event MinAssetAmountUpdated(uint256 indexed timestamp, uint256 amount);

    /// @notice event emitted upon a minting
    event Mint(uint256 indexed timestamp, address indexed to, address asset, uint256 amountIn, uint256 amountOut);

    /// @notice calculate the amount of receiptToken() out for a given `amountIn` of assetToken()
    /// @param _assetAmount the amount of assetTokens to convert to receiptTokens
    /// @return the amount of receiptTokens received
    function assetToReceipt(uint256 _assetAmount) external view returns (uint256);

    /// @notice mint `amountOut` receiptToken() to address `to` for `amountIn` assetToken()
    /// @param _to the address to mint the receiptToken to
    /// @param _assetAmountIn the amount of assetTokens to spend for minting receiptTokens
    /// @return the amount of receiptTokens minted
    function mint(address _to, uint256 _assetAmountIn) external returns (uint256);
}
