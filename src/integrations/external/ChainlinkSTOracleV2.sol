// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {YieldSharingV2} from "@finance/YieldSharingV2.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {InfiniFiGatewayV2} from "@gateway/InfiniFiGatewayV2.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice Oracle returning the value of a staked token in Chainlink format
contract ChainlinkSTOracleV2 is CoreControlled {
    using Math for uint256;

    error InvalidRoundId();

    uint256 constant STAKED_TOKEN_AMOUNT = 1e18;

    /// @notice reference to the staked token
    address public immutable stakedToken;

    /// @notice reference to the receipt token
    address public immutable receiptToken;

    /// @notice reference to the accounting contract
    address public immutable gateway;

    constructor(address _core, address _gateway) CoreControlled(_core) {
        gateway = _gateway;
        stakedToken = InfiniFiGatewayV2(_gateway).getAddress("stakedToken");
        receiptToken = StakedToken(stakedToken).asset();
    }

    function price() public view returns (uint256) {
        address yieldSharing = InfiniFiGatewayV2(gateway).getAddress("yieldSharing");

        uint256 totalAssets = StakedToken(stakedToken).totalAssets() + YieldSharingV2(yieldSharing).vested();
        uint256 totalSupply = StakedToken(stakedToken).totalSupply();

        // decimal offset is 0, so 10^0 = 1
        return STAKED_TOKEN_AMOUNT.mulDiv(totalAssets + 1, totalSupply + 1, Math.Rounding.Floor);
    }

    function latestRoundData()
        public
        view
        virtual
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        roundId = 0;
        answer = int256(price());
        startedAt = 0;
        updatedAt = block.timestamp;
        answeredInRound = 0;
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(roundId == 0, InvalidRoundId());
        return latestRoundData();
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external pure returns (string memory) {
        return "Chainlink-formatted InfiniFi ST Oracle V2 (siUSD - iUSD)";
    }

    function version() external pure returns (uint256) {
        return 2;
    }
}
