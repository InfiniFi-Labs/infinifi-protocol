// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {Fixture} from "@test/Fixture.t.sol";
import {ERC4626Farm} from "@integrations/farms/ERC4626Farm.sol";

contract IntegrationTestERC4626Farm is Fixture {
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public morphoMEVCapitalUsualUsdcVault = 0xd63070114470f685b75B74D60EEc7c1113d33a3D;
    address public eulerPrimesUSDC2 = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;
    address public fluidFUSDC = 0x9Fb7b4477576Fe5B32be4C1843aFB1e55F251B33;
    address public gearboxDUSDCV3 = 0xda00000035fef4082F78dEF6A8903bee419FbF8E;

    ERC4626Farm public farmA;
    ERC4626Farm public farmB;
    ERC4626Farm public farmC;
    ERC4626Farm public farmD;

    function setUp() public override {
        // this test needs a specific fork network & block
        vm.createSelectFork("mainnet", 22325494);

        super.setUp();

        vm.warp(1745336354);
        vm.roll(22325494);

        // deploy
        farmA = new ERC4626Farm(address(core), USDC, morphoMEVCapitalUsualUsdcVault);
        farmB = new ERC4626Farm(address(core), USDC, eulerPrimesUSDC2);
        farmC = new ERC4626Farm(address(core), USDC, fluidFUSDC);
        farmD = new ERC4626Farm(address(core), USDC, gearboxDUSDCV3);
    }

    function testSetup() public view {
        assertEq(farmA.assetToken(), USDC);
        assertEq(farmA.vault(), morphoMEVCapitalUsualUsdcVault);
        assertEq(farmA.liquidity(), 0);
        assertEq(farmA.assets(), 0);

        assertEq(farmB.assetToken(), USDC);
        assertEq(farmB.vault(), eulerPrimesUSDC2);
        assertEq(farmB.liquidity(), 0);
        assertEq(farmB.assets(), 0);

        assertEq(farmC.assetToken(), USDC);
        assertEq(farmC.vault(), fluidFUSDC);
        assertEq(farmC.liquidity(), 0);
        assertEq(farmC.assets(), 0);

        assertEq(farmD.assetToken(), USDC);
        assertEq(farmD.vault(), gearboxDUSDCV3);
        assertEq(farmD.liquidity(), 0);
        assertEq(farmD.assets(), 0);
    }

    function testFarmA() public {
        _testFarm(farmA);
    }

    function testFarmB() public {
        _testFarm(farmB);
    }

    function testFarmC() public {
        _testFarm(farmC);
    }

    function testFarmD() public {
        _testFarm(farmD);
    }

    function _testFarm(ERC4626Farm farm) internal {
        dealToken(USDC, address(farm), 50_000e6);
        vm.prank(farmManagerAddress);
        farm.deposit();

        assertApproxEqAbs(farm.liquidity(), 50_000e6, 1e6);
        assertApproxEqAbs(farm.assets(), 50_000e6, 1e6);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        // should have earned at least 1 USDC in 24 hours
        assertGt(farm.assets(), 50_000e6 + 1e6);

        vm.prank(farmManagerAddress);
        farm.withdraw(50_000e6, address(this));

        assertEq(ERC20(USDC).balanceOf(address(this)), 50_000e6);
        assertLt(farm.assets(), 50e6); // less than 50 USDC left in the farm
    }
}
