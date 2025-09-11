// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice Oracle returning the value of a staked token in Chainlink format
contract ChainlinkSTOracle is CoreControlled {
    using FixedPointMathLib for uint256;

    error InvalidRoundId();

    /// @notice reference to the staked token
    address public immutable stakedToken;

    /// @notice reference to the accounting contract
    address public accounting;

    event SetAccounting(uint256 timestamp, address accounting);

    constructor(address _core, address _stakedToken, address _accounting) CoreControlled(_core) {
        stakedToken = _stakedToken;
        accounting = _accounting;
    }

    function setAccounting(address _accounting) external onlyCoreRole(CoreRoles.GOVERNOR) {
        accounting = _accounting;
        emit SetAccounting(block.timestamp, _accounting);
    }

    function receiptToken() public view returns (address) {
        return StakedToken(stakedToken).asset();
    }

    function price() public view returns (uint256) {
        address iusd = receiptToken();
        uint256 iusdRate = Accounting(accounting).price(iusd); // e18
        uint256 exchangeRate = StakedToken(stakedToken).convertToAssets(1e18); // e18
        return exchangeRate.mulWadDown(iusdRate); // e18
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
        return "Chainlink-formatted InfiniFi ST Oracle";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}
