pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {BaseHookTest} from "@test/unit/farms/movement/BaseHook.t.sol";
import {MockPartialFarm} from "@test/mock/MockPartialFarm.sol";
import {BeforeRedeemHook} from "@integrations/farms/movement/BeforeRedeemHook.sol";

contract BeforeRedeemHookTest is BaseHookTest, BeforeRedeemHook {
    constructor() BeforeRedeemHook(address(this), address(this), address(this), address(0)) {}

    function withdraw(uint256 _amount, address _to) public onlyCoreRole(CoreRoles.FARM_MANAGER) {
        MockPartialFarm(_to).directDeposit(_amount);
    }

    /// ============================================================
    /// Test suite for the LiabilityHooks contract
    /// ============================================================
    function testFindOptimalRedeemFarm()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(10 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[1], "Optimal farm should be farm 2 with 20% weight");
    }

    function testFindOptimalRedeemFarmNoAssets()
        public
        configureFarms(0, 0, 0)
        setWeights(20, 60, 20)
        setAmount(10 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, address(0), "Farm should be address(0) indicating no assets in the farm");
    }

    function testFindOptimalRedeemInsufficientLiquidity()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(50, 25, 25)
        setAmount(60 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, address(0), "Farm should be address(0) indicating insufficient liquidity");
    }

    /// If the farm has no weight, it should be emptied by redeeming from it
    /// We do not expect this to happen due to existence of manual rebalancing
    /// But it is good to have this test to ensure the logic will still work as expected without it
    function testFindOptimalRedeemFarmNoWeightInFarm()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(90, 0, 10)
        setAmount(10 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[1], "Optimal farm should be farm 2 with 0% weight");
    }

    function testFindOptimalRedeemFarmSkippingEmpty()
        public
        configureFarms(0 ether, 50 ether, 50 ether)
        setWeights(0, 50, 50)
        setAmount(20 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[1], "Optimal farm should be farm 2 with 50% weight");
    }

    /// When farm has exactly the amount to redeem, it should be emptied if the weights are calculated correctly
    function testFindOptimalRedeemEmptiesFarm()
        public
        configureFarms(10 ether, 50 ether, 50 ether)
        setWeights(0, 50, 50)
        setAmount(10 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, farms[0], "Should entirely drain farm 1");
    }

    function testRedeemWorkflow()
        public
        configureFarms(50 ether, 50 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(1 ether)
    {
        MockPartialFarm _controllerFarm = new MockPartialFarm(amount);

        for (uint256 i = 0; i < 50; i++) {
            address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
            MockPartialFarm(farm).withdraw(amount, address(_controllerFarm));
        }

        uint256 farm1Percentage = (_getFarmAssetPercentage(address(farm1)) * 100) / PRECISION;
        uint256 farm2Percentage = (_getFarmAssetPercentage(address(farm2)) * 100) / PRECISION;
        uint256 farm3Percentage = (_getFarmAssetPercentage(address(farm3)) * 100) / PRECISION;

        assertApproxEqAbs(farm1Percentage, 60, 5, "Farm 1 should have ~60% weight");
        assertApproxEqAbs(farm2Percentage, 20, 5, "Farm 2 should have ~20% weight");
        assertApproxEqAbs(farm3Percentage, 20, 5, "Farm 3 should have ~20% weight");
    }

    function testBeforeRedeemNormal()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(10 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 90 ether, "Total liquid assets should be 90 ether after redeeming");
    }

    /// Even though the farm has insufficient liquidity, it should still be able to redeem the amount
    /// Since it will apply the proportional redeem from all farms
    function testBeforeRedeemProportional()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(50, 25, 25)
        setAmount(60 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 90 ether, "Total liquid assets should be 90 ether after redeeming");
    }

    function testBeforeRedeemProportionalEntireLiquidity()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(50, 25, 25)
        setAmount(150 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 0, "Total liquid assets should be 0 after redeeming");
    }

    /// This shows the case where some amount can be redeemed from the farms,
    /// but not enough to cover the entire redeem amount.
    /// The remaining amount is probably enqueued to be redeemed later
    function testBeforeRedeemInsufficientLiquidity()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(50, 25, 25)
        setAmount(200 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 0, "Total liquid assets should be 0 after redeeming");
    }

    /// @notice Test redeem when there are no farms available
    function testBeforeRedeemNoFarms() public configureFarms(0, 0, 0) setWeights(0, 0, 0) setAmount(10 ether) {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 0, "Total liquid assets should be 0 after redeeming");
    }

    /// @notice Test redeem when total power is 0 but farms have assets
    function testBeforeRedeemZeroPower()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(0, 0, 0)
        setAmount(10 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 90 ether, "Total liquid assets should be 90 ether after redeeming");
    }

    /// @notice Test redeem with zero amount
    function testBeforeRedeemZeroAmount()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(0)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 100 ether, "Total liquid assets should remain unchanged");
    }

    /// @notice Test redeem when all farms have equal weights
    function testBeforeRedeemEqualWeights()
        public
        configureFarms(30 ether, 30 ether, 30 ether)
        setWeights(33, 33, 34)
        setAmount(15 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 75 ether, "Total liquid assets should be 75 ether after redeeming");
    }

    /// @notice Test redeem when one farm has all the weight
    function testBeforeRedeemSingleFarmWeight()
        public
        configureFarms(30 ether, 30 ether, 30 ether)
        setWeights(100, 0, 0)
        setAmount(20 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 70 ether, "Total liquid assets should be 70 ether after redeeming");
    }

    /// @notice Test redeem when asset is not enabled
    function testBeforeRedeemAssetNotEnabled()
        public
        configureFarms(30 ether, 30 ether, 30 ether)
        setWeights(100, 0, 0)
        setAmount(20 ether)
    {
        controllerFarm.setAsset(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(BeforeRedeemHook.AssetNotEnabled.selector, address(0xdead)));
        controllerFarm.callRedeemHook(this, amount);
    }

    /// @notice Test redeem when farms have very uneven distribution
    function testBeforeRedeemUnevenDistribution()
        public
        configureFarms(80 ether, 10 ether, 10 ether)
        setWeights(20, 40, 40)
        setAmount(20 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 80 ether, "Total liquid assets should be 80 ether after redeeming");
    }

    /// @notice Test redeem with exact amount matching a farm's balance
    function testBeforeRedeemExactFarmBalance()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(40 ether)
    {
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 60 ether, "Total liquid assets should be 60 ether after redeeming");
    }

    /// @notice Test redeem with multiple sequential small redemptions
    function testBeforeRedeemMultipleSmallRedemptions()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(50, 25, 25)
        setAmount(10 ether)
    {
        for (uint256 i = 0; i < 5; i++) {
            controllerFarm.callRedeemHook(this, amount);
        }
        assertEq(totalAssetsOf(address(0), 0), 100 ether, "Total liquid assets should be 100 ether after redeeming");
    }

    function testBeforeRedeemPausedFarm()
        public
        configureFarms(20 ether, 40 ether, 40 ether)
        setWeights(60, 20, 20)
        setAmount(10 ether)
    {
        address farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertEq(farm, address(farm2), "Optimal farm should be farm 2 with 20% weight");

        farm2.pause();

        farm = _findOptimalRedeemFarm(farms, weights, _getTotalPower(), _getTotalAssets(), amount);
        assertNotEq(farm, address(farm2), "Pausing the farm should exclude it");
    }

    // Prove that farm will not be skipped for proportional redeem
    // This is intentional!
    function testBeforeRedeemProportionalPausedFarm()
        public
        configureFarms(50 ether, 50 ether, 50 ether)
        setWeights(50, 25, 25)
        setAmount(60 ether)
    {
        farm1.pause();

        // we should only have 50 + 20 + 20 = 90 ether remaining
        controllerFarm.callRedeemHook(this, amount);
        assertEq(totalAssetsOf(address(0), 0), 90 ether, "Total liquid assets should be 90 ether after redeeming");
    }
}
