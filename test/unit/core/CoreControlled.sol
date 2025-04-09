// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {InfiniFiTest} from "@test/InfiniFiTest.t.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {MockCoreControlled} from "@test/mock/MockCoreControlled.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";

contract CoreControlledUnitTest is InfiniFiTest {
    address private governor = address(1);
    address private guardian = address(2);
    InfiniFiCore private core;
    MockCoreControlled private coreControlled;

    // used to test emergency actions
    MockERC20 private token;

    function revertMe() external pure {
        revert();
    }

    function setUp() public {
        core = new InfiniFiCore();
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        coreControlled = new MockCoreControlled(address(core));

        token = new MockERC20("MockERC20", "MRC20");

        vm.label(address(core), "core");
        vm.label(address(coreControlled), "coreControlled");
        vm.label(address(token), "token");
    }

    function testInitialState() public view {
        assertEq(address(coreControlled.core()), address(core), "Error: coreControlled core should be core");
    }

    function testSetCoreRevertIfNotGovernor() public {
        vm.expectRevert("UNAUTHORIZED");
        coreControlled.setCore(address(1));
    }

    function testSetCore() public {
        vm.prank(governor);
        coreControlled.setCore(address(1));
        assertEq(address(coreControlled.core()), address(1), "Error: coreControlled core should be 1");
    }

    function testPauseCanOnlyBeCalledByGuardian() public {
        vm.expectRevert("UNAUTHORIZED");
        coreControlled.pause();
    }

    function testPause() public {
        vm.prank(guardian);
        coreControlled.pause();
        assertEq(coreControlled.paused(), true, "Error: coreControlled should be paused");
    }

    function testUnpauseCanOnlyBeCalledByGuardian() public {
        testPause();
        vm.expectRevert("UNAUTHORIZED");
        coreControlled.unpause();
    }

    function testUnpause() public {
        testPause();
        vm.prank(guardian);
        coreControlled.unpause();
        assertEq(coreControlled.paused(), false, "Error: coreControlled should be unpaused");
    }

    function testEmergencyActionFailIfNotGovernor() public {
        MockCoreControlled.Call[] memory calls = new MockCoreControlled.Call[](1);
        calls[0].callData = abi.encodeWithSignature("mint(address,uint256)", address(this), 100);
        calls[0].target = address(token);

        vm.expectRevert("UNAUTHORIZED");
        coreControlled.emergencyAction(calls);
    }

    /// @notice test emergency action, any action can be called so we'll try to mint 100 tokens to this contract
    function testEmergencyAction() public {
        MockCoreControlled.Call[] memory calls = new MockCoreControlled.Call[](1);
        calls[0].callData = abi.encodeWithSignature("mint(address,uint256)", address(this), 100);
        calls[0].target = address(token);

        assertEq(token.balanceOf(address(this)), 0);

        vm.prank(governor);
        coreControlled.emergencyAction(calls);

        assertEq(token.balanceOf(address(this)), 100, "Error: token balance of this should be 100");
    }

    /// @notice test emergency action, any action can be called so we'll try to mint 100 tokens to this contract
    function testEmergencyActionThatReverts() public {
        MockCoreControlled.Call[] memory calls = new MockCoreControlled.Call[](1);
        calls[0].target = address(this);
        calls[0].value = 0;
        calls[0].callData = abi.encodeWithSignature("revertMe()");

        assertEq(token.balanceOf(address(this)), 0, "Error: token balance of this should be 0");

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(CoreControlled.UnderlyingCallReverted.selector, ""));
        coreControlled.emergencyAction(calls);
    }
}
