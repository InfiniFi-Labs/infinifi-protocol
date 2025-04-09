// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {InfiniFiTest} from "@test/InfiniFiTest.t.sol";

contract InfiniFiCoreUnitTest is InfiniFiTest {
    InfiniFiCore private core;
    address private notGovernor;
    address private governor;

    function setUp() public {
        core = new InfiniFiCore();
        notGovernor = makeAddr("notGovernor");
        governor = makeAddr("governor");
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));
    }

    function testInitialState() public view {}

    function testCreateRoleRevertsIfNotGovernor() public {
        vm.prank(notGovernor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notGovernor, CoreRoles.GOVERNOR
            )
        );
        core.createRole(keccak256("NEW ROLE"), CoreRoles.GOVERNOR);
    }

    function testCreateRoleRevertsIfRoleAlreadyExists() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(InfiniFiCore.RoleAlreadyExists.selector, keccak256("GOVERNOR")));
        core.createRole(keccak256("GOVERNOR"), CoreRoles.GOVERNOR);
    }

    function testCreateRole() public {
        vm.prank(governor);
        core.createRole(keccak256("NEW_ROLE"), CoreRoles.GOVERNOR);
        assertEq(core.getRoleAdmin(keccak256("NEW_ROLE")), CoreRoles.GOVERNOR, "Error: role admin should be governor");
    }

    function testSetRoleAdminRevertsIfNotGovernor() public {
        vm.prank(notGovernor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notGovernor, CoreRoles.GOVERNOR
            )
        );
        core.setRoleAdmin(keccak256("NEW_ROLE"), CoreRoles.GOVERNOR);
    }

    function testSetRoleAdminRevertsIfRoleDoesNotExist() public {
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(InfiniFiCore.RoleDoesNotExist.selector, keccak256("NEW_ROLE")));
        core.setRoleAdmin(keccak256("NEW_ROLE"), CoreRoles.GOVERNOR);
    }

    function testSetRoleAdmin() public {
        vm.prank(governor);
        core.createRole(keccak256("NEW_ROLE"), CoreRoles.GOVERNOR);
        vm.prank(governor);
        core.setRoleAdmin(keccak256("NEW_ROLE"), CoreRoles.GUARDIAN);
        assertEq(core.getRoleAdmin(keccak256("NEW_ROLE")), CoreRoles.GUARDIAN, "Error: role admin should be guardian");
    }

    function testGrantRolesRevertsIfLengthMismatch() public {
        bytes32[] memory roles = new bytes32[](1);
        address[] memory accounts = new address[](2);
        vm.expectRevert(abi.encodeWithSelector(InfiniFiCore.LengthMismatch.selector, 1, 2));
        core.grantRoles(roles, accounts);
    }

    function testGrantRolesRevertsIfNotRoleAdmin() public {
        bytes32[] memory roles = new bytes32[](1);
        roles[0] = keccak256("GUARDIAN");
        address[] memory accounts = new address[](1);
        accounts[0] = makeAddr("account");
        vm.prank(notGovernor);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, notGovernor, CoreRoles.GOVERNOR
            )
        );
        core.grantRoles(roles, accounts);
    }

    function testGrantRoles() public {
        bytes32[] memory roles = new bytes32[](2);
        roles[0] = keccak256("GUARDIAN");
        roles[1] = keccak256("GUARDIAN");
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("account");
        accounts[1] = makeAddr("account2");
        vm.prank(governor);
        core.grantRoles(roles, accounts);

        assertEq(core.hasRole(keccak256("GUARDIAN"), accounts[0]), true, "Error: account should have guardian role");
        assertEq(core.hasRole(keccak256("GUARDIAN"), accounts[1]), true, "Error: account2 should have guardian role");
    }
}
