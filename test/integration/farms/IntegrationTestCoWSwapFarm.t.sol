// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {GPv2Trade} from "@cowprotocol/contracts/libraries/GPv2Trade.sol";
import {EthenaOracle} from "@finance/oracles/EthenaOracle.sol";
import {CoWSwapFarm} from "@integrations/farms/CoWSwapFarm.sol";
import {GPv2Settlement} from "@cowprotocol/contracts/GPv2Settlement.sol";
import {GPv2Interaction} from "@cowprotocol/contracts/libraries/GPv2Interaction.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {GPv2Order, IERC20 as ICoWERC20} from "@cowprotocol/contracts/libraries/GPv2Order.sol";

contract IntegrationTestCoWSwapFarm is Fixture {
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;
    address public solverAddress = 0x008300082C3000009e63680088f8c7f4D3ff2E87;

    EthenaOracle public oracle;
    CoWSwapFarm public farm;

    uint256 public counter = 0;

    function incrementCounter(uint256 x) public {
        counter += x;
    }

    function sendTokens(address token, address to, uint256 amount) public {
        ERC20(token).transfer(to, amount);
    }

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
        farm =
            new CoWSwapFarm(address(core), USDC, sUSDe, address(accounting), 7 days, COW_SETTLEMENT, COW_VAULT_RELAYER);

        assertEq(block.timestamp, 1734341951, "Wrong fork block");
        assertEq(address(farm), 0xB401175F5D37305304b8ab8c20fc3a49ff2A3190, "Wrong farm deploy address");
    }

    function testSetup() public view {
        // check oracle
        assertApproxEqAbs(oracle.price(), 1.137e18, 0.001e18, "Unexpected oracle price");

        // check constructor sets the correct values
        assertEq(farm.assetToken(), USDC);
        assertEq(farm.wrapToken(), sUSDe);
        assertEq(farm.accounting(), address(accounting));
        assertApproxEqAbs(farm.convertToAssets(1e18), 1.137e6, 0.001e6); // 1 sUSDE ~= 1.137 USDC
        assertApproxEqAbs(farm.convertToWrapTokens(1e6), 0.879e18, 0.001e18); // 1 USDC ~= 0.879 sUSDE
        assertEq(farm.liquidity(), 0);
        assertEq(farm.assets(), 0);
    }

    function testSignOrder() public {
        // deal 1k usdc to the farm
        dealToken(USDC, address(farm), 1_000e6);
        assertEq(farm.liquidity(), 1_000e6);
        assertEq(farm.assets(), 1_000e6);

        // order swap of USDC to sUSDe
        vm.prank(msig);
        bytes memory orderUid = farm.signWrapOrder(1000e6, 879e18);

        assertEq(
            GPv2Settlement(payable(COW_SETTLEMENT)).preSignature(orderUid),
            uint256(keccak256("GPv2Signing.Scheme.PreSign"))
        );
    }

    function testSettlement() public {
        // deal 1k usdc to the farm
        dealToken(USDC, address(farm), 1_000e6);
        assertEq(farm.liquidity(), 1_000e6);
        assertEq(farm.assets(), 1_000e6);

        // deal 880 sUSDe to solve the trade
        uint256 amountOut = 880e18;
        uint256 minAmountOut = amountOut - 1e18;
        dealToken(sUSDe, address(this), amountOut);

        // order swap of USDC to sUSDe
        vm.prank(msig);
        farm.signWrapOrder(1000e6, minAmountOut);

        ICoWERC20[] memory tokens = new ICoWERC20[](2);
        tokens[0] = ICoWERC20(USDC);
        tokens[1] = ICoWERC20(sUSDe);

        uint256[] memory clearingPrices = new uint256[](2);
        clearingPrices[0] = 1e18;
        clearingPrices[1] = farm.convertToAssets(1e18); // ~= 1.137e6

        GPv2Trade.Data[] memory trades = new GPv2Trade.Data[](1);
        trades[0] = GPv2Trade.Data({
            sellTokenIndex: 0,
            buyTokenIndex: 1,
            receiver: address(farm),
            sellAmount: 1000e6,
            buyAmount: minAmountOut,
            validTo: uint32(block.timestamp + 20 minutes),
            appData: 0x3cac71ef99d0dfbf5b937334b5b7ab672b679ba2bbd4d6fe8e0c54a2dab31109,
            feeAmount: 0,
            flags: 96, // sell order, non partially fillable, ERC20_BALANCE, pre_sign
            executedAmount: 0,
            signature: hex"b401175f5d37305304b8ab8c20fc3a49ff2a3190" // farm address
        });

        GPv2Interaction.Data[] memory interaction1 = new GPv2Interaction.Data[](1);
        interaction1[0] = GPv2Interaction.Data({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSignature("incrementCounter(uint256)", 1)
        });
        GPv2Interaction.Data[] memory interaction2 = new GPv2Interaction.Data[](1);
        interaction2[0] = GPv2Interaction.Data({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSignature("sendTokens(address,address,uint256)", sUSDe, COW_SETTLEMENT, amountOut)
        });
        GPv2Interaction.Data[] memory interaction3 = new GPv2Interaction.Data[](1);
        interaction3[0] = GPv2Interaction.Data({
            target: address(this),
            value: 0,
            callData: abi.encodeWithSignature("incrementCounter(uint256)", 2)
        });

        GPv2Interaction.Data[][3] memory interactions = [interaction1, interaction2, interaction3];

        vm.startPrank(solverAddress);
        {
            GPv2Settlement(payable(COW_SETTLEMENT)).settle(tokens, clearingPrices, trades, interactions);
        }
        vm.stopPrank();

        assertEq(counter, 3, "Wrong counter");
        assertEq(farm.liquidity(), 0);
        assertApproxEqAbs(farm.assets(), 1000e6, 0.01e6);
        assertApproxEqAbs(ERC20(sUSDe).balanceOf(address(farm)), amountOut, 1e18);
    }
}
