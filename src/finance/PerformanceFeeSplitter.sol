// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice InfiniFi Performance Fee Splitter contract
contract PerformanceFeeSplitter is ReentrancyGuardTransient {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    address public immutable token;
    address public immutable receiverA;
    address public immutable receiverB;
    uint256 public immutable splitA;

    constructor(address _token, uint256 _splitA, address _receiverA, address _receiverB) {
        require(_splitA <= FixedPointMathLib.WAD);
        token = _token;
        splitA = _splitA;
        receiverA = _receiverA;
        receiverB = _receiverB;
    }

    function pendingA() external view returns (uint256) {
        return IERC20(token).balanceOf(address(this)).mulWadDown(splitA);
    }

    function pendingB() external view returns (uint256) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 aShare = balance.mulWadDown(splitA);
        return balance - aShare;
    }

    function split() external nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;

        uint256 aShare = balance.mulWadDown(splitA);
        uint256 bShare = balance - aShare;
        if (aShare > 0) IERC20(token).safeTransfer(receiverA, aShare);
        if (bShare > 0) IERC20(token).safeTransfer(receiverB, bShare);
    }
}
