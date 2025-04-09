// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {PendleV2Farm} from "@integrations/farms/PendleV2Farm.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {IntegrationTestPendleCalldata} from "@test/integration/farms/IntegrationTestPendleCalldata.sol";

contract IntegrationTestPendleV2Farm is Fixture, IntegrationTestPendleCalldata {
    address public constant _PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address public constant _PENDLE_MARKET = 0xa0ab94DeBB3cC9A7eA77f3205ba4AB23276feD08;
    address public constant _PENDLE_PT = 0xEe9085fC268F6727d5D4293dBABccF901ffDCC29;
    address public constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    PendleV2Farm public farm;
    FixedPriceOracle public oracle;

    function setUp() public override {
        // this test needs a specific fork network & block
        vm.createSelectFork("mainnet", 21236715);
        super.setUp();

        vm.warp(1732199459);
        vm.roll(21236715);

        // deploy farm
        oracle = new FixedPriceOracle(address(core), 1e6); // 1e18 USDE ~= 1e6 USDC

        // prank an address with nonce 0 to deploy the farm at a consistent address
        // this is required because the Pendle SDK takes as an argument the address of which to send
        // the results of the swap, and we hardcode router calldata in this test file.
        vm.prank(address(123456));
        farm = new PendleV2Farm(address(core), _USDC, _PENDLE_MARKET, _PENDLE_ORACLE, address(oracle));
    }

    function testSetup() public view {
        assertEq(address(farm.core()), address(core));
        assertEq(farm.maturity(), 1735171200);
        assertEq(farm.pendleMarket(), _PENDLE_MARKET);
        assertEq(farm.pendleOracle(), _PENDLE_ORACLE);
        assertEq(farm.ptToken(), _PENDLE_PT);
        assertEq(farm.assetToPtUnderlyingOracle(), address(oracle));

        assertEq(block.timestamp, 1732199459, "Wrong fork block");
        assertEq(address(farm), 0xB401175F5D37305304b8ab8c20fc3a49ff2A3190, "Wrong farm deploy address");
    }

    function testDepositAndWithdraw() public {
        assertEq(farm.assets(), 0);

        dealToken(_USDC, address(farm), 1_000e6);

        assertEq(ERC20(_PENDLE_PT).balanceOf(address(farm)), 0);
        assertEq(farm.assets(), 1_000e6);
        assertEq(farm.liquidity(), 1_000e6);

        // swap USDC to PTs
        // generate calldata at https://api-v2.pendle.finance/core/docs#/SDK%20(Recommended)/SdkController_swap
        vm.prank(msig);
        uint256 usdcAmountIn = 500e6;
        uint256 ptAmountOut = 509185354499248657266;
        address pendleRouter = 0x888888888889758F76e7103c6CbF23ABbF58F946;
        farm.wrapAssetToPt(usdcAmountIn, pendleRouter, _PENDLE_ROUTER_CALLDATA_1);

        // 500 USDC remaining after swap, the rest is in PTs
        assertEq(ERC20(_USDC).balanceOf(address(farm)), 500e6);
        assertEq(ERC20(_PENDLE_PT).balanceOf(address(farm)), ptAmountOut);

        // no yield interpolation yet
        assertEq(farm.assets(), 1_000e6);

        // fast-forward to just before maturity
        vm.warp(farm.maturity() - 1);

        // at ~maturity, assets should be 1000e6 + targetyield accounting for slippage
        // 500 USDC are still in the farm
        // 500 USDC were wrapped for 509.18 PTs
        // 1009.18 ==> real target amount after unwrapping
        // before unwrapping, we have a forced slippage accounting of 99.5%
        // so we should expect ~1005e6 before unwrapping

        assertApproxEqAbs(farm.assets(), 1005e6, 2e6);

        // fast forward just after maturity
        vm.warp(farm.maturity() + 1);

        assertApproxEqAbs(farm.assets(), 1005e6, 2e6);

        // redeem 250 matured PTs to USDC
        // generate calldata at https://api-v2.pendle.finance/core/docs#/SDK%20(Recommended)/SdkController_redeem
        vm.prank(msig);
        farm.unwrapPtToAsset(250e18, pendleRouter, _PENDLE_ROUTER_CALLDATA_2);

        assertEq(ERC20(_PENDLE_PT).balanceOf(address(farm)), ptAmountOut - 250e18);
        assertApproxEqAbs(ERC20(_USDC).balanceOf(address(farm)), 750e6, 1e6); // 250 PTs gave ~249.84 USDC

        // here the yield returned by the farm should be
        // ~750e6 + 259.18e6 * 99.5% (slippage)
        assertApproxEqAbs(farm.assets(), 750e6 + 259.18e6 * 0.995e18 / 1e18, 1e6);
        assertApproxEqAbs(farm.liquidity(), 750e6, 1e6);

        // unwrap the rest of PTs (259.185354499248657266)
        vm.prank(msig);
        farm.unwrapPtToAsset(ptAmountOut - 250e18, pendleRouter, _PENDLE_ROUTER_CALLDATA_3);

        assertEq(ERC20(_PENDLE_PT).balanceOf(address(farm)), 0);
        // 249.846654 USDC + 259.026161 USDC from redeeming 259.185354499248657266 PTs
        assertApproxEqAbs(ERC20(_USDC).balanceOf(address(farm)), 1008.5e6, 0.5e6);
        assertEq(farm.assets(), ERC20(_USDC).balanceOf(address(farm)));
    }

    function testMaxDeposit() public view {
        uint256 maxDeposit = farm.maxDeposit();
        require(maxDeposit == 150206179037180, "Max deposit amount is not correct!");
    }
}
