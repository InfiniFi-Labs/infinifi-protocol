// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice Oracle returning the value of a receipt token in Chainlink format
contract ChainlinkRTOracle is CoreControlled {
    using FixedPointMathLib for uint256;

    error InvalidRoundId();

    /// @notice reference to the receipt token
    address public immutable receiptToken;

    /// @notice reference to the accounting contract
    address public accounting;

    event SetAccounting(uint256 timestamp, address accounting);

    constructor(address _core, address _receiptToken, address _accounting) CoreControlled(_core) {
        receiptToken = _receiptToken;
        accounting = _accounting;
    }

    function setAccounting(address _accounting) external onlyCoreRole(CoreRoles.GOVERNOR) {
        accounting = _accounting;
        emit SetAccounting(block.timestamp, _accounting);
    }

    function price() public view returns (uint256) {
        return Accounting(accounting).price(receiptToken); // e18
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
        return "Chainlink-formatted InfiniFi RT Oracle";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}
