// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {EmergencyWithdrawal} from "@integrations/farms/movement/EmergencyWithdrawal.sol";

contract EmergencyWithdrawalUnitTest is Fixture {
    function setUp() public override {
        super.setUp();

        farm1.mockProfit(100e6);
    }

    function testInitialState() public view {
        assertEq(address(emergencyWithdrawal.core()), address(core), "Error: incorrect core");
        assertEq(emergencyWithdrawal.safeAddress(), address(mintController), "Error: incorrect safeAddress");
    }

    function testDeprecateFarms() public {
        vm.expectRevert("UNAUTHORIZED");
        emergencyWithdrawal.setDeprecated(address(farm1));
        vm.expectRevert("UNAUTHORIZED");
        emergencyWithdrawal.setNotDeprecated(address(farm1));

        assertEq(emergencyWithdrawal.isDeprecated(address(farm1)), false, "Error: farm1 should not be deprecated (1)");

        vm.prank(msig);
        emergencyWithdrawal.setDeprecated(address(farm1));
        assertEq(emergencyWithdrawal.isDeprecated(address(farm1)), true, "Error: farm1 should be deprecated");

        assertEq(emergencyWithdrawal.getDeprecatedFarms().length, 1, "Error: should have 1 deprecated farm");
        assertEq(
            emergencyWithdrawal.getDeprecatedFarms()[0], address(farm1), "Error: farm1 should be the deprecated farm"
        );

        vm.prank(msig);
        vm.expectRevert(abi.encodeWithSelector(EmergencyWithdrawal.FarmAlreadyDeprecated.selector, address(farm1)));
        emergencyWithdrawal.setDeprecated(address(farm1));

        vm.prank(msig);
        emergencyWithdrawal.setNotDeprecated(address(farm1));
        assertEq(emergencyWithdrawal.isDeprecated(address(farm1)), false, "Error: farm1 should not be deprecated (2)");

        vm.prank(msig);
        vm.expectRevert(abi.encodeWithSelector(EmergencyWithdrawal.FarmNotDeprecated.selector, address(farm1)));
        emergencyWithdrawal.setNotDeprecated(address(farm1));
    }

    function testSetSafeAddress() public {
        vm.expectRevert("UNAUTHORIZED");
        emergencyWithdrawal.setSafeAddress(address(this));

        vm.prank(governorAddress);
        emergencyWithdrawal.setSafeAddress(address(this));
        assertEq(emergencyWithdrawal.safeAddress(), address(this), "Error: safeAddress not set");
    }

    function testEmergencyWithdraw() public {
        vm.expectRevert("UNAUTHORIZED");
        emergencyWithdrawal.emergencyWithdraw(address(farm1), 123);

        assertEq(farm1.assets(), 100e6, "Error: incorrect assets (1)");
        assertEq(mintController.assets(), 0, "Error: incorrect assets (2)");
        assertEq(farm1.paused(), false, "Error: farm1 should not be paused");

        vm.prank(msig);
        emergencyWithdrawal.emergencyWithdraw(address(farm1), 123);

        assertEq(farm1.assets(), 100e6 - 123, "Error: incorrect assets (3)");
        assertEq(mintController.assets(), 123, "Error: incorrect assets (4)");
        assertEq(farm1.paused(), true, "Error: farm1 should be paused (1)");

        vm.prank(msig);
        emergencyWithdrawal.emergencyWithdraw(address(farm1), 123);

        assertEq(farm1.assets(), 100e6 - 123 * 2, "Error: incorrect assets (5)");
        assertEq(mintController.assets(), 123 * 2, "Error: incorrect assets (6)");
        assertEq(farm1.paused(), true, "Error: farm1 should be paused (2)");
    }

    function testDeprecatedWithdraw() public {
        vm.expectRevert(abi.encodeWithSelector(EmergencyWithdrawal.FarmNotDeprecated.selector, address(farm1)));
        emergencyWithdrawal.deprecatedWithdraw(address(farm1), 123);

        vm.prank(msig);
        emergencyWithdrawal.setDeprecated(address(farm1));

        assertEq(farm1.assets(), 100e6, "Error: incorrect assets (1)");
        assertEq(mintController.assets(), 0, "Error: incorrect assets (2)");
        assertEq(farm1.paused(), true, "Error: farm1 should be paused (1)");

        emergencyWithdrawal.deprecatedWithdraw(address(farm1), 0);

        assertEq(farm1.assets(), 0, "Error: incorrect assets (3)");
        assertEq(mintController.assets(), 100e6, "Error: incorrect assets (4)");
        assertEq(farm1.paused(), true, "Error: farm1 should be paused (2)");
    }
}
