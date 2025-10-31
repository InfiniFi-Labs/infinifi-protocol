// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPendleV2FarmV3 Interface
/// @notice Interface for Pendle V2 Farm V3 contract
/// @dev Defines the core functionality for managing Pendle Principal Tokens and yield strategies
interface IPendleV2FarmV3 {
    /// @notice Thrown when there are no PTs to reconcile (difference below threshold)
    error NoPTsToReconcile(int256 difference);

    /// @notice Thrown when PT receiver is not set for transfer operations
    error PTReceiverNotSet();

    /// @notice Thrown when trying to set this contract as its own PT receiver
    error PTReceiverIsSelf();

    /// @notice Thrown when a swap operation fails
    /// @param reason The revert reason from the failed swap
    error SwapFailed(bytes reason);

    /// @notice Thrown when trying to unwrap PTs before maturity
    /// @param maturity The maturity timestamp of the PTs
    error PTNotMatured(uint256 maturity);

    /// @notice Thrown when trying to wrap tokens after PT maturity
    /// @param maturity The maturity timestamp of the PTs
    error PTAlreadyMatured(uint256 maturity);

    /// @notice Thrown when there are insufficient tokens for an operation
    /// @param token Address of the token with insufficient balance
    /// @param amount Amount requested
    error InsufficientBalance(address token, uint256 amount);

    /// @notice Thrown when farm PT balance is not reconciled
    /// @param totalReceivedPTs Tracked PT balance
    /// @param balanceOfPTs Actual PT balance
    error FarmNotReconciled(uint256 totalReceivedPTs, uint256 balanceOfPTs);

    /// @notice Thrown when farm is not able to be reconciled
    error FarmNotUsed(uint256 totalReceivedPTs, uint256 currentAssets);

    /// @notice Emitted when tokens are wrapped into PTs using standard router
    /// @param timestamp Block timestamp of the operation
    /// @param tokenIn Token that was wrapped
    /// @param tokenInAmount Amount of input token wrapped
    /// @param ptReceived Amount of PTs received
    /// @param assetsSpent Asset value of the wrapped tokens
    event PTWrapped(
        uint256 indexed timestamp, address tokenIn, uint256 tokenInAmount, uint256 ptReceived, uint256 assetsSpent
    );

    /// @notice Emitted when PTs are unwrapped into tokens using standard router
    /// @param timestamp Block timestamp of the operation
    /// @param tokenOut Token received from unwrapping
    /// @param tokenOutAmount Amount of output token received
    /// @param ptTokensIn Amount of PTs unwrapped
    /// @param assetsReceived Asset value of the received tokens
    event PTUnwrapped(
        uint256 indexed timestamp, address tokenOut, uint256 tokenOutAmount, uint256 ptTokensIn, uint256 assetsReceived
    );

    /// @notice Emitted when tokens are wrapped into PTs using custom calldata
    /// @param timestamp Block timestamp of the operation
    /// @param tokenIn Token that was wrapped
    /// @param tokenInAmount Amount of input token wrapped
    /// @param ptReceived Amount of PTs received
    /// @param assetsSpent Asset value of the wrapped tokens
    event PTZappedIn(
        uint256 indexed timestamp, address tokenIn, uint256 tokenInAmount, uint256 ptReceived, uint256 assetsSpent
    );

    /// @notice Emitted when PTs are unwrapped into tokens using custom calldata
    /// @param timestamp Block timestamp of the operation
    /// @param tokenOut Token received from unwrapping
    /// @param tokenOutAmount Amount of output token received
    /// @param ptTokensIn Amount of PTs unwrapped
    /// @param assetsReceived Asset value of the received tokens
    event PTZappedOut(
        uint256 indexed timestamp, address tokenOut, uint256 tokenOutAmount, uint256 ptTokensIn, uint256 assetsReceived
    );

    /// @notice Emitted when PTs are transferred to another farm
    /// @param timestamp Block timestamp of the operation
    /// @param receiver Address that received the PTs
    /// @param ptTokensIn Amount of PTs transferred
    /// @param assetsSpent Asset value of the transferred PTs
    event PTTransferred(uint256 indexed timestamp, address receiver, uint256 ptTokensIn, uint256 assetsSpent);

    /// @notice Emitted when PT balance is reconciled
    /// @param timestamp Block timestamp of the operation
    /// @param assetsSpent Change in asset value (positive for gains, negative for losses)
    /// @param ptTokensIn Change in PT balance
    event PTReconciled(uint256 indexed timestamp, int256 assetsSpent, int256 ptTokensIn);

    /// @notice Emitted when PT receiver address is changed
    /// @param timestamp Block timestamp of the operation
    /// @param ptReceiver New PT receiver address
    event PTReceiverChanged(uint256 indexed timestamp, address ptReceiver);

    /// @notice Emitted when PT reconciliation threshold is updated
    /// @param timestamp Block timestamp of the operation
    /// @param ptThreshold New reconciliation threshold
    event PTThresholdUpdated(uint256 indexed timestamp, uint256 ptThreshold);

    /// @notice Emitted when Pendle router address is updated
    /// @param timestamp Block timestamp of the operation
    /// @param pendleRouter New Pendle router address
    event PendleRouterUpdated(uint256 indexed timestamp, address pendleRouter);

    /// @notice Emitted when maturity PT discount is updated
    /// @param timestamp Block timestamp of the operation
    /// @param maturityPTDiscount New maturity PT discount
    event MaturityPTDiscountUpdated(uint256 indexed timestamp, uint256 maturityPTDiscount);

    /// @notice Wraps tokens into PTs using standard Pendle router
    /// @param _tokenIn Token to wrap
    /// @param _amountIn Amount to wrap
    function wrapToPt(address _tokenIn, uint256 _amountIn) external;

    /// @notice Unwraps PTs into tokens using standard Pendle router
    /// @param _tokenOut Token to receive
    /// @param _ptTokensIn Amount of PTs to unwrap
    function unwrapFromPt(address _tokenOut, uint256 _ptTokensIn) external;

    /// @notice Wraps tokens into PTs using custom Pendle router calldata
    /// @param _tokenIn Token to wrap
    /// @param _amountIn Amount to wrap
    /// @param _calldata Custom router calldata
    function wrapToPt(address _tokenIn, uint256 _amountIn, bytes memory _calldata) external;

    /// @notice Unwraps PTs into tokens using custom Pendle router calldata
    /// @param _tokenOut Token to receive
    /// @param _ptTokensIn Amount of PTs to unwrap
    /// @param _calldata Custom router calldata
    function unwrapFromPt(address _tokenOut, uint256 _ptTokensIn, bytes memory _calldata) external;

    /// @notice Transfers PTs to the configured receiver
    /// @param _amount Amount of PTs to transfer
    /// @param _reconcile Executes reconcilePt callback if true
    function transferPt(uint256 _amount, bool _reconcile) external;

    /// @notice Reconciles PT balance with actual token balance
    function reconcilePt() external;
}
