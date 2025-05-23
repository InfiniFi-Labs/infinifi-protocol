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

        advanceEpoch(1);

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
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1200,
            "Error: Alice's reward weight after unwinding is not correct"
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
        assertEq(
            unwindingModule.totalRewardWeight(),
            1200,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        );
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1200,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        );
        // and then, it should decrease by 20 per epoch for 10 epochs
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1180,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1180,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1160,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1160,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1140,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1140,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1120,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1120,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1100,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1100,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1080,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1080,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1060,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1060,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1040,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1040,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1020,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20
        assertEq(unwindingModule.rewardWeight(alice, startUnwindingTimestamp), 1020, "a"); // -20
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20, floor at 1000
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1000,
            "Error: Alice's reward weight does not reflect correct amount after advance epoch in first 10 epochs"
        ); // -20, floor at 1000
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1000,
            "Error: Alice's reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        advanceEpoch(1);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1000,
            "Error: Alice's reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        advanceEpoch(99);
        assertEq(
            unwindingModule.totalRewardWeight(),
            1000,
            "Error: Total reward weight should not change after advance epoch after 10 epochs"
        ); // unchanged
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1000,
            "Error: Alice's reward weight should not change after advance epoch after 10 epochs"
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
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            1100,
            "Error: alice's reward weight does not reflect correct amount after advance epoch"
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
        assertEq(
            unwindingModule.rewardWeight(alice, startUnwindingTimestamp),
            550,
            "Error: alice's reward weight does not reflect correct amount after slashing"
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
        assertApproxEqAbs(
            lockingController.globalRewardWeight(),
            1281,
            2,
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
        advanceEpoch(1);

        assertEq(
            lockingController.globalRewardWeight(), 0, "Error: global reward weight does not reflect correct amount"
        );
        assertEq(
            unwindingModule.totalRewardWeight(), 1200, "Error: total reward weight does not reflect correct amount"
        );
        advanceEpoch(6);
        assertEq(
            unwindingModule.totalRewardWeight(), 1080, "Error: total reward weight does not reflect correct amount"
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
        advanceEpoch(1);

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

    function testClaimRewardsFromLCandWM() public {
        _createPosition(alice, 1000, 10);
        _createPosition(bob, 2000, 5);

        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), 1000);
            gateway.startUnwinding(1000, 10);
        }
        vm.stopPrank();
        uint256 aliceUnwindingTimestamp = block.timestamp;

        assertEq(unwindingModule.totalRewardWeight(), 0);

        advanceEpoch(1);

        assertEq(unwindingModule.totalRewardWeight(), 1200);

        advanceEpoch(5);

        assertEq(lockingController.globalRewardWeight(), 2200);
        assertEq(unwindingModule.totalRewardWeight(), 1100);
        assertEq(unwindingModule.balanceOf(alice, aliceUnwindingTimestamp), 1000);
        assertEq(lockingController.balanceOf(bob), 2000);

        _depositRewards(330);

        assertEq(unwindingModule.balanceOf(alice, aliceUnwindingTimestamp), 1110); // +110
        assertEq(lockingController.balanceOf(bob), 2220); // +220
        assertEq(unwindingModule.totalRewardWeight(), 1100); // unchanged

        vm.startPrank(bob);
        {
            MockERC20(lockingController.shareToken(5)).approve(address(gateway), 2000);
            gateway.startUnwinding(2000, 5);
        }
        vm.stopPrank();
        uint256 bobUnwindingTimestamp = block.timestamp;

        assertEq(unwindingModule.totalRewardWeight(), 1100); // unchanged

        // balances should be unchanged after bob starts unwinding
        assertEq(unwindingModule.balanceOf(alice, aliceUnwindingTimestamp), 1110);
        assertEq(unwindingModule.balanceOf(bob, bobUnwindingTimestamp), 2220);

        // after starting to unwind, bob is not earning any rewards for the remaining
        // of the epoch where they started to unwind.

        _depositRewards(70);

        assertEq(unwindingModule.balanceOf(alice, aliceUnwindingTimestamp), 1180); // +70
        assertEq(unwindingModule.balanceOf(bob, bobUnwindingTimestamp), 2220); // +0

        advanceEpoch(1);

        // bob has 2220 tokens with a weight of *1.1 = 2442 at the start
        // with the rounding loss correction, bob's reward weight is 2440
        // every epoch, bob's reward weight decrease by (2440 - 2220) / 5 = 44
        assertEq(unwindingModule.totalRewardWeight(), 1080 + 2440);

        // after the epoch transition, bob is earning rewards again in the unwinding module

        assertEq(unwindingModule.balanceOf(alice, aliceUnwindingTimestamp), 1180); // unchanged
        assertEq(unwindingModule.balanceOf(bob, bobUnwindingTimestamp), 2220); // unchanged

        _depositRewards(352);

        assertEq(unwindingModule.balanceOf(alice, aliceUnwindingTimestamp), 1180 + 108); // +108
        assertEq(unwindingModule.balanceOf(bob, bobUnwindingTimestamp), 2220 + 244); // +244

        assertEq(unwindingModule.totalRewardWeight(), 1080 + 2440); // unchanged

        // check future reward weight changes
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1060 + 2396); // -20 for alice, -44 for bob
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1040 + 2352); // -20 for alice, -44 for bob
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1020 + 2308); // -20 for alice, -44 for bob
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1000 + 2264); // -20 for alice, -44 for bob
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1000 + 2220); // unchanged for alice, -44 for bob
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1000 + 2220); // unchanged for alice & bob
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1000 + 2220); // unchanged for alice & bob
    }

    function testCancelUnwindingNextEpoch() public {
        // alice & bob lock for 10 weeks and start unwinding
        _createPosition(alice, 1000e18, 10);
        _createPosition(bob, 1000e18, 10);
        uint256 startUnwindingTimestamp = block.timestamp;
        vm.startPrank(alice);
        {
            address shareToken = lockingController.shareToken(10);
            uint256 shareTokenBalance = MockERC20(shareToken).balanceOf(alice);
            MockERC20(shareToken).approve(address(gateway), shareTokenBalance);
            gateway.startUnwinding(shareTokenBalance, 10);
        }
        vm.stopPrank();
        vm.startPrank(bob);
        {
            address shareToken = lockingController.shareToken(10);
            uint256 shareTokenBalance = MockERC20(shareToken).balanceOf(bob);
            MockERC20(shareToken).approve(address(gateway), shareTokenBalance);
            gateway.startUnwinding(shareTokenBalance, 10);
        }
        vm.stopPrank();

        // when they start unwinding, they won't earn any rewards until the next epoch
        // but on next epoch, their reward weight is accounted in the unwindingModule
        assertEq(unwindingModule.totalRewardWeight(), 0);
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 2400e18);

        // alice cancels her unwinding
        vm.startPrank(alice);
        {
            gateway.cancelUnwinding(startUnwindingTimestamp, 10);
        }
        vm.stopPrank();

        // alice's reward weight is not accounted in the unwindingModule anymore
        assertEq(unwindingModule.totalRewardWeight(), 1200e18);

        // on the next epochs, the total reward weight should decrease
        // by bob's unwinding reward weight decrease
        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1180e18);

        advanceEpoch(1);
        assertEq(unwindingModule.totalRewardWeight(), 1160e18);
    }

    function testUnwindingCancelErwanCertoraInvestigation() public {
        _createPosition(alice, 100e18, 10);
        _createPosition(bob, 10e18, 5);
        _createPosition(carol, 10e18, 5);
        advanceEpoch(1);

        assertEq(lockingController.balanceOf(alice), 100e18);
        assertEq(lockingController.balanceOf(bob), 10e18);
        assertEq(lockingController.balanceOf(carol), 10e18);
        assertEq(lockingController.rewardWeight(alice), 120e18); // 1.2x multiplier
        assertEq(lockingController.rewardWeight(bob), 11e18); // 1.1x multiplier
        assertEq(lockingController.rewardWeight(carol), 11e18); // 1.1x multiplier
        assertEq(lockingController.globalReceiptToken(), 120e18);
        assertEq(lockingController.globalRewardWeight(), 142e18);
        assertEq(unwindingModule.totalReceiptTokens(), 0);
        assertEq(unwindingModule.totalRewardWeight(), 0);

        // Bob starts unwinding
        vm.startPrank(bob);
        {
            address bobShareToken = lockingController.shareToken(5);
            uint256 bobShareTokenBalance = MockERC20(bobShareToken).balanceOf(bob);
            MockERC20(bobShareToken).approve(address(gateway), bobShareTokenBalance);
            gateway.startUnwinding(bobShareTokenBalance, 5);
        }
        vm.stopPrank();

        // Alice starts unwinding
        vm.startPrank(alice);
        {
            address aliceShareToken = lockingController.shareToken(10);
            uint256 aliceShareTokenBalance = MockERC20(aliceShareToken).balanceOf(alice);
            MockERC20(aliceShareToken).approve(address(gateway), aliceShareTokenBalance);
            gateway.startUnwinding(aliceShareTokenBalance, 10);
        }
        vm.stopPrank();
        uint256 unwindingTimestamp = block.timestamp;

        assertEq(lockingController.balanceOf(alice), 0);
        assertEq(lockingController.balanceOf(bob), 0);
        assertEq(lockingController.balanceOf(carol), 10e18);
        assertEq(lockingController.rewardWeight(alice), 0);
        assertEq(lockingController.rewardWeight(bob), 0);
        assertEq(lockingController.rewardWeight(carol), 11e18);
        assertEq(lockingController.globalReceiptToken(), 10e18);
        assertEq(lockingController.globalRewardWeight(), 11e18);

        assertEq(unwindingModule.balanceOf(alice, unwindingTimestamp), 100e18);
        assertEq(unwindingModule.balanceOf(bob, unwindingTimestamp), 10e18);
        assertEq(unwindingModule.rewardWeight(alice, unwindingTimestamp), 0);
        assertEq(unwindingModule.rewardWeight(bob, unwindingTimestamp), 0);
        assertEq(unwindingModule.totalReceiptTokens(), 110e18);
        assertEq(unwindingModule.totalRewardWeight(), 0);

        advanceEpoch(1);

        assertEq(lockingController.balanceOf(carol), 10e18);
        assertEq(lockingController.rewardWeight(carol), 11e18);
        assertEq(lockingController.globalReceiptToken(), 10e18);
        assertEq(lockingController.globalRewardWeight(), 11e18);

        assertEq(unwindingModule.balanceOf(alice, unwindingTimestamp), 100e18);
        assertEq(unwindingModule.balanceOf(bob, unwindingTimestamp), 10e18);
        assertEq(unwindingModule.rewardWeight(alice, unwindingTimestamp), 120e18);
        assertEq(unwindingModule.rewardWeight(bob, unwindingTimestamp), 11e18);
        assertEq(unwindingModule.totalReceiptTokens(), 110e18);
        assertEq(unwindingModule.totalRewardWeight(), 131e18);

        advanceEpoch(5);

        assertEq(lockingController.balanceOf(carol), 10e18);
        assertEq(lockingController.rewardWeight(carol), 11e18);
        assertEq(lockingController.globalReceiptToken(), 10e18);
        assertEq(lockingController.globalRewardWeight(), 11e18);

        assertEq(unwindingModule.balanceOf(alice, unwindingTimestamp), 100e18);
        assertEq(unwindingModule.balanceOf(bob, unwindingTimestamp), 10e18);
        assertEq(unwindingModule.rewardWeight(alice, unwindingTimestamp), 110e18);
        assertEq(unwindingModule.rewardWeight(bob, unwindingTimestamp), 10e18);
        assertEq(unwindingModule.totalReceiptTokens(), 110e18);
        assertEq(unwindingModule.totalRewardWeight(), 120e18);

        // alice cancels her unwinding
        vm.prank(alice);
        gateway.cancelUnwinding(unwindingTimestamp, 10);

        assertEq(lockingController.balanceOf(alice), 100e18);
        assertEq(lockingController.rewardWeight(alice), 120e18);
        assertEq(lockingController.balanceOf(carol), 10e18);
        assertEq(lockingController.rewardWeight(carol), 11e18);
        assertEq(lockingController.globalReceiptToken(), 110e18);
        assertEq(lockingController.globalRewardWeight(), 131e18);

        assertEq(unwindingModule.balanceOf(alice, unwindingTimestamp), 0);
        assertEq(unwindingModule.balanceOf(bob, unwindingTimestamp), 10e18);
        assertEq(unwindingModule.rewardWeight(alice, unwindingTimestamp), 0);
        assertEq(unwindingModule.rewardWeight(bob, unwindingTimestamp), 10e18);
        assertEq(unwindingModule.totalReceiptTokens(), 10e18);
        assertEq(unwindingModule.totalRewardWeight(), 10e18);

        _depositRewards(141e18);

        assertEq(lockingController.balanceOf(alice), 100e18 + 120e18);
        assertEq(lockingController.balanceOf(carol), 10e18 + 11e18);
        assertEq(unwindingModule.balanceOf(bob, unwindingTimestamp), 10e18 + 10e18);
    }

    // fuzz the situation where users are canceling their unwinding
    // halfway through, or going through the full unwinding period and then
    // withdrawing. After all users are done exiting, the unwinding module
    // should not have any leftover tokens or reward weight.
    function testNoSharesLeftAfterExit(uint256 seed) public {
        uint256 lockAmount = _bound(seed, 3, 1000e18);
        uint256 rewards = _bound(seed, 1, 100e18);
        uint256 startUnwindingTimestamp = block.timestamp;

        // alice starts unwinding
        _createPosition(alice, lockAmount, 10);
        vm.startPrank(alice);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), lockAmount);
            gateway.startUnwinding(lockAmount, 10);
        }
        vm.stopPrank();

        // bob starts unwinding (half of alice's position size)
        _createPosition(bob, lockAmount / 2, 10);
        vm.startPrank(bob);
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), lockAmount / 2);
            gateway.startUnwinding(lockAmount / 2, 10);
        }
        vm.stopPrank();

        // distribute some rewards
        advanceEpoch(1);
        _depositRewards(rewards);

        // halfway through, bob cancels unwinding
        advanceEpoch(5);
        vm.startPrank(bob);
        {
            gateway.cancelUnwinding(startUnwindingTimestamp, 5);
        }
        vm.stopPrank();

        // alice withdraws
        advanceEpoch(5);
        vm.startPrank(alice);
        {
            gateway.withdraw(startUnwindingTimestamp);
        }
        vm.stopPrank();

        // tolerate at most 1 wei of rounding errors in favor of the protocol after
        // all users are done exiting the system.
        // the leftover shares are due to unclaimable reward shares since
        // everyone's reward shares are rounded down.
        // the leftover receiptTokens are due to everyone's share to receiptTokens
        // conversion rounding down, and the leftover shares that are unclaimable.
        uint256 tolerance = 1;
        assertApproxEqAbs(unwindingModule.totalReceiptTokens(), 0, tolerance);
        assertApproxEqAbs(unwindingModule.totalShares(), 0, tolerance);
        assertEq(unwindingModule.totalRewardWeight(), 0);
    }
}
