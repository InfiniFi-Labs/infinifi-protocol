// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {LockingController} from "@locking/LockingController.sol";

contract LockingTestBase is Fixture {
    function test() public pure override {}

    function setUp() public override {
        super.setUp();
    }

    function _createPosition(address _user, uint256 _amount, uint32 _unwindingEpochs) internal {
        vm.prank(address(mintController));
        iusd.mint(_user, _amount);

        vm.startPrank(_user);
        {
            iusd.approve(address(gateway), _amount);
            gateway.createPosition(_amount, _unwindingEpochs, _user);
        }
        vm.stopPrank();
    }

    function _depositRewards(uint256 _amount) public {
        vm.prank(address(mintController));
        iusd.mint(address(yieldSharing), _amount);

        vm.startPrank(address(yieldSharing));
        {
            iusd.approve(address(lockingController), _amount);
            lockingController.depositRewards(_amount);
        }
        vm.stopPrank();
    }

    function _applyLosses(uint256 _amount) public {
        vm.startPrank(address(yieldSharing));
        {
            lockingController.applyLosses(_amount);
        }
        vm.stopPrank();
    }
}
