// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Fixture} from "@test/Fixture.t.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {MockISYToken} from "@test/mock/pendle/MockISYToken.sol";
import {MockSwapRouter} from "@test/mock/MockSwapRouter.sol";
import {MockPendleMarket} from "@test/mock/pendle/MockPendleMarket.sol";
import {MockPendleOracle} from "@test/mock/pendle/MockPendleOracle.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {MockISYTokenNoCap} from "@test/mock/pendle/MockISYTokenNoCap.sol";
import {Farm, PendleV2Farm} from "@integrations/farms/PendleV2Farm.sol";

contract PendleV2FarmUnitTest is Fixture {
    MockPendleMarket pendleMarket;
    MockPendleOracle pendleOracle;
    FixedPriceOracle underlyingOracle;
    MockISYToken syToken = new MockISYToken("SY_TOKEN", "SYT");
    MockERC20 ptToken = new MockERC20("PT_TOKEN", "PTT");
    address ytToken = makeAddr("YT_TOKEN");
    PendleV2Farm farm;

    MockPendleMarket pendleMarketNoCap;
    MockPendleOracle pendleOracleNoCap;
    MockISYTokenNoCap syTokenNoCap = new MockISYTokenNoCap("SY_TOKEN", "SYT");
    MockERC20 ptTokenNoCap = new MockERC20("PT_TOKEN", "PTT");
    address ytTokenNoCap = makeAddr("YT_TOKEN");
    PendleV2Farm farmNoCap;

    MockSwapRouter router = new MockSwapRouter();

    function setUp() public override {
        super.setUp();

        pendleMarket = new MockPendleMarket();
        pendleOracle = new MockPendleOracle();
        underlyingOracle = new FixedPriceOracle(address(core), 1e18); // 1$
        pendleMarket.mockSetExpiry(block.timestamp + 30 days);
        pendleMarket.mockSetTokens(address(syToken), address(ptToken), ytToken);
        pendleOracle.mockSetRate(0.8e18);

        syToken.setAbsoluteSupplyCap(25_000e18);
        syToken.setAbsoluteTotalSupply(0);

        vm.prank(oracleManagerAddress);
        accounting.setOracle(address(syToken), address(underlyingOracle));

        farm = new PendleV2Farm(
            address(core), address(usdc), address(pendleMarket), address(pendleOracle), address(accounting)
        );

        pendleMarketNoCap = new MockPendleMarket();
        pendleOracleNoCap = new MockPendleOracle();
        pendleMarketNoCap.mockSetExpiry(block.timestamp + 30 days);
        pendleMarketNoCap.mockSetTokens(address(syTokenNoCap), address(ptTokenNoCap), ytTokenNoCap);
        pendleOracleNoCap.mockSetRate(0.8e18);

        farmNoCap = new PendleV2Farm(
            address(core), address(usdc), address(pendleMarketNoCap), address(pendleOracleNoCap), address(accounting)
        );

        vm.prank(parametersAddress);
        farm.setPendleRouter(address(router));

        vm.prank(parametersAddress);
        farmNoCap.setPendleRouter(address(router));
    }

    function scenarioDepositAssetsAndWrapBeforeMaturity(uint256 assetsIn, uint256 targetYield) public {
        // deposit assets
        usdc.mint(address(farm), assetsIn);
        vm.prank(farmManagerAddress);
        farm.deposit();

        // if yield is 0.25e18, 1000e6 USDC should give 1250e18 PTs, 25% yield at maturity
        uint256 assetInNormalizedTo18 = assetsIn * 1e12;
        uint256 ptOut = assetInNormalizedTo18 + (assetInNormalizedTo18 * targetYield / 1e18);
        router.mockPrepareSwap(address(usdc), address(ptToken), assetsIn, ptOut);
        bytes memory routerCalldata = abi.encodeWithSelector(MockSwapRouter.swap.selector);

        // wrap assets
        pendleOracle.mockSetRate(assetInNormalizedTo18 * 1e18 / ptOut);
        vm.prank(msig);
        farm.wrapAssetToPt(assetsIn, routerCalldata);
    }

    function scenarioUnwrapPTAfterMaturity() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        pendleOracle.mockSetRate(1e18);
        vm.warp(pendleMarket.expiry()); // warp to after maturity

        // unwrap assets
        // the 1250 PTs will be unwrapped for 1250e6 USDC
        router.mockPrepareSwap(address(ptToken), address(usdc), 1250e18, 1250e6);
        bytes memory routerCalldata = abi.encodeWithSelector(MockSwapRouter.swap.selector);
        vm.prank(msig);
        farm.unwrapPtToAsset(1250e18, routerCalldata);
    }

    function testInitialState() public view {
        assertEq(farm.pendleMarket(), address(pendleMarket));
        assertEq(farm.pendleOracle(), address(pendleOracle));
        assertEq(farm.accounting(), address(accounting));
        assertEq(farm.assets(), 0);
        assertEq(farm.maturity(), pendleMarket.expiry());
        assertEq(farm.ptToken(), address(ptToken));
        assertEq(farm.assetToken(), address(usdc));
    }

    function testPendleV2NoCapMaxDeposit() public view {
        // by default, the farm cap is the cap of the SY token
        assertEq(
            farmNoCap.maxDeposit(), type(uint256).max, "Max deposit amount of Farm with no cap should be max uint256!"
        );
    }

    function testCannotCallDepositAfterMaturity() public {
        vm.warp(pendleMarket.expiry() + 1);
        vm.expectRevert(abi.encodeWithSelector(PendleV2Farm.PTAlreadyMatured.selector, pendleMarket.expiry()));
        vm.prank(farmManagerAddress);
        farm.deposit();
    }

    /// @notice test noop deposit but does not revert
    function testDeposit() public {
        vm.prank(farmManagerAddress);
        farm.deposit();
    }

    function testAssetsBeforeMaturity() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        assertEq(farm.assets(), 1000e6, "assets should be 1000e6 just after wrapping 1000 USDC");

        // yield interpolation for a 30 days maturity with 20% target yield means
        uint256 targetYieldWithSlippage = 1250e6 * 0.995e18 / 1e18;
        uint256 yieldPerSecWithSlippage = (targetYieldWithSlippage - 1000e6) * 1e18 / uint256(30 days);
        // warp 1000 seconds
        vm.warp(block.timestamp + 1000);
        assertEq(
            farm.assets(), 1000e6 + yieldPerSecWithSlippage * 1000 / 1e18, "assets should be 1000e6 + interpolatedYield"
        );

        // warp to maturity - 1, should return 99.5% of 1250 USDC
        vm.warp(pendleMarket.expiry() - 1);
        assertApproxEqAbs(
            farm.assets(), targetYieldWithSlippage, 1e6, "assets should be ~1250e6 * slippage just before maturity"
        );
    }

    function testMultipleAssetsDepositsBeforeMaturity() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        assertEq(farm.assets(), 1000e6, "assets should be 1000e6 just after wrapping 1000 USDC");
        uint256 targetYieldWithSlippage = 1250e6 * 0.995e18 / 1e18;
        uint256 yieldPerSecWithSlippage = (targetYieldWithSlippage - 1000e6) * 1e18 / uint256(30 days);
        // warp 15 days, exactly half of the maturity
        vm.warp(block.timestamp + 15 days);
        assertEq(
            farm.assets(),
            1000e6 + yieldPerSecWithSlippage * 15 days / 1e18,
            "assets should be 1000e6 + interpolatedYield"
        );
        uint256 alreadyInterpolatedYield = farm.assets() - 1000e6;

        // deposit again but because we're already at half of the maturity,
        // the amount of PT received for wrapping 1000 USDC would be 1125 and not 1250
        // (target yield is now 12.5% while it was 25% at first)
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.125e18);

        // assert should now be 2000e6 + alreadyInterpolatedYield
        assertEq(farm.assets(), 2000e6 + alreadyInterpolatedYield, "assets should be 2000e6 + interpolatedYield");

        vm.warp(pendleMarket.expiry() - 1);
        // warping to maturity should give us approx 1250 + 1125 (the amount of PT received for both swaps)
        uint256 newTargetYieldWithSlippage = (1250e6 + 1125e6) * 0.995e18 / 1e18;
        assertApproxEqAbs(
            farm.assets(), newTargetYieldWithSlippage, 1e6, "assets should be 2000e6 + interpolatedYield + 250e6"
        );
    }

    function testAssetsAfterMaturity() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        pendleOracle.mockSetRate(1e18); // + 100% value
        vm.warp(pendleMarket.expiry() + 3 weeks); // warp to after maturity

        // because PTs are still not unwrapped here, we should account for slippage
        assertEq(farm.assets(), 1250e6 * 0.995e18 / 1e18);
    }

    function testWrapAssetToPtRevertIfNotFarmSwapCaller() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(makeAddr("NOT_FARM_SWAP_CALLER"));
        farm.wrapAssetToPt(1000e6, "0x");
    }

    function testWrapAssetToPtRevertIfAfterMaturity() public {
        vm.warp(pendleMarket.expiry() + 1);
        vm.expectRevert(abi.encodeWithSelector(PendleV2Farm.PTAlreadyMatured.selector, pendleMarket.expiry()));
        vm.prank(msig);
        farm.wrapAssetToPt(1000e6, "0x");
    }

    function testWrapAssetToPtRevertIfSwapFails() public {
        bytes memory revertData = abi.encodeWithSignature("Error(string)", "MockSwapRouter: swap failed");
        bytes memory expectedError = abi.encodeWithSelector(PendleV2Farm.SwapFailed.selector, revertData);

        vm.expectRevert(expectedError);
        vm.prank(msig);
        farm.wrapAssetToPt(1000e6, abi.encodeWithSelector(MockSwapRouter.swapFail.selector));
    }

    function testWrapAssetToPtRevertIfTooMuchSlippage() public {
        uint256 assetsIn = 1000e6;
        uint256 ptsOut = 500e18;
        // deposit assets
        usdc.mint(address(farm), assetsIn);

        // swapping 1000e6 usdc will give 500e18 ptToken, which is not enough
        router.mockPrepareSwap(address(usdc), address(ptToken), assetsIn, ptsOut);
        bytes memory routerCalldata = abi.encodeWithSelector(MockSwapRouter.swap.selector);

        uint256 minAssets = 1000e6 * 0.995e18 / 1e18;
        uint256 assetsOut = ptsOut * pendleOracle.getPtToAssetRate(address(ptToken), 3600) / 1e30; // 1e30 to normalize to usdc 6 decimals
        // wrap assets
        vm.expectRevert(abi.encodeWithSelector(Farm.SlippageTooHigh.selector, minAssets, assetsOut));
        vm.prank(msig);
        farm.wrapAssetToPt(assetsIn, routerCalldata);
    }

    function testWrapAssetToPt(uint256 assetsIn, uint256 targetYield) public {
        assetsIn = bound(assetsIn, 1e6, 10_000_000e6);
        targetYield = bound(targetYield, 0.01e18, 0.5e18);
        scenarioDepositAssetsAndWrapBeforeMaturity(assetsIn, targetYield);
        assertEq(farm.assets(), assetsIn);
        assertApproxEqAbs(
            ERC20(farm.ptToken()).balanceOf(address(farm)), (assetsIn + (assetsIn * targetYield / 1e18)) * 1e12, 1e12
        );
    }

    function testUnwrapPtToAssetShouldRevertIfNotFarmSwapCaller() public {
        vm.expectRevert("UNAUTHORIZED");
        vm.prank(makeAddr("NOT_FARM_SWAP_CALLER"));
        farm.unwrapPtToAsset(1000e18, "0x");
    }

    function testUnwrapPtToAssetShouldRevertIfBeforeMaturity() public {
        vm.warp(pendleMarket.expiry() - 1);
        vm.expectRevert(abi.encodeWithSelector(PendleV2Farm.PTNotMatured.selector, pendleMarket.expiry()));
        vm.prank(msig);
        farm.unwrapPtToAsset(1000e18, "0x");
    }

    function testUnwrapPtToAssetShouldRevertIfSwapFails() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        vm.warp(pendleMarket.expiry() + 1);

        bytes memory revertData = abi.encodeWithSignature("Error(string)", "MockSwapRouter: swap failed");
        bytes memory expectedError = abi.encodeWithSelector(PendleV2Farm.SwapFailed.selector, revertData);
        vm.expectRevert(expectedError);
        vm.prank(msig);
        farm.unwrapPtToAsset(1250e18, abi.encodeWithSelector(MockSwapRouter.swapFail.selector));
    }

    function testUnwrapPtToAssetShouldRevertIfSlippageTooHigh() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        vm.warp(pendleMarket.expiry() + 1);

        // assume 100% profit
        pendleOracle.mockSetRate(1e18);

        // assuming 25% yield, we should have 1250e6 USDC when unwrapping
        // 1250e18 ptToken
        uint256 minAssets = 1250e6 * 0.995e18 / 1e18;

        // we prepare the swap to take 1250e18 ptToken and
        // give only 950e6 usdc back, which is less than 1250e6 * 0.995e18 / 1e18
        router.mockPrepareSwap(address(ptToken), address(usdc), 1250e18, 950e6);

        vm.expectRevert(abi.encodeWithSelector(Farm.SlippageTooHigh.selector, minAssets, 950e6));
        vm.prank(msig);
        farm.unwrapPtToAsset(1250e18, abi.encodeWithSelector(MockSwapRouter.swap.selector));
    }

    function testUnwrapPtToAsset() public {
        scenarioUnwrapPTAfterMaturity();
        assertEq(farm.assets(), 1250e6);
        assertEq(ERC20(farm.ptToken()).balanceOf(address(farm)), 0);
    }

    function testWithdrawal() public {
        scenarioUnwrapPTAfterMaturity();
        vm.prank(farmManagerAddress);
        farm.withdraw(1250e6, msig);
        assertEq(usdc.balanceOf(msig), 1250e6);
    }

    function testLiquidityShouldBe0WhenNoAssetsInFarm() public view {
        assertEq(farm.liquidity(), 0);
    }

    function testLiquidityShouldBeAmountHeldWhenNotWrappedInFarm() public {
        usdc.mint(address(farm), 1000e6);
        assertEq(farm.liquidity(), 1000e6);
    }

    function testLiquidityShouldOnlyBeAssetsHeldWhenSomeAssetsAreWrapped() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        assertEq(farm.liquidity(), 0);
        // if we mint some usdc to the farm while
        // some USDC are wrapped, it should only be the assets held that are counted
        usdc.mint(address(farm), 222e6);
        assertEq(farm.liquidity(), 222e6);
    }

    function testUnderlyingRateChangeNotOverflowing() public {
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);
        uint256 ts = block.timestamp;
        uint256 expiry = farm.maturity();
        vm.warp((ts + expiry) / 2);
        scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18);

        vm.prank(oracleManagerAddress);
        underlyingOracle.setPrice(0.79999e18);
        //  vm.expectRevert(abi.encodeWithSelector(Farm.SlippageTooHigh.selector, 99500000, 799990000));
        try this.scenarioDepositAssetsAndWrapBeforeMaturity(1000e6, 0.25e18) {}
        catch (bytes memory reason) {
            // Make sure this error is slippage error from the above comment
            assertEq(bytes4(reason), Farm.SlippageTooHigh.selector, "Expected SlippageTooHigh error");
        }
    }
}
