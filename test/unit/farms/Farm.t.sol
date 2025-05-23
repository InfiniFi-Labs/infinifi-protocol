// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Farm} from "@integrations/Farm.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {MockFarm} from "@test/mock/MockFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";

contract FarmUnitTest is Fixture {
    MockFarm public farm;
    uint256 constant INITIAL_CAP = 1_000_000e6; // 1M USDC

    function setUp() public override {
        super.setUp();
        farm = new MockFarm(address(core), address(usdc));
    }

    function testInitialState() public view {
        assertEq(farm.assetToken(), address(usdc), "Error: asset token should be usdc");
        assertEq(farm.cap(), type(uint256).max, "Error: cap should be max uint256");
    }

    function testSetCapShouldRevertIfNotFarmManager() public {
        vm.expectRevert("UNAUTHORIZED");
        farm.setCap(1000e6);
    }

    function testSetCapShouldUpdateCap() public {
        vm.prank(parametersAddress);
        farm.setCap(INITIAL_CAP);
        assertEq(farm.cap(), INITIAL_CAP, "Error: Farm's cap is not updated after setCap()");

        uint256 newCap = 50_000_000e6;
        vm.prank(parametersAddress);

        farm.setCap(newCap);
        assertEq(farm.cap(), newCap, "Error: Farm's cap is not updated after setCap()");
    }

    function testDepositShouldRevertIfCapExceeded() public {
        vm.prank(parametersAddress);
        farm.setCap(INITIAL_CAP);

        // Try to deposit more than cap
        usdc.mint(address(farm), INITIAL_CAP + 1);
        vm.prank(farmManagerAddress);
        vm.expectRevert(abi.encodeWithSelector(Farm.CapExceeded.selector, INITIAL_CAP + 1, INITIAL_CAP));
        farm.deposit();
    }

    function testDepositShouldSucceedIfUnderCap() public {
        vm.prank(parametersAddress);
        farm.setCap(INITIAL_CAP);

        // Deposit under cap
        usdc.mint(address(farm), INITIAL_CAP - 1);
        vm.prank(farmManagerAddress);
        farm.deposit();

        assertEq(
            farm.assets(), INITIAL_CAP - 1, "Error: Farm's assets does not reflect the correct amount after deposit"
        );
    }

    function testDepositShouldSucceedIfEqualToCap() public {
        vm.prank(parametersAddress);
        farm.setCap(INITIAL_CAP);

        // Deposit exactly at cap
        usdc.mint(address(farm), INITIAL_CAP);
        vm.prank(farmManagerAddress);
        farm.deposit();

        assertEq(farm.assets(), INITIAL_CAP, "Error: Farm's assets does not reflect the correct amount after deposit");
    }

    function testDepositShouldConsiderExistingAssets() public {
        vm.prank(parametersAddress);
        farm.setCap(INITIAL_CAP);

        // First deposit
        usdc.mint(address(farm), INITIAL_CAP - 500e6);
        vm.prank(farmManagerAddress);
        farm.deposit();

        // Second deposit that would exceed cap
        usdc.mint(address(farm), 600e6);
        vm.prank(farmManagerAddress);
        vm.expectRevert(abi.encodeWithSelector(Farm.CapExceeded.selector, INITIAL_CAP + 100e6, INITIAL_CAP));
        farm.deposit();
    }

    function testSetMaxSlippage() public {
        vm.expectRevert("UNAUTHORIZED");
        farm.setMaxSlippage(0.98e18);

        vm.prank(parametersAddress);
        farm.setMaxSlippage(0.98e18);

        assertEq(farm.maxSlippage(), 0.98e18, "Error: Farm's maxSlippage should be 0.98e18");
    }

    function testMaxDepositViewer() public {
        vm.prank(parametersAddress);
        farm.setCap(1000e6);

        assertEq(farm.maxDeposit(), 1000e6);

        usdc.mint(address(farm), 500e6);
        vm.prank(farmManagerAddress);
        farm.deposit();

        assertEq(farm.maxDeposit(), 500e6);

        // set cap to below current assets()
        vm.prank(parametersAddress);
        farm.setCap(50e6);

        assertEq(farm.maxDeposit(), 0);
    }
}
