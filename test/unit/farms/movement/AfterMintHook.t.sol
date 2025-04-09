pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseHookTest} from "@test/unit/farms/movement/BaseHook.t.sol";
import {AfterMintHook} from "@integrations/farms/movement/AfterMintHook.sol";
import {MockPartialFarm} from "@test/mock/MockPartialFarm.sol";

contract AfterMintHookTest is BaseHookTest, AfterMintHook {
    constructor() AfterMintHook(address(this), address(this), address(this)) {}

    /// ============================================================
    /// Test suite for the LiabilityHooks contract
    /// ============================================================

    function testFindOptimalDepositFarm()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(1000 ether)
    {
        address farm = _findOptimalDepositFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[0], "Optimal farm should be farm 1 with 60% weight");
    }

    function testFindOptimalDepositFarmNoAssets()
        public
        configureFarms(0, 0, 0)
        setWeights(20, 60, 20)
        setAmount(10 ether)
    {
        address farm = _findOptimalDepositFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[1], "Optimal farm should be farm 2 with 60% weight");
    }

    /// While this will debalance the farms, it will favor the farm with the greatest weight
    function testFindOptimalDepositFarmPerfectBalance()
        public
        configureFarms(20 ether, 30 ether, 50 ether)
        setWeights(20, 30, 50)
        setAmount(100 ether)
    {
        address farm = _findOptimalDepositFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[2], "Optimal farm should be farm 3 with 50% weight");
    }

    function testFindOptimalDepositFarmNoWeightInFarm()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(90, 0, 10)
        setAmount(100 ether)
    {
        address farm = _findOptimalDepositFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[0], "Optimal farm should be farm 1 with 90% weight");
    }

    function testDepositWorkflow()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(10 ether)
    {
        for (uint256 i = 0; i < 100; i++) {
            address farm = _findOptimalDepositFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
            MockPartialFarm(farm).directDeposit(amount);
        }

        assertEq(_getFarmAssetPercentage(address(farm1)), (60 * PRECISION) / 100, "Farm 1 should have 60% weight");
        assertEq(_getFarmAssetPercentage(address(farm2)), (20 * PRECISION) / 100, "Farm 2 should have 20% weight");
        assertEq(_getFarmAssetPercentage(address(farm3)), (20 * PRECISION) / 100, "Farm 3 should have 20% weight");
    }

    /// Verifies the simple flow
    function testAfterMint()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(10 ether)
    {
        controllerFarm.directDeposit(amount);
        controllerFarm.callMintHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 110 ether, "Total liquid assets should be 10 ether after minting");
    }

    function testAfterMintEvenSplit()
        public
        configureFarms(0 ether, 0 ether, 0 ether)
        setWeights(0, 50, 50)
        setAmount(100 ether)
    {
        controllerFarm.directDeposit(amount * 2);
        controllerFarm.callMintHook(this, amount);
        controllerFarm.callMintHook(this, amount);

        assertEq(farm2.assets(), farm3.assets(), "Even split has to put money 50-50");
    }
}
