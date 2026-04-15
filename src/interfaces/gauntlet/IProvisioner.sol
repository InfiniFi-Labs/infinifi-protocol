// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IProvisioner
/// @notice Interface for the contract that can mint and burn vault units in exchange for tokens
interface IProvisioner {
    enum RequestType {
        DEPOSIT_AUTO_PRICE, // 00: deposit, auto price
        REDEEM_AUTO_PRICE, // 01: redeem, auto price
        DEPOSIT_FIXED_PRICE, // 10: deposit, fixed price
        REDEEM_FIXED_PRICE // 11: redeem, fixed price
    }

    struct Request {
        /// @notice Request type(deposit/redeem + auto/fixed price)
        RequestType requestType;
        /// @notice User address making the request
        address user;
        /// @notice Amount of vault units
        uint256 units;
        /// @notice Amount of underlying tokens
        uint256 tokens;
        /// @notice Tip paid to solver, always in tokens
        uint256 solverTip;
        /// @notice Timestamp after which request expires
        uint256 deadline;
        /// @notice Maximum age of price data allowed
        uint256 maxPriceAge;
    }

    /// @notice Token configuration for deposits and redemptions
    struct TokenDetails {
        /// @notice Whether async deposits are enabled
        bool asyncDepositEnabled;
        /// @notice Whether async redemptions are enabled
        bool asyncRedeemEnabled;
        /// @notice Whether sync deposits are enabled
        bool syncDepositEnabled;
        /// @notice Premium multiplier applied to deposits in basis points (9999 = 0.1% premium)
        uint16 depositMultiplier;
        /// @notice Premium multiplier applied to redemptions in basis points (9999 = 0.1% premium)
        uint16 redeemMultiplier;
    }

    ////////////////////////////////////////////////////////////
    //                         Functions                      //
    ////////////////////////////////////////////////////////////

    /// @notice Deposit tokens directly into the vault
    /// @param token The token to deposit
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @dev MUST revert if tokensIn is 0, minUnitsOut is 0, or sync deposits are disabled
    /// @return unitsOut The amount of shares minted to the receiver
    function deposit(IERC20 token, uint256 tokensIn, uint256 minUnitsOut) external returns (uint256 unitsOut);

    /// @notice Mint exact amount of units by depositing required tokens
    /// @param token The token to deposit
    /// @param unitsOut The exact amount of units to mint
    /// @param maxTokensIn Maximum amount of tokens willing to deposit
    /// @return tokensIn The amount of tokens used to mint the requested shares
    function mint(IERC20 token, uint256 unitsOut, uint256 maxTokensIn) external returns (uint256 tokensIn);

    /// @notice Refund a deposit within the refund period
    /// @param sender The original depositor
    /// @param token The deposited token
    /// @param tokenAmount The amount of tokens deposited
    /// @param unitsAmount The amount of units minted
    /// @param refundableUntil Timestamp until which refund is possible
    /// @dev Only callable by authorized addresses
    function refundDeposit(
        address sender,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) external;

    /// @notice Refund an expired deposit or redeem request
    /// @param token The token involved in the request
    /// @param request The request to refund
    /// @dev Can only be called after request deadline has passed
    function refundRequest(IERC20 token, Request calldata request) external;

    /// @notice Create a new deposit request to be solved by solvers
    /// @param token The token to deposit
    /// @param tokensIn The amount of tokens to deposit
    /// @param minUnitsOut The minimum amount of units expected
    /// @param solverTip The tip offered to the solver
    /// @param deadline Duration in seconds for which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    /// @param isFixedPrice Whether the request is a fixed price request
    function requestDeposit(
        IERC20 token,
        uint256 tokensIn,
        uint256 minUnitsOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice
    ) external;

    /// @notice Create a new redeem request to be solved by solvers
    /// @param token The token to receive
    /// @param unitsIn The amount of units to redeem
    /// @param minTokensOut The minimum amount of tokens expected
    /// @param solverTip The tip offered to the solver
    /// @param deadline Duration in seconds for which the request is valid
    /// @param maxPriceAge Maximum age of price data that solver can use
    function requestRedeem(
        IERC20 token,
        uint256 unitsIn,
        uint256 minTokensOut,
        uint256 solverTip,
        uint256 deadline,
        uint256 maxPriceAge,
        bool isFixedPrice
    ) external;

    /// @notice Return maximum amount that can still be deposited
    /// @return Amount of deposit capacity remaining
    function maxDeposit() external view returns (uint256);

    /// @notice Check if a user's units are currently locked
    /// @param user The address to check
    /// @return True if user's units are locked, false otherwise
    function areUserUnitsLocked(address user) external view returns (bool);

    function asyncDepositHashes(bytes32 hash) external view returns (bool);

    function asyncRedeemHashes(bytes32 hash) external view returns (bool);

    /// @notice Computes the hash for a sync deposit
    /// @param user The address making the deposit
    /// @param token The token being deposited
    /// @param tokenAmount The amount of tokens to deposit
    /// @param unitsAmount Minimum amount of units to receive
    /// @param refundableUntil The timestamp until which the deposit is refundable
    /// @return The hash of the deposit
    function getDepositHash(
        address user,
        IERC20 token,
        uint256 tokenAmount,
        uint256 unitsAmount,
        uint256 refundableUntil
    ) external pure returns (bytes32);

    /// @notice Computes the hash for a generic request
    /// @param token The token involved in the request
    /// @param request The request struct
    /// @return The hash of the request
    function getRequestHash(IERC20 token, Request calldata request) external pure returns (bytes32);

    /// @notice Solve multiple requests using vault's liquidity
    /// @param token The token for which to solve requests
    /// @param requests Array of requests to solve
    /// @dev Only callable by authorized addresses
    function solveRequestsVault(IERC20 token, Request[] calldata requests) external;
}
