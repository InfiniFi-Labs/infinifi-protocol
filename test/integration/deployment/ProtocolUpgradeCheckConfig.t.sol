pragma solidity 0.8.28;

import "@test/integration/deployment/ProtocolUpgradeFixture.sol";

contract ProtocolUpgradeCheckConfig is ProtocolUpgradeFixture {
    function testCoreReferences() public view {
        assertEq(address(core), address(longTimelock.core()));
        assertEq(address(core), address(shortTimelock.core()));
        assertEq(address(core), address(accounting.core()));
        assertEq(address(core), address(siusd.core()));
        assertEq(address(core), address(yieldSharing.core()));
        assertEq(address(core), address(farmRegistry.core()));
        assertEq(address(core), address(iusd.core()));
        assertEq(address(core), address(mintController.core()));
        assertEq(address(core), address(unwindingModule.core()));
        assertEq(address(core), address(manualRebalancer.core()));
        assertEq(address(core), address(oracleIusd.core()));
        assertEq(address(core), address(oracleUsdc.core()));
        assertEq(address(core), address(redeemController.core()));
        assertEq(address(core), address(allocationVoting.core()));
        assertEq(address(core), address(lockingController.core()));
        assertEq(address(core), address(gateway.core()));
        assertEq(address(core), address(minorRolesManager.core()));
        assertEq(address(core), address(emergencyWithdrawal.core()));
    }

    function testGatewayReferences() public view {
        assertEq(gateway.getAddress("USDC"), address(usdc));
        assertEq(gateway.getAddress("mintController"), address(mintController));
        assertEq(gateway.getAddress("redeemController"), address(redeemController));
        assertEq(gateway.getAddress("stakedToken"), address(siusd));
        assertEq(gateway.getAddress("receiptToken"), address(iusd));
        assertEq(gateway.getAddress("allocationVoting"), address(allocationVoting));
        assertEq(gateway.getAddress("lockingController"), address(lockingController));
        assertEq(gateway.getAddress("yieldSharing"), address(yieldSharing));
    }

    function testFarmRegistry() public view {
        // enabled assets
        assertEq(farmRegistry.getEnabledAssets().length, 1);
        assertEq(farmRegistry.getEnabledAssets()[0], address(usdc));

        // protocol farms
        assertEq(farmRegistry.getTypeFarms(FarmTypes.PROTOCOL).length, 2);
        assertEq(farmRegistry.getTypeFarms(FarmTypes.PROTOCOL)[0], address(mintController));
        assertEq(farmRegistry.getTypeFarms(FarmTypes.PROTOCOL)[1], address(redeemController));

        // liquid farms
        assertEq(farmRegistry.getTypeFarms(FarmTypes.LIQUID).length, 4);

        // illiquid farms
        assertEq(farmRegistry.getTypeFarms(FarmTypes.MATURITY).length, 6);
    }

    function testOracles() public view {
        assertEq(accounting.price(address(usdc)), 1e30);
    }

    function testSharePricesInitialized() public view {
        uint256 min = 1e12; // 0.000001 iUSD

        // siUSD
        assertGt(siusd.totalSupply(), min);

        // locking module
        for (uint32 i = 1; i <= 12; i++) {
            address token = lockingController.shareToken(i);
            assertGt(ERC20(token).totalSupply(), min);
        }

        // unwinding module
        assertGt(unwindingModule.totalShares(), min);
    }

    function testNoPendingLosses() public view {
        assertGe(yieldSharing.unaccruedYield(), 0);
    }

    function testNoRealizedLosses() public view {
        assertEq(accounting.price(address(iusd)), 1e18);

        assertGe(siusd.convertToAssets(1e18), 1e18);

        for (uint32 i = 1; i <= 12; i++) {
            assertGe(lockingController.exchangeRate(i), 1e18);
        }

        assertEq(unwindingModule.slashIndex(), 1e18);
    }
}
