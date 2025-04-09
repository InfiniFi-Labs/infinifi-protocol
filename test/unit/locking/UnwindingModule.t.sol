// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {UnwindingModule} from "@locking/UnwindingModule.sol";
import {LockingTestBase} from "@test/unit/locking/LockingTestBase.t.sol";
import {LockingController} from "@locking/LockingController.sol";

contract UnwindingModuleUnitTest is LockingTestBase {
    function testInitialState() public view {
        assertEq(
            address(unwindingModule.core()), address(core), "Error: UnwindingModule's core address is not set correctly"
        );
        assertEq(
            unwindingModule.receiptToken(), address(iusd), "Error: UnwindingModule's receipt token is not set correctly"
        );
    }

    function testUnwinding() public {
        _createPosition(alice, 1000, 10);
        _createPosition(bob, 2000, 5);

        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), 1000);
            gateway.startUnwinding(1000, 10);
        }
        vm.stopPrank();
        uint256 startUnwindingTimestamp = block.timestamp;

        // unwinding should move alice out of the lockingModule
        assertEq(lockingController.balanceOf(alice), 0, "Error: Alice's balance after unwinding is not correct");
        assertEq(lockingController.balanceOf(bob), 2000, "Error: Bob's balance after unwinding is not correct");
        assertEq(
            lockingController.globalReceiptToken(),
            2000,
            "Error: Global receipt token after unwinding position is not correct"
        );
        assertEq(
            lockingController.globalRewardWeight(),
            2200,
            "Error: Global reward weight after unwinding position is not correct"
        );

        // alice should be in the unwindingModule
        assertEq(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            1000,
            "Error: Alice's balance after unwinding is not correct"
        );
        assertEq(
            unwindingModule.totalReceiptTokens(),
            1000,
            "Error: Total receipt tokens after unwinding position is not correct"
        );
        assertEq(
            unwindingModule.totalRewardWeight(),
            1200,
            "Error: Total reward weight after unwinding position is not correct"
        );

        // rewards should be split between locked & unwinding positions
        _depositRewards(340);
        assertApproxEqAbs(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            1120,
            1,
            "Error: Alice's balance after depositing rewards is not correct"
        ); // +120
        assertApproxEqAbs(
            lockingController.balanceOf(bob), 2220, 1, "Error: Bob's balance after depositing rewards is not correct"
        ); // +220
        assertEq(
            unwindingModule.totalReceiptTokens(),
            1120,
            "Error: Total receipt tokens after depositing rewards is not correct"
        );

        // during unwinding, the reward weight should decrease
        // from 1200 to 1000 over 10 epochs, then stay at 1000
        advanceEpoch(1);
        // at the first epoch after startUnwinding, the reward weight should still be the same,
        // because the unwinding actually starts on the next epoch when initiated. This behavior
        // has been chosen to avoid 1-week locking period from being able to withdraw instantly
        // if unwinding was started just before an epoch transition.
        // A user locking for 1 week will actually need to unwind for a duration between [7, 14[ days
        assertEq(
            unwindingModule.totalRewardWeight(),
            1200,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        );
        // and then, it should decrease by 20 per epoch for 10 epochs
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1180,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1160,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1140,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1120,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1100,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1080,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1060,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1040,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1020,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20, floor at 1000
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        advanceEpoch(99);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
    }

    function testRewardsAndSlashingDuringUnwinding() public {
        _createPosition(alice, 1000, 10);
        _createPosition(bob, 2000, 5);

        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), 1000);
            gateway.startUnwinding(1000, 10);
        }
        vm.stopPrank();
        uint256 startUnwindingTimestamp = block.timestamp;

        advanceEpoch(6);
        assertEq(
            lockingController.globalRewardWeight(),
            2200,
            "Error: global reward weight does not reflect correct amount after advance epoch"
        );
        assertEq(
            unwindingModule.totalRewardWeight(),
            1100,
            "Error: total reward weight does not reflect correct amount after advance epoch"
        );
        _depositRewards(330);
        assertApproxEqAbs(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            1110,
            1,
            "Error: alice's balance does not reflect correct amount after depositing rewards"
        ); // +110
        assertApproxEqAbs(
            lockingController.balanceOf(bob),
            2220,
            1,
            "Error: bob's balance does not reflect correct amount after depositing rewards"
        ); // +220
        assertEq(
            unwindingModule.totalRewardWeight(),
            1100,
            "Error: total reward weight does not reflect correct amount after depositing rewards"
        ); // rewards are non compounding
        assertEq(
            lockingController.globalRewardWeight(),
            2442,
            "Error: global reward weight does not reflect correct amount after depositing rewards"
        ); // +242, rewards are compounding

        // 50% slash
        _applyLosses(3330 / 2);
        assertApproxEqAbs(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            555,
            1,
            "Error: alice's balance does not reflect correct amount after slashing"
        ); // -50%
        assertApproxEqAbs(
            lockingController.balanceOf(bob),
            1110,
            1,
            "Error: bob's balance does not reflect correct amount after slashing"
        ); // -50%
        assertEq(
            lockingController.globalRewardWeight(),
            1221,
            "Error: global reward weight does not reflect correct amount after slashing"
        ); // -50%
        assertEq(
            unwindingModule.totalRewardWeight(),
            550,
            "Error: total reward weight does not reflect correct amount after slashing"
        ); // -50%
        // alice's weight is now decreasing by 10 per epoch & trending to 500
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            540,
            "Error: total reward weight does not reflect correct amount after periods after slashing"
        ); // -10
        assertApproxEqAbs(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            555,
            1,
            "Error: alice's balance does not reflect correct amount after periods after slashing"
        ); // unchanged
        assertApproxEqAbs(
            lockingController.balanceOf(bob),
            1110,
            1,
            "Error: bob's balance does not reflect correct amount after periods after slashing"
        ); // unchanged

        // deposit rewards
        _depositRewards(540 + 1221);
        assertApproxEqAbs(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            1095,
            1,
            "Error: alice's balance does not reflect correct amount after depositing rewards"
        ); // +540
        assertApproxEqAbs(
            lockingController.balanceOf(bob),
            2331,
            1,
            "Error: bob's balance does not reflect correct amount after depositing rewards"
        ); // +1221
        assertEq(
            unwindingModule.totalRewardWeight(),
            540,
            "Error: total reward weight does not reflect correct amount after depositing rewards"
        ); // rewards are non compounding
        assertEq(
            lockingController.globalRewardWeight(),
            2564,
            "Error: global reward weight does not reflect correct amount after depositing rewards"
        ); // +1343 (1.1*1221), rewards are compounding

        // 50% slash
        advanceEpoch(1);
        _applyLosses(3426 / 2);
        assertApproxEqAbs(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            547,
            1,
            "Error: alice's balance does not reflect correct amount after slashing"
        ); // -50%
        assertApproxEqAbs(
            lockingController.balanceOf(bob),
            1165,
            1,
            "Error: bob's balance does not reflect correct amount after slashing"
        ); // -50%
        assertEq(
            lockingController.globalRewardWeight(),
            1281,
            "Error: global reward weight does not reflect correct amount after slashing"
        ); // -50%
        assertEq(unwindingModule.totalRewardWeight(), 265); // -50%
        // alice's weight is now decreasing by 5 per epoch & trending to 250
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            260,
            "Error: total reward weight does not reflect correct amount after periods after slashing"
        ); // -5

        // reward weight of the unwindingModule should floor at 250
        advanceEpoch(99);
        assertEq(
            unwindingModule.totalRewardWeight(),
            250,
            "Error: total reward weight does not reflect correct amount after periods after slashing"
        ); // floor at 250
    }

    function testCancelUnwinding() public {
        _createPosition(alice, 1000, 10);

        assertEq(
            lockingController.globalRewardWeight(), 1200, "Error: global reward weight does not reflect correct amount"
        );

        uint256 startUnwindingTimestamp = block.timestamp;
        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), 1000);
            gateway.startUnwinding(1000, 10);

            // cannot cancel unwinding immediately, must wait for next epoch
            vm.expectRevert(UnwindingModule.UserUnwindingNotStarted.selector);
            gateway.cancelUnwinding(startUnwindingTimestamp, 10);
        }
        vm.stopPrank();

        assertEq(
            lockingController.globalRewardWeight(), 0, "Error: global reward weight does not reflect correct amount"
        );
        assertEq(
            unwindingModule.totalRewardWeight(), 1200, "Error: total reward weight does not reflect correct amount"
        );
        advanceEpoch(6);
        assertEq(
            unwindingModule.totalRewardWeight(), 1100, "Error: total reward weight does not reflect correct amount"
        );

        vm.startPrank(alice);
        {
            // cancel unwinding and relock for 7 epochs
            gateway.cancelUnwinding(startUnwindingTimestamp, 7);
        }
        vm.stopPrank();

        assertEq(
            lockingController.globalRewardWeight(),
            1140,
            "Error: global reward weight does not reflect correct amount after canceling unwinding"
        );
        assertEq(
            unwindingModule.totalRewardWeight(),
            0,
            "Error: total reward weight does not reflect correct amount after canceling unwinding"
        );
        assertEq(
            unwindingModule.totalReceiptTokens(),
            0,
            "Error: total receipt tokens does not reflect correct amount after canceling unwinding"
        );
    }

    function testWithdraw() public {
        _createPosition(alice, 1000, 10);

        assertEq(
            lockingController.globalRewardWeight(),
            1200,
            "Error: global reward weight does not reflect correct amount after creating position"
        );

        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), 1000);
            gateway.startUnwinding(1000, 10);
        }
        vm.stopPrank();
        uint256 startUnwindingTimestamp = block.timestamp;

        assertEq(
            lockingController.globalRewardWeight(),
            0,
            "Error: global reward weight does not reflect correct amount after unwinding"
        );
        assertEq(
            unwindingModule.totalRewardWeight(),
            1200,
            "Error: total reward weight does not reflect correct amount after unwinding"
        );

        // distribute some rewards
        assertEq(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            1000,
            "Error: alice's balance does not reflect correct amount before depositing rewards"
        );
        _depositRewards(100);
        assertEq(
            unwindingModule.balanceOf(alice, startUnwindingTimestamp),
            1100,
            "Error: alice's balance does not reflect correct amount after depositing rewards"
        );
        // go to end of unwinding period
        advanceEpoch(11);

        vm.startPrank(alice);
        {
            gateway.withdraw(startUnwindingTimestamp);
        }
        vm.stopPrank();

        assertEq(lockingController.globalRewardWeight(), 0, "Error: global reward weight should be 0 after withdrawing");
        assertEq(unwindingModule.totalRewardWeight(), 0, "Error: total reward weight should be 0 after withdrawing");

        // 1000 principal + 100 rewards
        assertEq(iusd.balanceOf(alice), 1100, "Error: iUSD balance does not reflect correct amount after withdrawing");
    }
}
