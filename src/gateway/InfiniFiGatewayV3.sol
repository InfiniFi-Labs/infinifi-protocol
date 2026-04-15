// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GovernanceToken} from "@tokens/GovernanceToken.sol";
import {LockingController} from "@locking/LockingController.sol";
import {InfiniFiGatewayV2} from "@gateway/InfiniFiGatewayV2.sol";
import {MigrationController} from "@funding/MigrationController.sol";

/// @notice Gateway to interact with the InfiniFi protocol
contract InfiniFiGatewayV3 is InfiniFiGatewayV2 {
    using SafeERC20 for ERC20;

    function migrate(address _farm, address _token, uint256 _amount, uint32 _unwindingEpochs, uint256 _minIusdReceived)
        external
        whenNotPaused
        nonReentrant
        returns (uint256)
    {
        ERC20 token = ERC20(_token);
        MigrationController migrationController = MigrationController(getAddress("migrationController"));

        token.safeTransferFrom(msg.sender, address(this), _amount);
        token.approve(address(migrationController), _amount);
        uint256 iusdReceived = migrationController.migrate(msg.sender, _farm, _token, _amount, _unwindingEpochs);
        require(iusdReceived >= _minIusdReceived, MinAssetsOutError(_minIusdReceived, iusdReceived));
        return iusdReceived;
    }

    function lockInfi(uint256 _amount, uint32 _unwindingEpochs) external whenNotPaused nonReentrant {
        GovernanceToken infi = GovernanceToken(getAddress("governanceToken"));
        LockingController locker = LockingController(getAddress("governanceLockingController"));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        infi.transferFrom(msg.sender, address(this), _amount);
        infi.approve(address(locker), _amount);
        locker.createPosition(_amount, _unwindingEpochs, msg.sender);
    }

    function startInfiWithdrawal(uint256 _shares, uint32 _unwindingEpochs) external whenNotPaused nonReentrant {
        LockingController locker = LockingController(getAddress("governanceLockingController"));
        GovernanceToken linfi = GovernanceToken(locker.shareToken(_unwindingEpochs));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        linfi.transferFrom(msg.sender, address(this), _shares);
        linfi.approve(address(locker), _shares);
        locker.startUnwinding(_shares, _unwindingEpochs, msg.sender);
    }

    function increaseInfiWithdrawalPeriod(uint32 _oldUnwindingEpochs, uint32 _newUnwindingEpochs, uint256 _shares)
        external
        whenNotPaused
        nonReentrant
    {
        LockingController locker = LockingController(getAddress("governanceLockingController"));
        GovernanceToken linfi = GovernanceToken(locker.shareToken(_oldUnwindingEpochs));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        linfi.transferFrom(msg.sender, address(this), _shares);
        linfi.approve(address(locker), _shares);
        locker.increaseUnwindingEpochs(_shares, _oldUnwindingEpochs, _newUnwindingEpochs, msg.sender);
    }

    function cancelInfiWithdrawal(uint256 _unwindingTimestamp, uint32 _newUnwindingEpochs)
        external
        whenNotPaused
        nonReentrant
    {
        LockingController(getAddress("governanceLockingController"))
            .cancelUnwinding(msg.sender, _unwindingTimestamp, _newUnwindingEpochs);
    }

    function completeInfiWithdrawal(address _user, uint256 _unwindingTimestamp) external whenNotPaused nonReentrant {
        LockingController(getAddress("governanceLockingController")).withdraw(_user, _unwindingTimestamp);
    }
}
