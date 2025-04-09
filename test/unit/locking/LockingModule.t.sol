// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {LockingTestBase} from "@test/unit/locking/LockingTestBase.t.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";

contract LockingModuleUnitTest is LockingTestBase {
    function testInitialState() public view {
        assertEq(
            iusd.balanceOf(address(lockingController)),
            0,
            "Error: Initial iUSD balance of lockingController should be 0"
        );
        assertEq(lockingController.balanceOf(alice), 0, "Error: Initial alice balance should be 0");
        assertEq(lockingController.balanceOf(bob), 0, "Error: Initial bob balance should be 0");
        assertEq(
            address(lockingController.core()), address(core), "Error: lockingController's core is not set correctly"
        );
        assertEq(
            lockingController.receiptToken(),
            address(iusd),
            "Error: lockingController's receiptToken is not set correctly"
        );
    }

    function testEnableUnwindingEpochs(uint32 _unwindingEpochs) public {
        _unwindingEpochs = uint32(bound(_unwindingEpochs, 13, 100));

        LockedPositionToken _token = new LockedPositionToken(address(core), "name", "symbol");

        vm.expectRevert("UNAUTHORIZED");
        lockingController.enableBucket(_unwindingEpochs, address(_token), 1.5e18);

        assertEq(
            lockingController.unwindingEpochsEnabled(_unwindingEpochs),
            false,
            "Error: Unwinding epochs should not be enabled"
        );

        vm.prank(governorAddress);
        lockingController.enableBucket(_unwindingEpochs, address(_token), 1.5e18);

        assertEq(
            lockingController.unwindingEpochsEnabled(_unwindingEpochs),
            true,
            "Error: Unwinding epochs should be enabled"
        );
    }

    function testMintAndLock(address _user, uint256 _amount, uint32 _unwindingEpochs) public {
        vm.assume(_user != address(0));
        _amount = bound(_amount, 1, 1e12);
        _unwindingEpochs = uint32(bound(_unwindingEpochs, 1, 12));

        vm.startPrank(_user);
        {
            usdc.mint(_user, _amount);
            usdc.approve(address(gateway), _amount);
            gateway.mintAndLock(_user, _amount, _unwindingEpochs);
        }
        vm.stopPrank();

        assertApproxEqAbs(
            lockingController.balanceOf(_user),
            _amount * 1e12,
            1,
            "Error: lockingController's balance is not correct after gateway.mintAndLock"
        );
    }

    function testCreatePosition(address _user, uint256 _amount, uint32 _unwindingEpochs) public {
        vm.assume(_user != address(0));
        _amount = bound(_amount, 1, 1e30);
        _unwindingEpochs = uint32(bound(_unwindingEpochs, 1, 12));

        _createPosition(_user, _amount, _unwindingEpochs);

        assertApproxEqAbs(
            lockingController.balanceOf(_user),
            _amount,
            1,
            "Error: lockingController's balance is not correct after user creates position"
        );
    }

    function testSetBucketMultiplier() public {
        _createPosition(alice, 1000, 10);

        assertEq(lockingController.rewardWeight(alice), 1200, "Error: alice's reward weight is not correct");
        assertEq(lockingController.globalRewardWeight(), 1200, "Error: global reward weight is not correct");

        vm.prank(governorAddress);
        lockingController.setBucketMultiplier(10, 1.5e18);

        assertEq(lockingController.rewardWeight(alice), 1500, "Error: alice's reward weight is not correct");
        assertEq(lockingController.globalRewardWeight(), 1500, "Error: global reward weight is not correct");
    }

    function testRewards() public {
        _createPosition(alice, 1000, 10); // 1200 reward weight
        _createPosition(bob, 2000, 5); // 2200 reward weight

        _depositRewards(34);

        assertApproxEqAbs(lockingController.balanceOf(alice), 1012, 1, "Error: alice's balance is not correct"); // +12
        assertApproxEqAbs(lockingController.balanceOf(bob), 2022, 1, "Error: bob's balance is not correct"); // +22

        _depositRewards(34);

        assertApproxEqAbs(lockingController.balanceOf(alice), 1024, 1, "Error: alice's balance is not correct"); // +12
        assertApproxEqAbs(lockingController.balanceOf(bob), 2044, 1, "Error: bob's balance is not correct"); // +22
    }

    function testSlashing() public {
        // alice locks 1000 for 10 epochs
        _createPosition(alice, 1000, 10);
        assertEq(
            lockingController.shares(alice, 10),
            1000,
            "Error: Alice's share after creating first position is not correct"
        );

        assertEq(lockingController.exchangeRate(10), 1e18, "Error: Exchange rate is not correct");

        // 1000 rewards should all go to alice
        _depositRewards(1000);
        assertApproxEqAbs(
            lockingController.balanceOf(alice),
            2000,
            1,
            "Error: Alice's balance is not correct after depositing rewards"
        );

        assertEq(lockingController.exchangeRate(10), 2e18, "Error: Exchange rate is not correct");

        // 1500 losses should all go to alice
        _applyLosses(1500);
        assertApproxEqAbs(
            lockingController.balanceOf(alice), 500, 1, "Error: Alice's balance is not correct after slashing"
        );

        assertEq(lockingController.exchangeRate(10), 0.5e18, "Error: Exchange rate is not correct");

        // bob locks 500 for 10 epochs
        // this should make both positions equal
        _createPosition(bob, 500, 10);
        assertEq(lockingController.shares(bob, 10), 1000, "Error: Bob's share after creating position is not correct");
        assertApproxEqAbs(
            lockingController.balanceOf(alice), 500, 1, "Error: Alice's balance after creating position is not correct"
        );
        assertApproxEqAbs(
            lockingController.balanceOf(bob), 500, 1, "Error: Bob's balance after creating position is not correct"
        );
        assertEq(
            iusd.balanceOf(address(lockingController)), 1000, "Error: iUSD balance of lockingController is not correct"
        );

        // next rewards should be distributed evenly
        _depositRewards(200);
        assertEq(
            iusd.balanceOf(address(lockingController)),
            1200,
            "Error: iUSD balance of lockingController is not correct after depositing rewards"
        );
        assertApproxEqAbs(
            lockingController.balanceOf(alice), 600, 1, "Error: Alice's balance after depositing rewards is not correct"
        ); // +100
        assertApproxEqAbs(
            lockingController.balanceOf(bob), 600, 1, "Error: Bob's balance after depositing rewards is not correct"
        ); // +100

        assertEq(lockingController.exchangeRate(10), 0.6e18);

        // enable 50 epochs lock that has a 2x multiplier
        LockedPositionToken _token = new LockedPositionToken(address(core), "Locked iUSD - 50 weeks", "liUSD-50w");
        vm.prank(governorAddress);
        lockingController.enableBucket(50, address(_token), 2e18);

        // carol enters the game
        _createPosition(carol, 720, 50); // 1440 reward weight
        assertEq(
            lockingController.shares(carol, 50), 720, "Error: Carol's share after creating position is not correct"
        );
        assertApproxEqAbs(
            lockingController.balanceOf(alice), 600, 1, "Error: Alice's balance after creating position is not correct"
        ); // unchanged, 720 reward weight
        assertApproxEqAbs(
            lockingController.balanceOf(bob), 600, 1, "Error: Bob's balance after creating position is not correct"
        ); // unchanged, 720 reward weight
        assertApproxEqAbs(
            lockingController.balanceOf(carol), 720, 1, "Error: Carol's balance after creating position is not correct"
        ); // 1440 reward weight

        assertEq(lockingController.exchangeRate(10), 0.6e18);
        assertEq(lockingController.exchangeRate(50), 1.0e18);

        // new rewards should go 25% for alice, 25% for bob, 50% for carol
        _depositRewards(720);
        assertApproxEqAbs(
            lockingController.balanceOf(alice), 780, 1, "Error: Alice's balance after depositing rewards is not correct"
        ); // +180
        assertApproxEqAbs(
            lockingController.balanceOf(bob), 780, 1, "Error: Bob's balance after depositing rewards is not correct"
        ); // +180
        assertApproxEqAbs(
            lockingController.balanceOf(carol),
            1080,
            1,
            "Error: Carol's balance after depositing rewards is not correct"
        ); // +360

        assertEq(lockingController.exchangeRate(10), 0.78e18);
        assertEq(lockingController.exchangeRate(50), 1.5e18);
    }

    function testIncreaseUnwindingEpochs() public {
        _createPosition(alice, 1000, 10);

        assertEq(
            lockingController.balanceOf(alice),
            1000,
            "Error: Alice's balance after creating first position is not correct"
        );
        assertEq(
            lockingController.rewardWeight(alice),
            1200,
            "Error: Alice's reward weight after creating first position is not correct"
        );
        assertEq(
            lockingController.shares(alice, 10),
            1000,
            "Error: Alice's share after creating first position is not correct"
        );
        assertEq(
            lockingController.shares(alice, 12),
            0,
            "Error: Alice's share after increasing unwinding epochs is not correct"
        );

        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), 1000);
            gateway.increaseUnwindingEpochs(10, 12);
        }
        vm.stopPrank();

        assertEq(
            lockingController.balanceOf(alice),
            1000,
            "Error: Alice's balance after increasing unwinding epochs is not correct"
        ); // unchanged
        assertEq(
            lockingController.rewardWeight(alice),
            1240,
            "Error: Alice's reward weight after increasing unwinding epochs is not correct"
        ); // +40
        assertEq(
            lockingController.shares(alice, 10),
            0,
            "Error: Alice's share after increasing unwinding epochs is not correct"
        ); // -1000
        assertEq(
            lockingController.shares(alice, 12),
            1000,
            "Error: Alice's share after increasing unwinding epochs is not correct"
        ); // +1000
    }

    function testWithdraw() public {
        _createPosition(alice, 1000, 2);

        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(2)).approve(address(gateway), 1000);
            gateway.startUnwinding(1000, 2);

            uint256 startUnwindingTimestamp = block.timestamp;
            advanceEpoch(3);

            gateway.withdraw(startUnwindingTimestamp);
        }
        vm.stopPrank();

        assertEq(lockingController.balanceOf(alice), 0);
        assertEq(iusd.balanceOf(alice), 1000);
        assertEq(lockingController.shares(alice, 2), 0);
    }
}
