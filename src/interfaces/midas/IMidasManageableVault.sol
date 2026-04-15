// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IMidasManageableVault {
    enum RequestStatus {
        Pending,
        Processed,
        Canceled
    }

    struct DepositRequest {
        address sender;
        address tokenIn;
        RequestStatus status;
        uint256 depositedUsdAmount;
        uint256 usdAmountWithoutFees;
        uint256 tokenOutRate;
    }

    struct RedeemRequest {
        address sender;
        address tokenOut;
        RequestStatus status;
        uint256 amountMToken;
        uint256 mTokenRate;
        uint256 tokenOutRate;
    }
}
