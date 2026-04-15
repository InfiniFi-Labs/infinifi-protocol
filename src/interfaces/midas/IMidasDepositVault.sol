// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IMidasManageableVault} from "@interfaces/midas/IMidasManageableVault.sol";

interface IMidasDepositVault is IMidasManageableVault {
    function mintRequests(uint256 id) external view returns (DepositRequest memory request);

    function depositInstant(address tokenIn, uint256 amountToken, uint256 minReceiveAmount, bytes32 referrerId) external;

    function depositRequest(address tokenIn, uint256 amountToken, bytes32 referrerId) external returns (uint256 id);
}
