// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {LockingController} from "@locking/LockingController.sol";

/// @notice Oracle returning the value of a locked token in Chainlink format
contract ChainlinkLPTOracleNoK is CoreControlled {
    using FixedPointMathLib for uint256;

    error InvalidRoundId();

    /// @notice Number of unwinding epochs this oracle is for
    uint32 public immutable unwindingEpochs;

    /// @notice reference to the locking controller
    address public lockingController;

    /// @notice reference to the accounting contract
    address public accounting;

    event SetReferences(uint256 timestamp, address lockingController, address accounting);

    constructor(address _core, uint32 _unwindingEpochs, address _lockingController, address _accounting)
        CoreControlled(_core)
    {
        unwindingEpochs = _unwindingEpochs;
        lockingController = _lockingController;
        accounting = _accounting;
    }

    function setReferences(address _lockingController, address _accounting) external onlyCoreRole(CoreRoles.GOVERNOR) {
        lockingController = _lockingController;
        accounting = _accounting;
        emit SetReferences(block.timestamp, _lockingController, _accounting);
    }

    function receiptToken() public view returns (address) {
        return LockingController(lockingController).receiptToken();
    }

    function lockedPositionToken() external view returns (address) {
        return LockingController(lockingController).shareToken(unwindingEpochs);
    }

    function price() public view returns (uint256) {
        address iusd = receiptToken();
        uint256 iusdRate = Accounting(accounting).price(iusd); // e18
        uint256 exchangeRate = LockingController(lockingController).exchangeRate(unwindingEpochs); // e18
        uint256 lptRate = exchangeRate.mulWadDown(iusdRate); // e18
        return lptRate;
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
        return "Chainlink-formatted InfiniFi LPT Oracle";
    }

    function version() external pure returns (uint256) {
        return 1;
    }
}
