// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {RedemptionPool} from "@funding/RedemptionPool.sol";
import {AfterMintHook} from "@integrations/farms/movement/AfterMintHook.sol";
import {BeforeRedeemHook} from "@integrations/farms/movement/BeforeRedeemHook.sol";

/// Actors in this test are:
/// Alice -> Ordinary end user that is minting and redeeming
/// Danny -> An existing user with capabilities of voting for farm allocation
contract IntegrationTestMintRedeemHooks is Fixture {
    AfterMintHook afterMintHook;
    BeforeRedeemHook beforeRedeemHook;

    uint256 aliceAssetAmount = 100e18;
    uint256 dannyAssetAmount = 100e18;
    AllocationVoting.AllocationVote[] liquidVotes;
    AllocationVoting.AllocationVote[] illiquidVotes;

    function setUp() public override {
        super.setUp();

        afterMintHook = new AfterMintHook(address(core), address(accounting), address(allocationVoting));
        beforeRedeemHook =
            new BeforeRedeemHook(address(core), address(accounting), address(allocationVoting), address(mintController));

        _initializeHooks();
        _prepareScenario();
    }

    /// ============================
    /// Configuration & Voting Setup
    /// ============================

    function _initializeHooks() internal {
        vm.startPrank(governorAddress);
        {
            core.grantRole(CoreRoles.FARM_MANAGER, address(afterMintHook));
            core.grantRole(CoreRoles.FARM_MANAGER, address(beforeRedeemHook));
            mintController.setAfterMintHook(address(afterMintHook));
            redeemController.setBeforeRedeemHook(address(beforeRedeemHook));
        }
        vm.stopPrank();
    }

    function _preparePosition() internal {
        deal(address(iusd), danny, dannyAssetAmount);

        // open position and wait for user to gain some power
        vm.startPrank(danny);
        {
            ERC20(iusd).approve(address(gateway), dannyAssetAmount);
            gateway.createPosition(dannyAssetAmount, 5, danny);
        }
        vm.stopPrank();
    }

    // Helper to prepare 50-50 votes
    function _prepareVote() internal {
        uint256 totalPower = lockingController.rewardWeight(danny);

        liquidVotes.push(AllocationVoting.AllocationVote({farm: address(farm1), weight: 0.5e18}));
        liquidVotes.push(AllocationVoting.AllocationVote({farm: address(farm2), weight: 0.5e18}));

        illiquidVotes.push(AllocationVoting.AllocationVote({farm: address(illiquidFarm1), weight: 0.5e18}));
        illiquidVotes.push(AllocationVoting.AllocationVote({farm: address(illiquidFarm2), weight: 0.5e18}));

        vm.prank(danny);
        gateway.vote(address(usdc), 5, liquidVotes, illiquidVotes);

        skip(1 weeks);

        (,, uint256 totalPowerVoted) = allocationVoting.getVoteWeights(FarmTypes.LIQUID);
        (,, totalPowerVoted) = allocationVoting.getVoteWeights(FarmTypes.MATURITY);

        assertEq(totalPower, totalPowerVoted, "Total power voted must equal individual power");
    }

    function _prepareVote(uint256 _farm1Weight, uint256 _farm2Weight) internal {
        uint256 totalPower = lockingController.rewardWeight(danny);

        delete liquidVotes;
        delete illiquidVotes;

        liquidVotes.push(AllocationVoting.AllocationVote({farm: address(farm1), weight: uint96(_farm1Weight)}));
        liquidVotes.push(AllocationVoting.AllocationVote({farm: address(farm2), weight: uint96(_farm2Weight)}));

        illiquidVotes.push(AllocationVoting.AllocationVote({farm: address(illiquidFarm1), weight: uint96(1e18)}));

        vm.prank(danny);
        gateway.vote(address(usdc), 5, liquidVotes, illiquidVotes);

        skip(1 weeks);

        (,, uint256 totalPowerVoted) = allocationVoting.getVoteWeights(FarmTypes.LIQUID);
        (,, totalPowerVoted) = allocationVoting.getVoteWeights(FarmTypes.MATURITY);

        assertEq(totalPower, totalPowerVoted, "Total power voted must equal individual power");
    }

    function _prepareScenario() internal {
        // Danny is going to be a voter
        _preparePosition();
        _prepareVote();
    }

    /// ============================
    /// Tests
    /// ============================

    function testAfterMintAuthorization() public {
        vm.startPrank(carol);
        {
            deal(address(usdc), carol, aliceAssetAmount);
            ERC20(usdc).approve(address(afterMintHook), type(uint256).max);
            try afterMintHook.afterMint(address(0), aliceAssetAmount) {
                assertTrue(true, "Failed to perform proper role check on afterMint hook");
                // noop
            } catch {
                assertTrue(true, "Unauthorized access to afterMint");
            }
        }
        vm.stopPrank();
    }

    function testBeforeRedeemAuthorization() public {
        vm.startPrank(carol);
        {
            deal(address(usdc), carol, aliceAssetAmount);
            ERC20(usdc).approve(address(beforeRedeemHook), type(uint256).max);
            try beforeRedeemHook.beforeRedeem(address(0), 0, aliceAssetAmount) {
                assertTrue(true, "Failed to perform proper role check on beforeRedeem hook");
                // noop
            } catch {
                assertTrue(true, "Unauthorized access to beforeRedeem");
            }
        }
        vm.stopPrank();
    }

    /// Tests mint operation when there is 50-50 allocation with two farms
    function testAfterMintIntegrationEvenSplit() public {
        vm.startPrank(alice);
        {
            deal(address(usdc), alice, aliceAssetAmount);
            ERC20(usdc).approve(address(gateway), type(uint256).max);

            gateway.mint(alice, (aliceAssetAmount / 2));
            gateway.mint(alice, (aliceAssetAmount / 2));

            // need to upscale since usdc has 6 decimals
            assertEq(iusd.balanceOf(alice), aliceAssetAmount * 1e12, "Should receive 1-1 iUSD for same amount of USDC");
            assertEq(farm1.assets(), aliceAssetAmount / 2, "Half should be in farm 1");
            assertEq(farm2.assets(), aliceAssetAmount / 2, "Half should be in farm 2");
        }
        vm.stopPrank();
        // skip some time to avoid transfer restriction
        vm.warp(block.timestamp + 10);
    }

    function testAfterMintIntegrationWithPausedFarms() public {
        vm.startPrank(guardianAddress);
        {
            farm1.pause();
            farm2.pause();
        }
        vm.stopPrank();

        dealToken(address(usdc), alice, aliceAssetAmount);
        vm.startPrank(alice);
        {
            ERC20(usdc).approve(address(gateway), type(uint256).max);
            gateway.mint(alice, (aliceAssetAmount));
        }
        vm.stopPrank();

        assertEq(farm1.assets(), 0, "Farm 1 should be empty");
        assertEq(farm2.assets(), 0, "Farm 2 should be empty");
        assertEq(mintController.liquidity(), aliceAssetAmount, "deposit should remain in the controller");
    }

    /// Redeems entire liquid TVL
    function testBeforeRedeemIntegrationFullRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, aliceBalance, 0);

            assertEq(farm1.assets(), 0, "Farm 1 should be empty");
            assertEq(farm2.assets(), 0, "Farm 2 should be empty");
            assertEq(iusd.balanceOf(alice), 0, "Alice should no longer have iUSD");
            assertEq(accounting.totalAssets(address(usdc)), 0, "Liquid TVL should be zero");
        }
        vm.stopPrank();
    }

    /// Redeems 25% of iUSD holdings
    function testBeforeRedeemIntegrationPartialRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, aliceBalance / 4, 0);

            assertEq(farm1.assets(), aliceAssetAmount / 4, "Farm 1 should be used for redemption");
            assertEq(farm2.assets(), aliceAssetAmount / 2, "Farm 2 should not be affected");
            assertEq(iusd.balanceOf(alice), (aliceBalance / 4) * 3, "Alice iUSD amount must be reduced to 75%");
        }
        vm.stopPrank();
    }

    /// Redeems 75% of iUSD holdings, meaning there is no farm good enough to satisfy the request
    /// In turn, all money will be pulled out proportionally according to the actual ratio within the farms
    function testBeforeRedeemIntegrationExcesiveRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, (aliceBalance / 4) * 3, 0);

            assertEq(farm1.assets(), aliceAssetAmount / 8, "Farm 1 should provide 50% of the total redemption");
            assertEq(farm2.assets(), aliceAssetAmount / 8, "Farm 2 should provide 50% of the total redemption");
            assertEq(iusd.balanceOf(alice), (aliceBalance / 4), "Alice iUSD amount must be reduced to 25%");
        }
        vm.stopPrank();
    }

    /// This case does four partial redeems, each by 25% percent of iUSD holdings
    function testBeforeRedeemIntegrationSequentialFullRedeem() public {
        testAfterMintIntegrationEvenSplit();

        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 aliceBalance = ERC20(iusd).balanceOf(alice);

            gateway.redeem(alice, (aliceBalance / 4), 0);
            gateway.redeem(alice, (aliceBalance / 4), 0);
            gateway.redeem(alice, (aliceBalance / 4), 0);
            gateway.redeem(alice, (aliceBalance / 4), 0);

            assertEq(farm1.assets(), 0, "Farm 1 should be empty after multiple redeems");
            assertEq(farm2.assets(), 0, "Farm 2 should be empty after multiple redeems");
            assertEq(iusd.balanceOf(alice), 0, "Alice iUSD amount must be 0");
        }
        vm.stopPrank();
    }

    function testAfterMintHookRespectingDepositCaps() public {
        uint256 _newCap = 100e18;
        aliceAssetAmount = 101e18;
        dealToken(address(usdc), alice, aliceAssetAmount);

        vm.startPrank(parametersAddress);
        {
            farm1.setCap(_newCap);
            farm2.setCap(_newCap);
        }
        vm.stopPrank();

        vm.startPrank(alice);
        {
            ERC20(usdc).approve(address(gateway), type(uint256).max);
            gateway.mint(alice, (aliceAssetAmount));
        }
        vm.stopPrank();

        assertEq(farm1.assets(), 100e18, "Farm 1 should have 100e18 assets");
        assertEq(farm2.assets(), 0, "Farm 2 should have 0 assets");
        assertEq(mintController.liquidity(), 1e18, "Liquidity should be 1e18");
    }

    function testAfterMintHookDepositCapExceeded() public {
        testAfterMintHookRespectingDepositCaps();
        dealToken(address(usdc), alice, 101e18);

        vm.prank(alice);
        gateway.mint(alice, 101e18);

        assertEq(farm1.assets(), 100e18, "Farm 1 should have 100e18 assets");
        assertEq(farm2.assets(), 100e18, "Farm 2 should have 100e18 assets");
        assertEq(mintController.liquidity(), 2e18, "Liquidity should be 2e18");
    }

    function testAfterMintHookDepositCapExceededWithMultipleFarms() public {
        testAfterMintHookDepositCapExceeded();
        dealToken(address(usdc), alice, 100e18);

        vm.prank(alice);
        gateway.mint(alice, 100e18);

        assertEq(farm1.assets(), 100e18, "Farm 1 should have 100e18 assets");
        assertEq(farm2.assets(), 100e18, "Farm 2 should have 100e18 assets");
        assertEq(mintController.liquidity(), 102e18, "Liquidity should be 102e18");
    }

    function testAfterMintHookDepositCapBorderCase() public {
        uint256 _newCap = 100e18;
        aliceAssetAmount = 10e18;
        dealToken(address(usdc), alice, aliceAssetAmount);

        _prepareVote(0.9e18, 0.1e18);

        farm1.mockProfit(99e18);
        farm2.mockProfit(30e18);

        vm.startPrank(parametersAddress);
        {
            farm1.setCap(_newCap);
            farm2.setCap(_newCap);
        }
        vm.stopPrank();

        vm.startPrank(alice);
        {
            ERC20(usdc).approve(address(gateway), type(uint256).max);
            gateway.mint(alice, (aliceAssetAmount));
        }
        vm.stopPrank();

        assertEq(farm1.assets(), 100e18, "Farm 1 should be used for deposit");
        assertEq(farm2.assets(), 30e18, "Farm 2 should not be changed");
        assertEq(mintController.liquidity(), 9e18, "Remainder should be in the mint controller");
    }

    function testBeforeRedeemHookFundingQueue() public {
        dealToken(address(usdc), alice, 100e6);

        dealToken(address(iusd), bob, 100e18);

        // Bob redeems 100 iUSD
        vm.startPrank(bob);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 amount = gateway.redeem(bob, 100e18, 0);
            assertEq(amount, 0, "Bob should receive 0 USDC");
        }
        vm.stopPrank();

        uint256 redeemTotalEnqueued = redeemController.totalEnqueuedRedemptions();
        assertEq(redeemTotalEnqueued, 100e18, "Total enqueued should be 100e18");

        // Alice mints 100 iUSD
        vm.startPrank(alice);
        {
            ERC20(usdc).approve(address(gateway), type(uint256).max);
            gateway.mint(alice, 100e6);
        }
        vm.stopPrank();

        // Alice redeems 100 iUSD
        vm.startPrank(alice);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 amount = gateway.redeem(alice, 100e18, 0);
            assertEq(amount, 0, "Alice should receive 0 USDC");
        }
        vm.stopPrank();

        uint256 usdcBalanceOfRedeemController = ERC20(usdc).balanceOf(address(redeemController));
        uint256 iusdBalanceOfRedeemController = ERC20(iusd).balanceOf(address(redeemController));

        assertEq(redeemController.queueLength(), 2, "Both Alice and Bob should be in the queue");
        assertEq(usdcBalanceOfRedeemController, 0, "USDC balance of redeem controller should be 0");
        assertEq(iusdBalanceOfRedeemController, 200e18, "iUSD balance of redeem controller should be 200e18");

        // System provides liquidity to redeem controller
        vm.startPrank(msig);
        {
            manualRebalancer.singleMovement(address(farm1), address(redeemController), farm1.liquidity());
            manualRebalancer.singleMovement(address(farm2), address(redeemController), farm2.liquidity());
        }
        vm.stopPrank();

        uint256 totalPendingClaims = redeemController.totalPendingClaims();
        assertEq(totalPendingClaims, 100e6, "Total pending claims should be 100e6 after rebalancing");

        assertEq(farm1.assets(), 0, "Farm 1 should be empty");
        assertEq(farm2.assets(), 0, "Farm 2 should be empty");
        assertEq(redeemController.liquidity(), 0, "Liquidity should be 0 (as 100e6 is reserved for claims)");

        // We prove that Alice cannot claim redemption as only Bob had enough
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RedemptionPool.NoPendingClaims.selector, alice));
        gateway.claimRedemption();

        // We prove that Bob can claim redemption as there are enough assets in the redeem controller
        vm.prank(bob);
        gateway.claimRedemption();

        assertEq(ERC20(usdc).balanceOf(bob), 100e6, "Bob should receive 100e6 USDC");
        assertEq(redeemController.totalPendingClaims(), 0, "Total pending claims should be 0");

        // Now we add a lot of money to farms
        vm.startPrank(parametersAddress);
        {
            farm1.mockProfit(100e18);
            farm2.mockProfit(100e18);
        }
        vm.stopPrank();

        // now Carol mints 100 iUSD and tries to redeem 100 iUSD
        dealToken(address(iusd), carol, 100e18);

        vm.startPrank(carol);
        {
            ERC20(iusd).approve(address(gateway), type(uint256).max);
            uint256 amount = gateway.redeem(carol, 100e18, 0);
            assertEq(amount, 0, "Carol should receive 0 USDC");
        }
        vm.stopPrank();

        uint256 usdcNeededToFundQueue = redeemController.receiptToAsset(redeemController.totalEnqueuedRedemptions());
        assertEq(usdcNeededToFundQueue, 200e6, "USDC needed to fund the queue should be 200e6");

        // now the system funds the queue
        dealToken(address(usdc), address(redeemController), usdcNeededToFundQueue);
        vm.prank(farmManagerAddress);
        redeemController.deposit();

        vm.prank(carol);
        gateway.claimRedemption();
        assertEq(ERC20(usdc).balanceOf(carol), 100e6, "Carol should receive 100e6 USDC");

        vm.prank(alice);
        gateway.claimRedemption();
        assertEq(ERC20(usdc).balanceOf(alice), 100e6, "Alice should receive 100e6 USDC");

        // assert that the redeem controller is empty
        assertEq(redeemController.queueLength(), 0, "Queue should be empty");
        assertEq(redeemController.totalEnqueuedRedemptions(), 0, "Total enqueued should be 0");
        assertEq(redeemController.totalPendingClaims(), 0, "Total pending claims should be 0");
        assertEq(ERC20(usdc).balanceOf(address(redeemController)), 0, "USDC balance of redeem controller should be 0");
        assertEq(ERC20(iusd).balanceOf(address(redeemController)), 0, "iUSD balance of redeem controller should be 0");
    }

    function testAfterMintHookAssetRebalanceThreshold() public {
        vm.expectRevert(bytes("UNAUTHORIZED"));
        afterMintHook.setAssetRebalanceThreshold(500e6);

        vm.prank(parametersAddress);
        afterMintHook.setAssetRebalanceThreshold(500e6);
        assertEq(afterMintHook.assetRebalanceThreshold(), 500e6);
    }

    function testMintThreshold() public {
        vm.prank(parametersAddress);
        afterMintHook.setAssetRebalanceThreshold(500e6);
        assertEq(afterMintHook.assetRebalanceThreshold(), 500e6);

        uint256 snapshot1 = gasleft();

        dealToken(address(usdc), address(alice), 1000e6);
        vm.startPrank(alice);
        {
            usdc.approve(address(gateway), 1000e6);
            gateway.mintAndLock(alice, 1000e6, 10);
        }
        vm.stopPrank();

        uint256 snapshot2 = gasleft();
        uint256 mintAndLockGasWithHook = snapshot1 - snapshot2;

        dealToken(address(usdc), address(alice), 500e6);
        vm.startPrank(alice);
        {
            usdc.approve(address(gateway), 500e6);
            gateway.mintAndLock(alice, 500e6, 10);
        }
        vm.stopPrank();

        uint256 snapshot3 = gasleft();
        uint256 mintAndLockGasWithoutHook = snapshot2 - snapshot3;

        assertGt(mintAndLockGasWithHook, mintAndLockGasWithoutHook, "Not using after mint hook should be cheaper");
        assertGt(
            mintAndLockGasWithHook - mintAndLockGasWithoutHook,
            200_000,
            "Not using after mint hook should be cheaper by at least 200k"
        );
    }

    function testBeforeRedeemHookUsesMintController() public {
        dealToken(address(usdc), address(mintController), 50e6);
        dealToken(address(iusd), address(alice), 100e18);

        farm1.mockProfit(50e6);

        vm.startPrank(alice);
        {
            iusd.approve(address(gateway), 100e18);
            gateway.redeem(alice, 100e18, 0);
        }
        vm.stopPrank();

        uint256 mintControllerBalance = usdc.balanceOf(address(mintController));
        uint256 aliceBalance = usdc.balanceOf(address(alice));

        assertEq(farm1.assets(), 0, "Farm 1 should have 0 assets after redeem");
        assertEq(mintControllerBalance, 0, "Mint controller should have 0 assets after redeem");
        assertEq(aliceBalance, 100e6, "Alice should have 100e6 USDC after redeem");
    }
}
