// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/console.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Fixture} from "@test/Fixture.t.sol";
import {SwapFarm} from "@integrations/farms/SwapFarm.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {MockSwapRouter} from "@test/mock/MockSwapRouter.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";

contract SwapFarmUnitTest is Fixture {
    SwapFarm farm;
    FixedPriceOracle wrapTokenOracle;
    MockERC20 wrapToken = new MockERC20("WRAP_TOKEN", "WT");
    MockSwapRouter router = new MockSwapRouter();

    function setUp() public override {
        super.setUp();

        wrapTokenOracle = new FixedPriceOracle(address(core), 0.5e30); // 1 wrapped token = 2 USDC
        farm = new SwapFarm(address(core), address(usdc), address(wrapToken), address(wrapTokenOracle));

        vm.label(address(farm), "SwapFarm");
        vm.label(address(router), "MockSwapRouter");
    }

    function testInitialState() public view {
        assertEq(
            farm.wrapTokenOracle(),
            address(wrapTokenOracle),
            "Error: SwapFarm's wrapTokenOracle does not reflect correct address"
        );
        assertEq(farm.assets(), 0, "Error: SwapFarm's assets should be 0");
        assertEq(farm.maturity(), block.timestamp + 30 days, "Error: SwapFarm's maturity is not set correctly");
        assertEq(farm.wrapToken(), address(wrapToken), "Error: SwapFarm's wrapToken does not reflect correct address");
        assertEq(farm.assetToken(), address(usdc), "Error: SwapFarm's assetToken does not reflect correct address");
    }

    function testAssetsAndLiquidity() public {
        // by default assets and liquidity are the same and are 0
        assertEq(farm.assets(), 0, "Error: SwapFarm's assets should be 0");
        assertEq(farm.liquidity(), 0, "Error: SwapFarm's liquidity should be 0");

        // if we deposit only assets (usdc), the assets and liquidity should be the same
        usdc.mint(address(farm), 1000e6);
        assertEq(farm.assets(), 1000e6, "Error: SwapFarm's assets should increase after farm deposit");
        assertEq(farm.liquidity(), 1000e6, "Error: SwapFarm's liquidity should increase after farm deposit");

        // if we add some wrapped tokens, the liquidity should be the same, but assets should be higher
        wrapToken.mint(address(farm), 1000e18);
        assertEq(
            farm.assets(),
            1000e6 + (1000e18 * 1e18 / wrapTokenOracle.price()),
            "Error: SwapFarm's assets does not reflect correct price from oracle"
        );
        assertEq(farm.liquidity(), 1000e6, "Error: SwapFarm's liquidity should increase after adding wrapped tokens");
    }

    function testDepositNoOp() public {
        // deposit should do nothing
        usdc.mint(address(farm), 1000e6);
        vm.prank(farmManagerAddress);
        farm.deposit();
        assertEq(farm.assets(), 1000e6, "Error: SwapFarm's assets should increase after deposit");
        assertEq(farm.liquidity(), 1000e6, "Error: SwapFarm's liquidity should increase after deposit");
    }

    function testWithdraw() public {
        usdc.mint(address(farm), 1000e6);
        vm.prank(farmManagerAddress);
        farm.withdraw(1000e6, address(farmManagerAddress));

        assertEq(farm.assets(), 0, "Error: SwapFarm's assets should be 0 after withdraw");
        assertEq(farm.liquidity(), 0, "Error: SwapFarm's liquidity should be 0 after withdraw");
        assertEq(
            usdc.balanceOf(address(farmManagerAddress)),
            1000e6,
            "Error: SwapFarm's assets should be transferred to farmManagerAddress"
        );
    }

    function testConvertToAssets(uint256 _wrapTokenAmount) public view {
        // uint256.max breaks the code because of the divWadDown
        // 1_000_000_000_000e18 is a random large number that should be safe
        // if wrappedToken is sUSDe, this is a safe upper bound
        _wrapTokenAmount = bound(_wrapTokenAmount, 1e18, 1_000_000_000_000e18);
        // convertToAssets should return the correct amount of assets
        assertEq(
            farm.convertToAssets(_wrapTokenAmount),
            _wrapTokenAmount * 1e18 / wrapTokenOracle.price(),
            "Error: SwapFarm's convertToAssets does not return correct amount of assets"
        );
    }

    function testWrapAssetsRevertsIfNotFarmSwapCaller() public {
        vm.expectRevert("UNAUTHORIZED");
        farm.wrapAssets(1000e18, address(router), "");
    }

    function testWrapAssetsRevertsIfSwapFailed() public {
        bytes memory revertData = abi.encodeWithSignature("Error(string)", "MockSwapRouter: swap failed");
        bytes memory expectedError = abi.encodeWithSelector(SwapFarm.SwapFailed.selector, revertData);

        vm.expectRevert(expectedError);
        vm.prank(msig);
        farm.wrapAssets(1000e6, address(router), abi.encodeWithSelector(MockSwapRouter.swapFail.selector));
    }

    function testWrapAssetsRevertsIfSlippageTooHigh() public {
        // we prepare the swap to take 1000e6 usdc and wrap to 10e18 wrapToken
        router.mockPrepareSwap(address(usdc), address(wrapToken), 1000e6, 10e18);

        // give 1000 usdc to the farm
        usdc.mint(address(farm), 1000e6);

        uint256 assetReceived = 10e18 * 1e18 / wrapTokenOracle.price();
        uint256 minAssetsOut = 1000e6 * 0.995e18 / 1e18;
        // we expect the swap to revert because the slippage is too high
        vm.expectRevert(abi.encodeWithSelector(SwapFarm.SlippageTooHigh.selector, minAssetsOut, assetReceived));
        vm.prank(msig);
        farm.wrapAssets(1000e6, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector));
    }

    function scenarioWrapAssets(uint256 _assetsIn, uint256 _wrapTokenAmount) public {
        // we prepare the swap to take 1000 usdc and wrap to 499 wrapToken
        router.mockPrepareSwap(address(usdc), address(wrapToken), _assetsIn, _wrapTokenAmount);

        // give 1000 usdc to the farm
        usdc.mint(address(farm), _assetsIn);

        // we expect the swap to revert because the slippage is too high
        vm.prank(msig);
        farm.wrapAssets(1000e6, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector));
    }

    function testWrapAssets() public {
        uint256 wrapTokenAmount = 499e18;
        scenarioWrapAssets(1000e6, wrapTokenAmount);
        assertEq(farm.assets(), wrapTokenAmount * 1e18 / wrapTokenOracle.price());
    }

    function testWrapAssetsRevertsIfInSwapCooldown() public {
        scenarioWrapAssets(1000e6, 500e18);
        vm.expectRevert(abi.encodeWithSelector(SwapFarm.SwapCooldown.selector));
        vm.prank(msig);
        farm.wrapAssets(1000e6, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector));
    }

    function testWrapAssetsTwiceWithWaitCoolDown() public {
        scenarioWrapAssets(1000e6, 500e18);
        vm.warp(block.timestamp + 1 days);
        scenarioWrapAssets(1000e6, 500e18);
    }

    function testUnwrapAssetsRevertsIfNotFarmSwapCaller() public {
        vm.expectRevert("UNAUTHORIZED");
        farm.unwrapAssets(500e18, address(router), "");
    }

    function testUnwrapAssetsRevertsInCooldown() public {
        scenarioWrapAssets(1000e6, 500e18);
        vm.expectRevert(abi.encodeWithSelector(SwapFarm.SwapCooldown.selector));
        vm.prank(msig);
        farm.unwrapAssets(500e18, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector));
    }

    function testUnwrapAssetsRevertsIfSwapFailed() public {
        bytes memory revertData = abi.encodeWithSignature("Error(string)", "MockSwapRouter: swap failed");
        bytes memory expectedError = abi.encodeWithSelector(SwapFarm.SwapFailed.selector, revertData);

        vm.expectRevert(expectedError);
        vm.prank(msig);
        farm.unwrapAssets(500e18, address(router), abi.encodeWithSelector(MockSwapRouter.swapFail.selector));
    }

    function testUnwrapAssetsRevertsIfSlippageTooHigh() public {
        scenarioWrapAssets(1000e6, 500e18);
        vm.warp(block.timestamp + 1 days);

        // prepare a swap that take 500 wrapToken and unwrap to 10e6 usdc, which is not enough
        router.mockPrepareSwap(address(wrapToken), address(usdc), 500e18, 10e6);

        uint256 assetsReceived = 10e6;
        uint256 minAssetsOut = 500e18 * 1e18 / wrapTokenOracle.price() * 0.995e18 / 1e18;
        vm.prank(msig);
        vm.expectRevert(abi.encodeWithSelector(SwapFarm.SlippageTooHigh.selector, minAssetsOut, assetsReceived));
        farm.unwrapAssets(500e18, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector));
    }

    function testUnwrapAssets() public {
        scenarioWrapAssets(1000e6, 500e18);
        vm.warp(block.timestamp + 1 days);
        assertEq(farm.assets(), 1000e6, "Error: SwapFarm's assets is not cooled down after scenario wrapping");
        assertEq(farm.liquidity(), 0, "Error: SwapFarm's liquidity should be 0 after scenario wrapping");

        // prepare a swap that take 500 wrapToken and unwrap to 1000 usdc
        router.mockPrepareSwap(address(wrapToken), address(usdc), 500e18, 1000e6);

        vm.prank(msig);
        farm.unwrapAssets(500e18, address(router), abi.encodeWithSelector(MockSwapRouter.swap.selector));

        assertEq(farm.assets(), 1000e6, "Error: SwapFarm's assets is not correct after unwrapping");
        assertEq(usdc.balanceOf(address(farm)), 1000e6, "Error: SwapFarm's assets should be transferred to farm");
        assertEq(farm.liquidity(), 1000e6, "Error: SwapFarm's liquidity should be correct after unwrapping");
    }
}
