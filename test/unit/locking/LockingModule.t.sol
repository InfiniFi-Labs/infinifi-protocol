// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@test/Fixture.t.sol";
import {MockSwapRouter} from "@test/mock/MockSwapRouter.sol";
import {LockingTestBase} from "@test/unit/locking/LockingTestBase.t.sol";

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

    function testSetMaxLossPercentage() public {
        assertEq(lockingController.maxLossPercentage(), 0.999999e18);

        vm.expectRevert("UNAUTHORIZED");
        lockingController.setMaxLossPercentage(0.5e18);

        vm.prank(governorAddress);
        lockingController.setMaxLossPercentage(0.5e18);

        assertEq(lockingController.maxLossPercentage(), 0.5e18);
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

        vm.prank(parametersAddress);
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
            gateway.increaseUnwindingEpochs(10, 12, 1000);
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

    function testUnstakeAndLock() public {
        uint256 amount = 12345;
        _mintBackedReceiptTokens(alice, amount);

        vm.startPrank(alice);
        iusd.approve(address(siusd), amount);
        uint256 stakedTokenBalance = siusd.deposit(amount, alice);
        vm.stopPrank();

        vm.startPrank(alice);
        {
            siusd.approve(address(gateway), stakedTokenBalance);
            gateway.unstakeAndLock(alice, stakedTokenBalance, 8);
        }
        vm.stopPrank();

        assertEq(siusd.balanceOf(alice), 0);
        assertEq(lockingController.balanceOf(alice), amount);
    }

    function testFullSlashingPauses() public {
        _createPosition(alice, 1000, 10);
        _applyLosses(1000);

        assertTrue(lockingController.paused());
    }

    function testGetEnabledBuckets() public view {
        uint32[] memory enabledBuckets = lockingController.getEnabledBuckets();
        assertEq(enabledBuckets.length, 12);
        assertEq(enabledBuckets[0], 1);
        assertEq(enabledBuckets[11], 12);
    }

    function _zapInAndLock() internal {
        MockSwapRouter router = new MockSwapRouter();
        MockERC20 weth = new MockERC20("Wrapped Ether", "WETH");

        vm.prank(parametersAddress);
        gateway.setEnabledRouter(address(router), true);

        router.mockPrepareSwap(address(weth), address(usdc), 1 ether, 2000e6);
        weth.mint(alice, 1 ether);

        vm.startPrank(alice);
        {
            weth.approve(address(gateway), 1 ether);
            gateway.zapInAndLock(
                address(weth), 1 ether, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector), 10, alice
            );
        }
        vm.stopPrank();
    }

    function testZapInAndLock() public {
        _zapInAndLock();

        assertEq(lockingController.balanceOf(alice), 2000e18);
        assertEq(lockingController.rewardWeight(alice), 2400e18);
    }

    function testZapInAndLockWithFee() public {
        vm.prank(parametersAddress);
        gateway.setZapFee(0.003e18); // set fee to 30 bps (0.3%)
        _zapInAndLock();

        assertEq(lockingController.balanceOf(alice), 1994e18);
    }

    // verifies the invariant that when winding users are wiped out, the locking module is also wiped out
    function testApplyingLossesNotWipingOutOnlyUnwindingUsers(
        uint256 _amountToLocking,
        uint256 _amountToUnwinding,
        uint256 _lossAmount
    ) public {
        // fuzz with deposits between $0.1 and $1T
        _amountToLocking = bound(_amountToLocking, 0, 1e12 * 1e6);
        _amountToUnwinding = bound(_amountToUnwinding, 0, 1e12 * 1e6);

        _lossAmount = bound(_lossAmount, 0, _amountToLocking + _amountToUnwinding) * 1e12;

        vm.assume(_lossAmount > 0);

        dealToken(address(usdc), alice, _amountToLocking);
        dealToken(address(usdc), bob, _amountToUnwinding);

        _createPosition(alice, _amountToLocking, 10);
        _createPosition(bob, _amountToUnwinding, 10);

        vm.startPrank(address(bob));
        {
            MockERC20(lockingController.shareToken(10)).approve(address(gateway), _amountToUnwinding);
            gateway.startUnwinding(_amountToUnwinding, 10);
        }
        vm.stopPrank();

        advanceEpoch(5);

        _applyLosses(_lossAmount);

        bool lockingWipedOut = lockingController.paused();

        if (!lockingWipedOut && _amountToUnwinding > 0) {
            uint256 slashIndex = UnwindingModule(unwindingModule).slashIndex();
            assertNotEq(slashIndex, 0, "Unwinding module should not be wiped out if locking is not paused");
        } else {
            if (_amountToUnwinding > 0) {
                uint256 slashIndex = UnwindingModule(unwindingModule).slashIndex();
                assertEq(slashIndex, 0, "Unwinding module should be wiped out if locking is paused");
            } else {
                // in this case, the locking module is wiped out, but the unwinding module is not as it was empty
                uint256 totalReceiptTokens = UnwindingModule(unwindingModule).totalReceiptTokens();
                assertEq(totalReceiptTokens, 0, "Total receipt tokens should be 0 if locking is wiped out");
                uint256 slashIndex = UnwindingModule(unwindingModule).slashIndex();
                assertEq(slashIndex, 1e18, "Slash index should be 1e18 when locking is paused as it was not affected");
            }
        }
    }

    function testStartUnwindingUnderflow_cantina435(uint256 _depositAmount, uint256 _rewardAmount) public {
        _depositAmount = bound(_depositAmount, 1e18, 1e12 * 1e6);
        _rewardAmount = bound(_rewardAmount, 1, 1e12 * 1e6);

        assertEq(lockingController.globalRewardWeight(), 0);
        assertEq(lockingController.globalReceiptToken(), 0);

        address shareToken = lockingController.shareToken(10);
        // Create 9 positions
        for (uint256 i = 1; i < 10; i++) {
            _createPosition(address(uint160(i)), _depositAmount, 10);
        }

        // Deposit rewards to make rewardWeightDecrease round up
        _depositRewards(_rewardAmount);

        // Start unwinding all 9 positions
        for (uint256 i = 1; i < 10; i++) {
            vm.startPrank(address(uint160(i)));
            {
                MockERC20(shareToken).approve(address(gateway), _depositAmount);
                gateway.startUnwinding(_depositAmount, 10);
            }
            vm.stopPrank();
        }

        assertEq(lockingController.globalRewardWeight(), 0);
        assertEq(lockingController.globalReceiptToken(), 0);
    }

    function testGlobalRewardWeightUnderflow_cantina499(uint256 _depositAmount, uint256 _rewardAmount) public {
        _depositAmount = bound(_depositAmount, 1e6, 1e12 * 1e6);
        _rewardAmount = bound(_rewardAmount, 1, 1e12);

        uint256 iterations = 10;

        // create 9 positions
        for (uint256 i = 1; i < iterations; i++) {
            _createPosition(address(uint160(i)), _depositAmount, 1);
        }

        // deposit rewards
        _depositRewards(_rewardAmount);

        // gradually increaseUnwindingEpochs on all positions to 10
        for (uint256 i = 1; i < iterations; i++) {
            for (uint256 u = 1; u < iterations; u++) {
                address shareToken = lockingController.shareToken(uint32(u));
                uint256 shareTokenBalance = MockERC20(shareToken).balanceOf(address(uint160(i)));
                vm.startPrank(address(uint160(i)));
                {
                    MockERC20(shareToken).approve(address(gateway), shareTokenBalance);
                    gateway.increaseUnwindingEpochs(uint32(u), uint32(u + 1), shareTokenBalance);
                }
                vm.stopPrank();
            }
        }

        // start unwinding all positions
        for (uint256 i = 1; i < iterations; i++) {
            address shareToken = lockingController.shareToken(uint32(iterations));
            uint256 shareTokenBalance = MockERC20(shareToken).balanceOf(address(uint160(i)));
            vm.startPrank(address(uint160(i)));
            {
                MockERC20(shareToken).approve(address(gateway), shareTokenBalance);
                gateway.startUnwinding(shareTokenBalance, uint32(iterations));
            }
            vm.stopPrank();
        }

        uint256 startUnwindingTimestamp = block.timestamp;

        advanceEpoch(11);

        for (uint256 i = 1; i < iterations; i++) {
            vm.prank(address(uint160(i)));
            gateway.withdraw(startUnwindingTimestamp);
        }

        uint256 unwindingModuleRewardWeight = UnwindingModule(unwindingModule).totalRewardWeight();
        assertEq(unwindingModuleRewardWeight, 0, "unwindingModuleRewardWeight should be 0");

        uint256 globalRewardWeight = lockingController.globalRewardWeight();
        assertEq(globalRewardWeight, 0, "globalRewardWeight should be 0");
    }

    function testGlobalRewardWeightUnderflow_cantina499_invariantBreaks(uint256 _depositAmount, uint256 _rewardAmount)
        public
    {
        _depositAmount = bound(_depositAmount, 1e6, 1e12 * 1e6);
        _rewardAmount = bound(_rewardAmount, 1, 1e12);

        uint256 iterations = 10;

        // create 9 positions
        for (uint256 i = 1; i < iterations; i++) {
            _createPosition(address(uint160(i)), _depositAmount, 1);
        }

        // deposit rewards
        _depositRewards(_rewardAmount);

        // gradually increaseUnwindingEpochs on all positions to 10
        for (uint256 i = 1; i < iterations; i++) {
            for (uint256 u = 1; u < iterations; u++) {
                address shareToken = lockingController.shareToken(uint32(u));
                uint256 shareTokenBalance = MockERC20(shareToken).balanceOf(address(uint160(i)));
                vm.startPrank(address(uint160(i)));
                {
                    MockERC20(shareToken).approve(address(gateway), shareTokenBalance);
                    gateway.increaseUnwindingEpochs(uint32(u), uint32(u + 1), shareTokenBalance);
                }
                vm.stopPrank();
            }
        }

        // start unwinding all positions
        for (uint256 i = 1; i < iterations; i++) {
            address shareToken = lockingController.shareToken(uint32(iterations));
            uint256 shareTokenBalance = MockERC20(shareToken).balanceOf(address(uint160(i)));
            vm.startPrank(address(uint160(i)));
            {
                MockERC20(shareToken).approve(address(gateway), shareTokenBalance);
                gateway.startUnwinding(shareTokenBalance, uint32(iterations));
            }
            vm.stopPrank();
        }

        uint256 startUnwindingTimestamp = block.timestamp;

        advanceEpoch(11);

        for (uint256 i = 1; i < iterations; i++) {
            vm.prank(address(uint160(i)));
            gateway.withdraw(startUnwindingTimestamp);
        }

        uint256 individualRewardWeight = 0;
        for (uint256 i = 1; i < iterations; i++) {
            for (uint256 u = 1; u < iterations; u++) {
                individualRewardWeight +=
                    lockingController.rewardWeightForUnwindingEpochs(address(uint160(i)), uint32(u));
            }
        }

        uint256 globalRewardWeight = lockingController.globalRewardWeight();

        assertGe(
            globalRewardWeight,
            individualRewardWeight,
            "globalRewardWeight should be greater or equal than sum of individualRewardWeight"
        );
    }
}
