// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {LockingController} from "@locking/LockingController.sol";

/// @notice Oracle used by Curve pools to know the exchange rate of certain locked tokens
contract LPTCurveOracleV1 is CoreControlled {
    using FixedPointMathLib for uint256;

    /// @notice reference to the iUSD token
    address public immutable iusd;
    /// @notice reference to the siUSD token
    address public immutable siusd;
    /// @notice reference to the locking controller
    address public lockingController;
    /// @notice reference to the accounting contract
    address public accounting;

    event SetReferences(uint256 timestamp, address lockingController, address accounting);

    constructor(address _core, address _iusd, address _siusd, address _lockingController, address _accounting)
        CoreControlled(_core)
    {
        iusd = _iusd;
        siusd = _siusd;
        lockingController = _lockingController;
        accounting = _accounting;
    }

    function setReferences(address _lockingController, address _accounting) external onlyCoreRole(CoreRoles.GOVERNOR) {
        lockingController = _lockingController;
        accounting = _accounting;
        emit SetReferences(block.timestamp, _lockingController, _accounting);
    }

    function getExchangeRate(uint32 _unwindingEpochs) public view returns (uint256) {
        uint256 iusdRate = Accounting(accounting).price(iusd);
        uint256 lptRate = LockingController(lockingController).exchangeRate(_unwindingEpochs);
        return lptRate.mulWadDown(iusdRate);
    }

    function exchangeRateStaked() external view returns (uint256) {
        uint256 iusdRate = Accounting(accounting).price(iusd);
        uint256 stakedRate = StakedToken(siusd).convertToAssets(FixedPointMathLib.WAD);
        return stakedRate.mulWadDown(iusdRate);
    }

    function exchangeRate_1() external view returns (uint256) {
        return getExchangeRate(1);
    }

    function exchangeRate_2() external view returns (uint256) {
        return getExchangeRate(2);
    }

    function exchangeRate_4() external view returns (uint256) {
        return getExchangeRate(4);
    }

    function exchangeRate_6() external view returns (uint256) {
        return getExchangeRate(6);
    }

    function exchangeRate_8() external view returns (uint256) {
        return getExchangeRate(8);
    }

    function exchangeRate_13() external view returns (uint256) {
        return getExchangeRate(13);
    }
}
