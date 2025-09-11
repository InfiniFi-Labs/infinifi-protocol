// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPendleMarket {
    function readTokens() external view returns (address sy, address pt, address yt);
    function expiry() external view returns (uint256 timestamp);
}
