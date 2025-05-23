// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GPv2Order} from "@cowprotocol/contracts/libraries/GPv2Order.sol";
import {CoWSwapFarm} from "@integrations/farms/CoWSwapFarm.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {MockCoWSettlement} from "@test/mock/MockCoWSettlement.sol";

contract CoWSwapFarmUnitTest is Fixture {
    CoWSwapFarm farm;
    FixedPriceOracle wrapTokenOracle;
    MockERC20 wrapToken = new MockERC20("WRAP_TOKEN", "WT");
    MockCoWSettlement mockSettlement = new MockCoWSettlement();

    function setUp() public override {
        super.setUp();

        wrapTokenOracle = new FixedPriceOracle(address(core), 2e18); // 1 wrapped token = 2 USDC
        vm.prank(oracleManagerAddress);
        accounting.setOracle(address(wrapToken), address(wrapTokenOracle));

        farm = new CoWSwapFarm(
            address(core),
            address(usdc),
            address(wrapToken),
            address(accounting),
            30 days,
            address(mockSettlement),
            address(mockSettlement)
        );

        vm.label(address(farm), "CoWSwapFarm");
        vm.label(address(mockSettlement), "MockCoWSettlement");
    }

    function testInitialState() public view {
        assertEq(
            farm.accounting(), address(accounting), "Error: CoWSwapFarm's accounting does not reflect correct address"
        );
        assertEq(farm.assets(), 0, "Error: CoWSwapFarm's assets should be 0");
        assertEq(farm.maturity(), block.timestamp + 30 days, "Error: CoWSwapFarm's maturity is not set correctly");
        assertEq(
            farm.wrapToken(), address(wrapToken), "Error: CoWSwapFarm's wrapToken does not reflect correct address"
        );
        assertEq(farm.assetToken(), address(usdc), "Error: CoWSwapFarm's assetToken does not reflect correct address");
    }

    function testConvertViewers() public view {
        assertEq(farm.convertToAssets(500e18), 1000e6, "Error: CoWSwapFarm's convertToAssets is not correct");
        assertEq(farm.convertToWrapTokens(1000e6), 500e18, "Error: CoWSwapFarm's convertToWrapTokens is not correct");
    }

    function testAssetsAndLiquidity() public {
        // by default assets and liquidity are the same and are 0
        assertEq(farm.assets(), 0, "Error: CoWSwapFarm's assets should be 0");
        assertEq(farm.liquidity(), 0, "Error: CoWSwapFarm's liquidity should be 0");

        // if we deposit only assets (usdc), the assets and liquidity should be the same
        usdc.mint(address(farm), 1000e6);
        assertEq(farm.assets(), 1000e6, "Error: CoWSwapFarm's assets should increase after farm deposit");
        assertEq(farm.liquidity(), 1000e6, "Error: CoWSwapFarm's liquidity should increase after farm deposit");

        // if we add some wrapped tokens, the liquidity should be the same, but assets should be higher
        wrapToken.mint(address(farm), 1000e18);
        assertEq(farm.assets(), 3000e6, "Error: CoWSwapFarm's assets does not reflect correct price from oracle");
        assertEq(farm.liquidity(), 1000e6, "Error: CoWSwapFarm's liquidity should increase after adding wrapped tokens");
    }

    function testDepositNoOp() public {
        // deposit should do nothing
        usdc.mint(address(farm), 1000e6);
        vm.prank(farmManagerAddress);
        farm.deposit();
        assertEq(farm.assets(), 1000e6, "Error: CoWSwapFarm's assets should increase after deposit");
        assertEq(farm.liquidity(), 1000e6, "Error: CoWSwapFarm's liquidity should increase after deposit");
    }

    function testWithdraw() public {
        usdc.mint(address(farm), 1000e6);
        vm.prank(farmManagerAddress);
        farm.withdraw(1000e6, address(farmManagerAddress));

        assertEq(farm.assets(), 0, "Error: CoWSwapFarm's assets should be 0 after withdraw");
        assertEq(farm.liquidity(), 0, "Error: CoWSwapFarm's liquidity should be 0 after withdraw");
        assertEq(
            usdc.balanceOf(address(farmManagerAddress)),
            1000e6,
            "Error: CoWSwapFarm's assets should be transferred to farmManagerAddress"
        );
    }

    function testSignWrapOrder() public returns (bytes memory orderUid) {
        usdc.mint(address(farm), 1000e6);

        vm.expectRevert("UNAUTHORIZED");
        orderUid = farm.signWrapOrder(1000e6, 500e18);

        vm.prank(msig);
        orderUid = farm.signWrapOrder(1000e6, 500e18);

        return orderUid;
    }

    function testSettleWrapOrder() public {
        bytes memory orderUid = testSignWrapOrder();

        mockSettlement.mockSettle(orderUid, address(usdc), 1000e6, address(wrapToken), 500e18);

        assertEq(farm.assets(), 1000e6, "Error: CoWSwapFarm's assets incorrect");
        assertEq(usdc.balanceOf(address(farm)), 0, "Error: CoWSwapFarm's usdc balance incorrect");
        assertEq(wrapToken.balanceOf(address(farm)), 500e18, "Error: CoWSwapFarm's wrapToken balance incorrect");
    }

    function testSignUnwrapOrder() public returns (bytes memory orderUid) {
        wrapToken.mint(address(farm), 500e18);

        vm.expectRevert("UNAUTHORIZED");
        orderUid = farm.signUnwrapOrder(500e18, 1000e6);

        vm.prank(msig);
        orderUid = farm.signUnwrapOrder(500e18, 1000e6);

        return orderUid;
    }

    function testSettleUnwrapOrder() public {
        bytes memory orderUid = testSignUnwrapOrder();

        mockSettlement.mockSettle(orderUid, address(wrapToken), 500e18, address(usdc), 1000e6);

        assertEq(farm.assets(), 1000e6, "Error: CoWSwapFarm's assets incorrect");
        assertEq(usdc.balanceOf(address(farm)), 1000e6, "Error: CoWSwapFarm's usdc balance incorrect");
        assertEq(wrapToken.balanceOf(address(farm)), 0, "Error: CoWSwapFarm's wrapToken balance incorrect");
    }
}
