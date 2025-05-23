// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {ResolvOracle} from "@finance/oracles/ResolvOracle.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {PendleV2Farm} from "@integrations/farms/PendleV2Farm.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {IntegrationTestPendleCalldata} from "@test/integration/farms/IntegrationTestPendleCalldata.sol";

contract IntegrationTestPendleV2FarmResolv is Fixture, IntegrationTestPendleCalldata {
    address public constant _PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address public constant _PENDLE_MARKET = 0x35a18CD59a214c9e797e14b1191b700EEa251f6A;
    address public constant _PENDLE_PT = 0xae4bE3acD95B6a4Ac5A0524ab95dA90c721f6C83;
    address public constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant _USR = 0x66a1E37c9b0eAddca17d3662D6c05F4DECf3e110;

    PendleV2Farm public farm;
    ResolvOracle public oracle;

    function setUp() public override {
        // this test needs a specific fork network & block
        vm.createSelectFork("mainnet", 22325494);
        super.setUp();

        vm.warp(1745336354);
        vm.roll(22325494);

        // deploy farm
        oracle = new ResolvOracle();
        vm.startPrank(oracleManagerAddress);
        {
            accounting.setOracle(_USR, address(oracle));
            accounting.setOracle(_USDC, address(new FixedPriceOracle(address(core), 1e30)));
        }
        vm.stopPrank();

        // prank an address with nonce 0 to deploy the farm at a consistent address
        // this is required because the Pendle SDK takes as an argument the address of which to send
        // the results of the swap, and we hardcode router calldata in this test file.
        vm.prank(address(123456));
        farm = new PendleV2Farm(address(core), _USDC, _PENDLE_MARKET, _PENDLE_ORACLE, address(accounting));

        vm.prank(parametersAddress);
        farm.setPendleRouter(0x888888888889758F76e7103c6CbF23ABbF58F946);
    }

    function testSetup() public view {
        assertEq(address(farm.core()), address(core));
        assertEq(farm.maturity(), 1748476800);
        assertEq(farm.pendleMarket(), _PENDLE_MARKET);
        assertEq(farm.pendleOracle(), _PENDLE_ORACLE);
        assertEq(farm.ptToken(), _PENDLE_PT);
        assertEq(farm.accounting(), address(accounting));

        assertEq(oracle.price(), 1e18, "Unexpected oracle price");

        assertEq(block.timestamp, 1745336354, "Wrong fork block");
        assertEq(address(farm), 0xB401175F5D37305304b8ab8c20fc3a49ff2A3190, "Wrong farm deploy address");
    }

    function testDepositAndWrap() public {
        assertEq(farm.assets(), 0);

        dealToken(_USDC, address(farm), 1_000e6);

        assertEq(ERC20(_PENDLE_PT).balanceOf(address(farm)), 0);
        assertEq(farm.assets(), 1_000e6);
        assertEq(farm.liquidity(), 1_000e6);

        // swap USDC to PTs
        // generate calldata at https://api-v2.pendle.finance/core/v1/sdk/1/markets/0x35a18CD59a214c9e797e14b1191b700EEa251f6A/swap?receiver=0xB401175F5D37305304b8ab8c20fc3a49ff2A3190&slippage=0.01&enableAggregator=true&tokenIn=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48&tokenOut=0xae4bE3acD95B6a4Ac5A0524ab95dA90c721f6C83&amountIn=500000000&additionalData=effectiveApy
        vm.prank(msig);
        uint256 usdcAmountIn = 500e6;
        uint256 ptAmountOut = 503570913874768977448;
        farm.wrapAssetToPt(usdcAmountIn, _PENDLE_ROUTER_CALLDATA_6);

        // 500 USDC remaining after swap, the rest is in PTs
        assertEq(ERC20(_USDC).balanceOf(address(farm)), 500e6);
        assertEq(ERC20(_PENDLE_PT).balanceOf(address(farm)), ptAmountOut);

        // no yield interpolation yet
        assertEq(farm.assets(), 1_000e6);

        // fast forward just after maturity
        vm.warp(farm.maturity() + 1);

        assertApproxEqAbs(farm.assets(), 1002e6, 1e6);
    }
}
