// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMidasManageableVault} from "@interfaces/midas/IMidasManageableVault.sol";

interface IMidasRedeemVault is IMidasManageableVault {
    function redeemRequests(uint256 id) external view returns (RedeemRequest memory request);

    function redeemInstant(address tokenOut, uint256 amountMTokenIn, uint256 minReceiveAmount) external;

    function redeemRequest(address tokenOut, uint256 amountMTokenIn) external returns (uint256 id);
}
