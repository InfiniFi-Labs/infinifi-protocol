// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MinorRolesManager} from "@governance/MinorRolesManager.sol";

contract MinorRolesManagerUnitTest is Fixture {
    function testInitialState() public view {
        assertEq(address(minorRolesManager.core()), address(core));
    }

    function testPauseRole() public {
        assertFalse(core.hasRole(CoreRoles.PAUSE, alice));

        vm.expectRevert("UNAUTHORIZED");
        minorRolesManager.grantPause(alice);

        vm.prank(msig);
        minorRolesManager.grantPause(alice);

        assertTrue(core.hasRole(CoreRoles.PAUSE, alice));

        vm.expectRevert("UNAUTHORIZED");
        minorRolesManager.revokePause(alice);

        vm.prank(msig);
        minorRolesManager.revokePause(alice);

        assertFalse(core.hasRole(CoreRoles.PAUSE, alice));
    }

    function testPeriodicRebalancerRole() public {
        assertFalse(core.hasRole(CoreRoles.PERIODIC_REBALANCER, alice));

        vm.expectRevert("UNAUTHORIZED");
        minorRolesManager.grantPeriodicRebalancer(alice);

        vm.prank(msig);
        minorRolesManager.grantPeriodicRebalancer(alice);

        assertTrue(core.hasRole(CoreRoles.PERIODIC_REBALANCER, alice));

        vm.expectRevert("UNAUTHORIZED");
        minorRolesManager.revokePeriodicRebalancer(alice);

        vm.prank(msig);
        minorRolesManager.revokePeriodicRebalancer(alice);

        assertFalse(core.hasRole(CoreRoles.PERIODIC_REBALANCER, alice));
    }

    function testFarmSwapCallerRole() public {
        assertFalse(core.hasRole(CoreRoles.FARM_SWAP_CALLER, alice));

        vm.expectRevert("UNAUTHORIZED");
        minorRolesManager.grantFarmSwapCaller(alice);

        vm.prank(msig);
        minorRolesManager.grantFarmSwapCaller(alice);

        assertTrue(core.hasRole(CoreRoles.FARM_SWAP_CALLER, alice));

        vm.expectRevert("UNAUTHORIZED");
        minorRolesManager.revokeFarmSwapCaller(alice);

        vm.prank(msig);
        minorRolesManager.revokeFarmSwapCaller(alice);

        assertFalse(core.hasRole(CoreRoles.FARM_SWAP_CALLER, alice));
    }
}
