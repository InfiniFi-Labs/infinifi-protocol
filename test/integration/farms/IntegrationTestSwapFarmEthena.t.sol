// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {SwapFarm} from "@integrations/farms/SwapFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {EthenaOracle} from "@finance/oracles/EthenaOracle.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {IntegrationTestSwapCalldata} from "@test/integration/farms/IntegrationTestSwapCalldata.sol";

contract IntegrationTestSwapFarmEthena is Fixture, IntegrationTestSwapCalldata {
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    EthenaOracle public oracle;
    SwapFarm public farm;

    function setUp() public override {
        // this test needs a specific fork network & block
        vm.createSelectFork("mainnet", 21414237);

        super.setUp();

        vm.warp(1734341951);
        vm.roll(21414237);

        // deploy
        oracle = new EthenaOracle();
        vm.startPrank(oracleManagerAddress);
        {
            accounting.setOracle(sUSDe, address(oracle));
            accounting.setOracle(USDC, address(new FixedPriceOracle(address(core), 1e30)));
        }
        vm.stopPrank();

        // prank an address with nonce 0 to deploy the farm at a consistent address
        // this is required because the Pendle SDK takes as an argument the address of which to send
        // the results of the swap, and we hardcode router calldata in this test file.
        vm.prank(address(123456));
        farm = new SwapFarm(address(core), USDC, sUSDe, address(accounting), 7 days);

        assertEq(block.timestamp, 1734341951, "Wrong fork block");
        assertEq(address(farm), 0xB401175F5D37305304b8ab8c20fc3a49ff2A3190, "Wrong farm deploy address");

        vm.prank(parametersAddress);
        farm.setEnabledRouter(0x6131B5fae19EA4f9D964eAc0408E4408b66337b5, true);
    }

    function testSetup() public view {
        // check oracle
        assertApproxEqAbs(oracle.price(), 1.169e18, 0.001e30, "Unexpected oracle price");

        // check constructor sets the correct values
        assertEq(farm.assetToken(), USDC);
        assertEq(farm.wrapToken(), sUSDe);
        assertEq(farm.accounting(), address(accounting));
        assertEq(farm.convertToAssets(1e18), 1136950); // 1 sUSDE ~= 1.136950 USDC
        assertEq(farm.liquidity(), 0);
        assertEq(farm.assets(), 0);
    }

    function testWrap() public {
        // deal 1k usdc to the farm
        dealToken(USDC, address(farm), 1_000e6);
        assertEq(farm.liquidity(), 1_000e6);
        assertEq(farm.assets(), 1_000e6);

        // swap USDC to sUSDe
        vm.prank(msig);
        uint256 amountIn = 800e6;
        uint256 amountOut = 703535949275306213742;
        address router = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        farm.wrapAssets(amountIn, router, _KYBER_ROUTER_CALLDATA_1);

        // 200 USDC remaining after swap, the rest is sUSDe
        assertEq(ERC20(USDC).balanceOf(address(farm)), 200e6);
        assertEq(ERC20(sUSDe).balanceOf(address(farm)), amountOut);

        // assets are marked to market
        assertEq(farm.liquidity(), 200e6);
        assertApproxEqAbs(farm.assets(), 1_000e6, 1e6);
    }

    function testUnwrapAndWithdraw() public {
        // deal 1k sUSDe to the farm
        dealToken(sUSDe, address(farm), 1_000e18);
        assertEq(farm.liquidity(), 0);
        assertEq(farm.assets(), 1136950681); // 1000 sUSDE ~= 1136.950681 USDC

        // unwrap sUSDe to USDC
        vm.prank(msig);
        uint256 amountIn = 500e18;
        uint256 amountOut = 566271085;
        address router = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
        farm.unwrapAssets(amountIn, router, _KYBER_ROUTER_CALLDATA_2);

        // 500 sUSDe remaining after swap, the rest is USDC
        assertEq(ERC20(sUSDe).balanceOf(address(farm)), 500e18);
        assertEq(ERC20(USDC).balanceOf(address(farm)), amountOut); // 500 sUSDe -> 566.271085 USDC

        assertEq(farm.liquidity(), amountOut);
        assertApproxEqAbs(farm.assets(), 1137e6, 5e6);
    }
}
