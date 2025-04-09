// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "@forge-std/console.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {EpochLib} from "@libraries/EpochLib.sol";
import {ActionRestriction} from "@core/ActionRestriction.sol";

contract StakedTokenUnitTest is Fixture {
    using EpochLib for uint256;

    function setUp() public override {
        super.setUp();

        // mint 1000 USDC to alice then stake it
        usdc.mint(address(alice), 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(gateway), 1000e6);
        gateway.mintAndStake(alice, 1000e6);
        vm.stopPrank();
        // mint 500 USDC to bob then stake it
        usdc.mint(address(bob), 500e6);
        vm.startPrank(bob);
        usdc.approve(address(gateway), 500e6);
        gateway.mintAndStake(bob, 500e6);
        vm.stopPrank();
    }

    function _depositRewards(uint256 _amount) internal {
        vm.startPrank(address(yieldSharing));
        iusd.mint(address(yieldSharing), _amount);
        iusd.approve(address(siusd), _amount);
        siusd.depositRewards(_amount);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(siusd.balanceOf(address(alice)), 1000e18);
        assertEq(siusd.balanceOf(address(bob)), 500e18);
        assertEq(siusd.totalSupply(), 1500e18);
    }

    /// @notice test that the withdraw works
    function testWithdrawShouldWork() public {
        vm.prank(alice);

        // skip for next block given restriction on mint and redemption on same block
        vm.warp(block.timestamp + 1);
        siusd.withdraw(1000e18, alice, alice);
        assertEq(siusd.balanceOf(address(alice)), 0e18);
        assertEq(iusd.balanceOf(address(alice)), 1000e18);
    }

    /// @notice verify transfer restriction works
    function testTransferShouldNotWorkInSameBlockAsMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActionRestriction.ActionRestricted.selector, alice, block.timestamp + 1));
        siusd.transfer(carol, 500e18);
    }

    /// @notice verify transfer restriction works
    function testTransferShouldNotWorkTheBlockAfterMint() public {
        vm.warp(block.timestamp + 12);
        vm.prank(alice);
        siusd.transfer(carol, 500e18);
        assertEq(siusd.balanceOf(address(alice)), 500e18);
        assertEq(siusd.balanceOf(address(carol)), 500e18);
    }

    /// @notice verify that not anyone can call depositRewards
    function testDepositRewardsShouldRevertIfNotProfitManager() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(carol);
        siusd.depositRewards(100e6);
    }

    /// @notice verify that deposited profites does not reflect directly in totalAssets
    /// but is added to the next epoch rewards
    function testDepositRewardsShouldNotReflectDirectlyInTotalAssets() public {
        // profit sharing will mint 300 iUSD (assuming profits here) and send it to the staked token
        _depositRewards(300e18);

        // thanks to alice and bob 1000 + 500 iUSD
        // and adding the new 300 iUSD minted because of profits
        // the staked token now has 1800 iUSD
        assertEq(iusd.balanceOf(address(siusd)), 1800e18);
        assertEq(siusd.totalAssets(), 1500e18);
        // check the reward has been added to the next epoch
        assertEq(siusd.epochRewards(block.timestamp.nextEpoch()), 300e18);

        // check that currently, rewards are not distributed
        // meaning alice can still only redeem 1000 iUSD
        // and bob can still only redeem 500 iUSD
        assertEq(siusd.maxWithdraw(alice), 1000e18);
        assertEq(siusd.maxWithdraw(bob), 500e18);
    }

    /// @notice verify that deposited profits is reflected fully 2 epochs later
    function testDepositRewardsShouldReflectInTotalAssetsAfterEpoch() public {
        // profit sharing will mint 300 iUSD (assuming profits here) and send it to the staked token
        _depositRewards(300e18);

        // now we'll advance 2 epoch, meaning the reward will be fully available
        advanceEpoch(2);
        assertEq(siusd.totalAssets(), 1800e18);

        // now we'll advance 2 epoch, meaning the reward will be fully available
        advanceEpoch(2);
        assertApproxEqAbs(siusd.maxWithdraw(alice), 1200e18, 10);
        assertApproxEqAbs(siusd.maxWithdraw(bob), 600e18, 10);
    }

    /// @notice verify that deposited profits is reflected gradually in totalAssets
    /// during the epoch it becomes claimable
    function testDepositRewardsShouldBeReflectedInHalfInMiddleOfEpoch() public {
        // profit sharing will mint 300 iUSD (assuming profits here) and send it to the staked token
        _depositRewards(300e18);

        // now we'll advance 2 epoch, meaning the reward will be fully available
        advanceEpoch(1);
        uint256 startEpochTimestamp = block.timestamp.epoch().epochToTimestamp();
        vm.warp(startEpochTimestamp + EpochLib.EPOCH / 2);

        // we're now in the middle of the epoch where the rewards are available.
        // the total assets should be 1500 + 150 (half of the 300 iUSD)
        assertEq(siusd.totalAssets(), 1650e18);

        // alice and bob should be able to redeem partially
        assertApproxEqAbs(siusd.maxWithdraw(alice), 1100e18, 10);
        assertApproxEqAbs(siusd.maxWithdraw(bob), 550e18, 10);
    }

    /// @notice verify that not anyone can call applyLosses
    function testApplyLossesShouldRevertIfNotProfitManager() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(carol);
        siusd.applyLosses(100e18);
    }

    /// @notice verify that applyLosses only slashes next epoch rewards if enough in it
    function testApplyLossesShouldOnlySlashNextRewardsIfEnough() public {
        // profit sharing will mint 300 iUSD (assuming profits here) and send it to the staked token
        _depositRewards(300e18);

        // now we'll apply losses
        vm.prank(address(yieldSharing));
        siusd.applyLosses(100e18);

        // the next epoch rewards should be slashed
        assertEq(siusd.epochRewards(block.timestamp.nextEpoch()), 200e18);

        // assert that alice and bob can still redeem at least the amount they staked
        assertGe(siusd.maxWithdraw(alice), 1000e18);
        assertGe(siusd.maxWithdraw(bob), 500e18);
    }

    /// @notice verify that applyLosses slashes current and next epoch rewards if enough in it
    function testApplyLossesShouldSlashCurrentAndNextRewardsIfEnough() public {
        // profit sharing will mint 300 iUSD (assuming profits here) and send it to the staked token
        _depositRewards(300e18);
        advanceEpoch(1);
        // add 50 iUSD to the next epoch
        _depositRewards(50e18);

        // now we'll apply losses
        vm.prank(address(yieldSharing));
        siusd.applyLosses(100e18);

        // the next epoch rewards should be slashed
        assertEq(siusd.epochRewards(block.timestamp.nextEpoch()), 0e18);
        assertEq(siusd.epochRewards(block.timestamp.epoch()), 250e18);

        // assert that alice and bob can still redeem at least the amount they staked
        assertGe(siusd.maxWithdraw(alice), 1000e18);
        assertGe(siusd.maxWithdraw(bob), 500e18);
    }

    /// @notice verify that applyLosses slashes current and next epoch rewards then burn underlying tokens
    /// meaning users are slashed
    function testApplyLossesGreaterThanRewardsShouldSlashUsers() public {
        // profit sharing will mint 300 iUSD (assuming profits here) and send it to the staked token
        _depositRewards(300e18);
        advanceEpoch(1);
        // add 200 iUSD to the next epoch
        _depositRewards(200e18);

        // now we'll apply losses
        vm.prank(address(yieldSharing));
        siusd.applyLosses(1400e18);

        // here we had alice and bob who staked 1000 and 500 iUSD: 1500 iUSD
        // then there was 300 + 200 iUSD in rewards: 500 iUSD (total 2000 iUSD in the vault)
        // then we're applying a loss of 1400 iUSD, meaning there will only be 600 iUSD left in the vault
        // alice should be entitled to 2/3 * 600 iUSD = 400 iUSD
        // bob should be entitled to 1/3 * 600 iUSD = 200 iUSD

        // all rewards should be slashed
        assertEq(siusd.epochRewards(block.timestamp.nextEpoch()), 0e18);
        assertEq(siusd.epochRewards(block.timestamp.epoch()), 0e18);

        // assert that alice and bob now only have 400 and 200 iUSD left
        // because they have been slashed
        assertApproxEqAbs(siusd.maxWithdraw(alice), 400e18, 10);
        assertApproxEqAbs(siusd.maxWithdraw(bob), 200e18, 10);
    }
}
