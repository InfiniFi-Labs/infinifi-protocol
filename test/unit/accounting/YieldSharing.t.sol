// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";

contract YieldSharingUnitTest is Fixture {
    function setUp() public override {
        super.setUp();

        // set iUSD price to 0.5$
        // this will help test that the formula have proper behavior when the price is not 1$
        vm.prank(oracleManagerAddress);
        oracleIusd.setPrice(0.5e18);
    }

    function testInitialState() public view {
        assertEq(yieldSharing.unaccruedYield(), 0, "Error: Unaccrued yield is not 0 at initialization");
    }

    function testUnaccruedYield() public {
        // airdrop usdc to a farm
        farm1.mockProfit(1000e6); // 1000 USDC in farm

        assertEq(yieldSharing.unaccruedYield(), 2000e18, "Error: Unaccrued yield does not increase after deposit"); // 1000$ in protocol

        // mint new iUSD in circulation
        vm.prank(address(mintController));
        iusd.mint(address(this), 1400e18); // +1400 iUSD in circulation

        assertEq(
            yieldSharing.unaccruedYield(), 600e18, "Error: Unaccrued yield does not increase after user stakes iUSD"
        ); // 300$ in protocol
    }

    function testAccrueProfitNoRecipients() public {
        // airdrop usdc to a farm & accrue
        farm1.mockProfit(1000e6); // 1000 USDC in farm
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)),
            2000e18,
            "Error: iUSD balance of yieldSharing is not updated after accrue()"
        );
        assertEq(yieldSharing.unaccruedYield(), 0, "Error: Unaccrued yield should be 0 after accrue");
    }

    function testAccrueProfitOnlySavingRecipients() public {
        // 1 depositor of 500$ in siUSD
        usdc.mint(address(this), 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mintAndStake(address(this), 500e6);
        vm.warp(block.timestamp + 10);

        assertEq(
            siusd.balanceOf(address(this)),
            1000e18,
            "Error: siusd balance of user is not updated after user's mintAndStake"
        );
        assertEq(siusd.totalAssets(), 1000e18, "Error: siusd total assets is not updated after user's mintAndStake");

        // simulate 10$ profit
        farm1.mockProfit(10e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)), 0, "Error: iUSD balance of profit sharing should be 0 after accrue"
        );
        assertEq(
            iusd.balanceOf(address(siusd)), 1020e18, "Error: iUSD balance of siusd should be increase after accrue"
        );
        assertEq(lockingController.totalBalance(), 0, "Error: lockingController total balance should be 0 after accrue");
        assertEq(yieldSharing.unaccruedYield(), 0, "Error: Unaccrued yield should be 0 after accrue");
    }

    function testAccrueProfitOnlylockingRecipients() public {
        // alice deposits 500$ and bonds for 4 epochs
        vm.startPrank(alice);
        usdc.mint(alice, 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mint(alice, 500e6);
        vm.warp(block.timestamp + 10);
        iusd.approve(address(gateway), 1000e18);
        gateway.createPosition(1000e18, 4, alice);
        vm.stopPrank();

        // simulate 10$ profit
        farm1.mockProfit(10e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)), 0, "Error: iUSD balance of profit sharing should be 0 after accrue"
        );
        assertEq(iusd.balanceOf(address(siusd)), 0, "Error: iUSD balance of siusd should be 0 after accrue");
        assertEq(
            lockingController.totalBalance(),
            1020e18,
            "Error: lockingController total balance should increase after accrue"
        );
        assertEq(yieldSharing.unaccruedYield(), 0, "Error: Unaccrued yield should be 0 after accrue");
    }

    function testAccrueProfitSavingsAndlockingRecipients() public {
        // alice deposits 500$ and bonds for 4 epochs
        vm.startPrank(alice);
        usdc.mint(alice, 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mint(alice, 500e6);
        vm.warp(block.timestamp + 10);
        iusd.approve(address(gateway), 1000e18);
        gateway.createPosition(1000e18, 10, alice);
        vm.stopPrank();

        // 1 depositor of 500$ in siUSD
        usdc.mint(address(this), 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mintAndStake(address(this), 500e6);
        vm.warp(block.timestamp + 10);

        // simulate 22$ profit
        farm1.mockProfit(22e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)), 0, "Error: iUSD balance of profit sharing should be 0 after accrue"
        );
        assertEq(
            iusd.balanceOf(address(siusd)), 1000e18 + 20e18, "Error: iUSD balance of siusd should increase after accrue"
        ); // 10$ to staking
        assertEq(
            lockingController.totalBalance(),
            1024e18,
            "Error: lockingController total balance should increase after accrue"
        ); // 12$ to locking
    }

    function testAccrueProfitFillsSafetyBufferFirst() public {
        testAccrueProfitSavingsAndlockingRecipients();

        // set safety buffer size to 10$
        vm.prank(parametersAddress);
        yieldSharing.setSafetyBufferSize(20e18);

        // simulate 5$ profit
        farm1.mockProfit(5e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)),
            10e18,
            "Error: iUSD balance of profitSharing should increase after accrue"
        ); // 5$ to safety buffer

        // simulate 20$ profit
        farm1.mockProfit(20e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)),
            20e18,
            "Error: iUSD balance of yieldSharing should increase after accrue"
        ); // 5$ + 5$ to safety buffer

        // any further profits should not continue to fill the buffer
        // simulate 100$ profit
        farm1.mockProfit(100e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(yieldSharing)),
            20e18,
            "Error: iUSD balance of yieldSharing should not change after accrue"
        ); // still 10$ to safety buffer
    }

    function testAccrueLossesNoSlashing() public {
        testAccrueProfitNoRecipients();

        // empty safety buffer that was filled
        // due to no recipients on previous profit distribution
        vm.prank(address(yieldSharing));
        iusd.transfer(address(this), 2000e18);

        // simulate 100$ loss in 1000$ farm
        farm1.mockLoss(100e6);
        yieldSharing.accrue();

        assertEq(oracleIusd.price(), 0.45e18, "Error: oracleIusd price should decrease after accrue"); // 0.5$ -> 0.45$ peg
    }

    function testAccrueLossesConsumeSafetyBufferFirst() public {
        testAccrueProfitFillsSafetyBufferFirst();

        // simulate 5$ loss (10$ buffer)
        farm1.mockLoss(5e6);
        yieldSharing.accrue();

        assertEq(iusd.balanceOf(address(yieldSharing)), 10e18); // 5$ left in safety buffer

        // simulate 7$ loss that exceeds the 5$ left in buffer
        uint256 lockingBalanceBefore = lockingController.totalBalance();
        farm1.mockLoss(7e6);
        yieldSharing.accrue();
        uint256 lockingBalanceAfter = lockingController.totalBalance();
        uint256 lockingLoss = lockingBalanceBefore - lockingBalanceAfter;

        assertEq(
            iusd.balanceOf(address(yieldSharing)),
            10e18,
            "Error: iUSD balance of yieldSharing should not change after accrue"
        ); // safety buffer untouched
        assertEq(lockingLoss, 14e18, "Error: lockingLoss should increase after accrue"); // 7$ slash on locking
    }

    function testAccrueLossesSlashOnlySavings() public {
        testAccrueProfitOnlySavingRecipients();

        // simulate 5$ loss in farm
        farm1.mockLoss(5e6);
        yieldSharing.accrue();

        assertEq(
            iusd.balanceOf(address(siusd)), 1020e18 - 10e18, "Error: iUSD balance of siusd should decrease after accrue"
        ); // 5$ slash on staking
    }

    function testAccrueLossesSlashOnlylocking() public {
        testAccrueProfitOnlylockingRecipients();

        // simulate 5$ loss in farm
        farm1.mockLoss(5e6);
        yieldSharing.accrue();

        assertEq(
            lockingController.totalBalance(),
            1000e18 - 10e18 + 20e18,
            "Error: lockingController total balance should increase after accrue"
        ); // 5$ slash on locking
    }

    function testAccrueLossesSlashlockingFirst() public {
        testAccrueProfitSavingsAndlockingRecipients();

        // simulate 5$ loss in farm
        farm1.mockLoss(5e6);
        yieldSharing.accrue();

        assertEq(
            lockingController.totalBalance(),
            1000e18 - 10e18 + 24e18,
            "Error: lockingController total balance should increase after accrue"
        ); // 5$ slash on locking
        assertEq(iusd.balanceOf(address(siusd)), 1020e18, "Error: iUSD balance of siusd should not change after accrue"); // no slash on savings
    }

    function testAccrueLossesSlashlockingAndSavingFirst() public {
        testAccrueProfitSavingsAndlockingRecipients();

        // simulate 600$ loss in mintController
        usdc.mockBurn(address(mintController), 600e6);
        yieldSharing.accrue();

        assertEq(iusd.balanceOf(address(siusd)), 1020e18 - 176e18); // 176 slashed
        assertEq(lockingController.totalBalance(), 0); // 1024 slashed
    }

    function testAccrueLossesSlashlockingAndSavingFirstThenUpdatePeg() public {
        testAccrueProfitSavingsAndlockingRecipients();

        // alice deposits 500$ and holds it idle
        vm.startPrank(alice);
        usdc.mint(alice, 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mint(alice, 500e6);
        vm.warp(block.timestamp + 10);

        // simulate 1100$ loss in mintController
        usdc.balanceOf(address(mintController));
        usdc.balanceOf(address(farm1));
        usdc.mockBurn(address(mintController), 1100e6);
        // simulate 22$ loss in farm
        farm1.mockLoss(22e6);
        yieldSharing.accrue();

        // total backing is now 400$
        assertEq(accounting.totalAssetsValue(), 400e18);
        // 1024 in locking is slashed
        // 1020 in savings is slashed
        // 1000 held idle by alice still exists
        assertEq(iusd.balanceOf(address(siusd)), 0, "Error: iUSD balance of siusd should be 0 after accrue"); // full slash overflows to savings
        assertEq(lockingController.totalBalance(), 0, "Error: lockingController total balance should be 0 after accrue"); // full slash on locking
        assertEq(iusd.totalSupply(), 1000e18, "Error: iUSD total supply should not change after accrue");

        // 0.5 * 0.8 = 0.4
        assertEq(oracleIusd.price(), 0.4e18, "Error: oracleIusd price should decrease after accrue");
    }

    function testSetPerformanceFeeAndRecipient() public {
        vm.prank(parametersAddress);
        yieldSharing.setPerformanceFeeAndRecipient(0.05e18, address(this));

        // simulate 10$ profit
        farm1.mockProfit(10e6);
        yieldSharing.accrue();

        assertEq(iusd.balanceOf(address(this)), 1e18, "Error: iUSD balance of this should increase after accrue"); // received 5% of 10$

        vm.prank(parametersAddress);
        yieldSharing.setPerformanceFeeAndRecipient(0, address(this));

        // simulate 20$ profit
        farm1.mockProfit(20e6);
        yieldSharing.accrue();

        assertEq(iusd.balanceOf(address(this)), 1e18, "Error: iUSD balance of this should not change after accrue"); // unchanged

        vm.prank(parametersAddress);
        yieldSharing.setPerformanceFeeAndRecipient(0, address(0));

        // simulate 10$ profit
        farm1.mockProfit(10e6);
        yieldSharing.accrue();

        assertEq(iusd.balanceOf(address(this)), 1e18, "Error: iUSD balance of this should not change after accrue"); // unchanged

        vm.prank(parametersAddress);
        yieldSharing.setPerformanceFeeAndRecipient(0.05e18, address(this));

        // simulate 10$ profit
        farm1.mockProfit(10e6);
        yieldSharing.accrue();

        assertEq(iusd.balanceOf(address(this)), 2e18, "Error: iUSD balance of this should increase after accrue"); // + 5% of 10$
    }

    function testSetLiquidReturnMultiplier() public {
        // alice deposits 500$ and locks for 10 epochs
        vm.startPrank(alice);
        usdc.mint(alice, 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mint(alice, 500e6);
        vm.warp(block.timestamp + 10);
        iusd.approve(address(gateway), 1000e18);
        gateway.createPosition(1000e18, 10, alice);
        vm.stopPrank();

        // 1 depositor of 500$ in siUSD
        usdc.mint(address(this), 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mintAndStake(address(this), 500e6);
        vm.warp(block.timestamp + 10);

        uint256 liquidBalanceBefore = iusd.balanceOf(address(siusd));
        uint256 lockingBalanceBefore = lockingController.totalBalance();

        vm.prank(parametersAddress);
        yieldSharing.setLiquidReturnMultiplier(1.5e18); // 150%

        // simulate 27$ profit
        // 15$ should go to savings
        // 12$ should go to locking
        farm1.mockProfit(27e6);
        yieldSharing.accrue();

        uint256 liquidBalanceAfter = iusd.balanceOf(address(siusd));
        uint256 lockingBalanceAfter = lockingController.totalBalance();
        uint256 liquidRewards = liquidBalanceAfter - liquidBalanceBefore;
        uint256 lockingRewards = lockingBalanceAfter - lockingBalanceBefore;

        assertEq(liquidRewards, 30e18, "Error: liquidRewards should increase after accrue"); // +15$ to savings
        assertEq(lockingRewards, 24e18, "Error: lockingRewards should increase after accrue"); // +12$ to locking
        assertEq(yieldSharing.unaccruedYield(), 0, "Error: Unaccrued yield should be 0 after accrue");
    }

    function testTargetIlliquidRatio() public {
        // alice deposits 500$ and bonds for 10 epochs
        vm.startPrank(alice);
        usdc.mint(alice, 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mint(alice, 500e6);
        vm.warp(block.timestamp + 10);
        iusd.approve(address(gateway), 1000e18);
        gateway.createPosition(1000e18, 10, alice);
        vm.stopPrank();

        // 1 depositor of 500$ in siUSD
        usdc.mint(address(this), 500e6);
        usdc.approve(address(gateway), 500e6);
        gateway.mintAndStake(address(this), 500e6);
        vm.warp(block.timestamp + 10);

        uint256 liquidBalanceBefore = iusd.balanceOf(address(siusd));
        uint256 lockingBalanceBefore = lockingController.totalBalance();

        // set target illiquid to 70%
        // iUSD in siUSD: 1000
        // iUSD in locking module: 1000
        // currently, 50% of iUSD is in locking module, but we target 70%,
        // so we treat the 1000 iUSD in locking module as 1400 iUSD for reward
        // distributions. With the 1.2x multiplier, this means 1680 iUSD total weight.
        vm.prank(parametersAddress);
        yieldSharing.setTargetIlliquidRatio(0.7e18); // 70%

        // simulate 268$ profit
        // 100$ should go to savings
        // 168$ should go to locking
        farm1.mockProfit(268e6);
        yieldSharing.accrue();

        uint256 liquidBalanceAfter = iusd.balanceOf(address(siusd));
        uint256 lockingBalanceAfter = lockingController.totalBalance();
        uint256 liquidRewards = liquidBalanceAfter - liquidBalanceBefore;
        uint256 lockingRewards = lockingBalanceAfter - lockingBalanceBefore;

        assertEq(liquidRewards, 200e18, "Error: liquidRewards should increase after accrue"); // +100$ to savings
        assertEq(lockingRewards, 336e18, "Error: lockingRewards should increase after accrue"); // +168$ to locking
        assertEq(yieldSharing.unaccruedYield(), 0, "Error: Unaccrued yield should be 0 after accrue");
    }

    function testTryManipulateLiquidIlliquidRatio() public {
        // alice deposits 500$ and bonds for 10 epochs
        vm.startPrank(alice);
        {
            usdc.mint(alice, 500e6);
            usdc.approve(address(gateway), 500e6);
            gateway.mintAndLock(alice, 500e6, 10);
        }
        vm.stopPrank();

        // bob deposits 500$ and stakes
        vm.startPrank(bob);
        {
            usdc.mint(bob, 500e6);
            usdc.approve(address(gateway), 500e6);
            gateway.mintAndStake(bob, 500e6);
        }
        vm.stopPrank();

        vm.warp(block.timestamp + 10);

        // simulate 22$ profit
        farm1.mockProfit(22e6);
        // a malicious actor tries to sandwich the accrue() call and skew
        // rewards towards the liquid side by atomically doing a large liquid
        // deposit, accrue, and redeem (presumably with a flashloan), with the
        // intent of earning more rewards on the liquid side on the next epoch.
        vm.startPrank(carol);
        {
            usdc.mint(carol, 1_000_000e6);
            usdc.approve(address(gateway), 1_000_000e6);
            gateway.mintAndStake(carol, 1_000_000e6);
            yieldSharing.accrue();
            siusd.redeem(2_000_000e18, address(carol), address(carol));
        }
        vm.stopPrank();

        // if manipulation were successful, most rewards should
        // have gone to the liquid side instead of the 10/12 split.
        assertEq(iusd.balanceOf(address(siusd)), 1000e18 + 20e18); // +10$ to staking
        assertEq(lockingController.totalBalance(), 1000e18 + 24e18); // +12$ to locking
    }

    function testPerformanceFeeAppliesToNetProfitOnly() public {
        // alice deposits 500$ and bonds for 10 epochs
        vm.startPrank(alice);
        {
            usdc.mint(alice, 500e6);
            usdc.approve(address(gateway), 500e6);
            gateway.mintAndLock(alice, 500e6, 10);
        }
        vm.stopPrank();

        vm.startPrank(parametersAddress);
        {
            yieldSharing.setSafetyBufferSize(5e18);
            yieldSharing.setPerformanceFeeAndRecipient(0.2e18, address(this));
        }
        vm.stopPrank();

        // simulate 10$ profit ~ 20 iUSD
        farm1.mockProfit(10e6);
        int256 unaccruedYieldBefore = yieldSharing.unaccruedYield();
        assertEq(unaccruedYieldBefore, 20e18, "Unaccrued yield should be 20 iUSD before accrue");

        yieldSharing.accrue();

        int256 unaccruedYieldAfter = yieldSharing.unaccruedYield();
        assertEq(unaccruedYieldAfter, 0, "Unaccrued yield should be 0 iUSD after accrue");

        // 5 iUSD is in the buffer and it is not subject to fee
        assertEq(iusd.balanceOf(address(yieldSharing)), 5e18, "5 iUSD should be in buffer");

        // 15 iUSD is left for distribution, fee is 20%, so 3 iUSD goes to the fee recipient
        assertEq(iusd.balanceOf(address(this)), 3e18, "3 iUSD should be charged to fee recipient");

        // 12 iUSD is distributed to the locking module
        assertEq(iusd.balanceOf(address(lockingController)), 1000e18 + 12e18);
    }
}
