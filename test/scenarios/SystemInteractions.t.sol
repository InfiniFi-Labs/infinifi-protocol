// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {EpochLib} from "@libraries/EpochLib.sol";
import {MintController} from "@funding/MintController.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {ActionRestriction} from "@core/ActionRestriction.sol";

contract SystemInteractionsUnitTest is Fixture {
    using EpochLib for uint256;

    bool public afterMintHookCalled = false;
    bool public beforeRedeemHookCalled = false;

    // mint & redeem hooks
    function afterMint(address, uint256, uint256) external {
        afterMintHookCalled = true;
    }

    function beforeRedeem(address, uint256, uint256) external {
        beforeRedeemHookCalled = true;
    }

    function setUp() public override {
        super.setUp();

        // setup some non-zero block & timestamp
        vm.warp(1733412513);
        vm.roll(21337193);
    }

    function testAccounting() public {
        assertEq(accounting.totalAssetsValue(), 0);
        assertEq(yieldSharing.unaccruedYield(), 0);

        // airdrop assets on a farm
        usdc.mint(address(farm1), 100e6); // 100$
        assertEq(accounting.totalAssetsValue(), 100e18); // 100$
        assertEq(yieldSharing.unaccruedYield(), 100e18);

        // airdrop liabilities in circulation
        vm.prank(address(mintController));
        iusd.mint(alice, 80e18); // 80$
        assertEq(accounting.totalAssetsValue(), 100e18); // 100$
        assertEq(yieldSharing.unaccruedYield(), 20e18); // 20$
    }

    function testMintRedeem() public {
        // set hooks
        vm.startPrank(governorAddress);
        mintController.setAfterMintHook(address(this));
        redeemController.setBeforeRedeemHook(address(this));
        vm.stopPrank();

        // mint
        vm.startPrank(alice);
        usdc.mint(alice, 100e6);
        usdc.approve(address(gateway), 100e6);
        gateway.mint(alice, 100e6);
        vm.stopPrank();

        // check token movements
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(mintController)), 100e6);
        assertEq(iusd.balanceOf(alice), 100e18);
        assertEq(iusd.balanceOf(address(mintController)), 0);
        assertEq(iusd.totalSupply(), 100e18);

        // check accounting
        assertEq(accounting.totalAssetsValue(), 100e18);
        assertEq(yieldSharing.unaccruedYield(), 0);

        // check hooks
        assertEq(afterMintHookCalled, true);
        assertEq(beforeRedeemHookCalled, false);

        // move funds to redeemController
        vm.prank(msig);
        farmRebalancer.singleMovement(address(mintController), address(redeemController), 100e6);

        // redeem
        vm.startPrank(alice);
        vm.warp(block.timestamp + 12);
        iusd.approve(address(gateway), 70e18);
        gateway.redeem(alice, 70e18);
        vm.stopPrank();

        // check token movements
        assertEq(usdc.balanceOf(alice), 70e6);
        assertEq(usdc.balanceOf(address(redeemController)), 30e6);
        assertEq(iusd.balanceOf(alice), 30e18);
        assertEq(iusd.balanceOf(address(redeemController)), 0);
        assertEq(iusd.totalSupply(), 30e18);

        // check accounting
        assertEq(accounting.totalAssetsValue(), 30e18);
        assertEq(yieldSharing.unaccruedYield(), 0);

        // check hooks
        assertEq(afterMintHookCalled, true);
        assertEq(beforeRedeemHookCalled, true);
    }

    function testMintAndStake() public {
        // set hooks
        vm.startPrank(governorAddress);
        mintController.setAfterMintHook(address(this));
        redeemController.setBeforeRedeemHook(address(this));
        vm.stopPrank();

        // mint 100 USDC to alice
        usdc.mint(alice, 100e6);

        // alice will then mint 100 iUSD and automatically deposit into stakedToken
        // using the `mintAndEnterSavings` function
        vm.startPrank(alice);
        usdc.approve(address(gateway), 100e6);
        gateway.mintAndStake(alice, 100e6);

        // check token movements
        assertEq(usdc.balanceOf(alice), 0, "usdc balance of alice should be 0");
        assertEq(usdc.balanceOf(address(mintController)), 100e6, "usdc balance of mintController should be 100e6");
        assertEq(iusd.balanceOf(alice), 0, "iusd balance of alice should be 0");
        assertEq(iusd.balanceOf(address(mintController)), 0, "iusd balance of mintController should be 0");
        assertEq(iusd.balanceOf(address(siusd)), 100e18, "iusd balance of stakedToken should be 100e18");
        assertEq(iusd.totalSupply(), 100e18, "iusd totalSupply should be 100e18");
        assertEq(siusd.totalSupply(), 100e18, "siusd totalSupply should be 100e18");
        assertEq(siusd.balanceOf(alice), 100e18, "siusd balance of alice should be 100e18");

        // check alice cannot transfer her siusd yet
        vm.expectRevert(
            abi.encodeWithSelector(
                ActionRestriction.ActionRestricted.selector,
                alice,
                block.timestamp + mintController.restrictionDuration()
            )
        );
        siusd.transfer(bob, 100e18);
        vm.stopPrank();

        // check hooks
        assertEq(afterMintHookCalled, true);
        assertEq(beforeRedeemHookCalled, false);
    }
}
