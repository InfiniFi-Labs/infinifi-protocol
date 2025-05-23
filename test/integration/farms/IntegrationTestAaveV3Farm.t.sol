// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {console} from "@forge-std/console.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {AaveV3Farm} from "@integrations/farms/AaveV3Farm.sol";

contract IntegrationTestAaveV3Farm is Fixture {
    address public aaveV3LendingPool = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public aUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    AaveV3Farm public aaveV3Farm;

    // at block 21337193, (, uint256 supplyCap) = IAaveDataProvider(dataProvider).getReserveCaps(assetToken);
    // the supply cap is 3B
    uint256 public aaveV3USDCSupplyCap = 3_000_000_000e6;
    // at block 21337193, the reserveData.totalAToken is 1971459791900656 (1.97B)
    uint256 public aaveV3USDCTotalAToken = 1_971_459_791_900_656;
    // at block 21337193, the reserveData.accruedToTreasuryScaled is 21350751486 (21k)
    uint256 public aaveV3USDCTreasuryAccrued = 21_350_751_486;

    function setUp() public override {
        vm.createSelectFork("mainnet", 21337193);

        super.setUp();

        // roll after the super.setUp() to ensure running this test at the specific block
        vm.roll(21337193);
        vm.warp(1733412513);

        // deploy farm
        aaveV3Farm = new AaveV3Farm(aUSDC, aaveV3LendingPool, address(core), USDC);
        // deal 1k usdc to the farm
        dealToken(USDC, address(aaveV3Farm), 1_000e6);
    }

    function testSetup() public view {
        // check constructor sets the correct values
        assertEq(aaveV3Farm.aToken(), aUSDC);
        assertEq(aaveV3Farm.lendingPool(), aaveV3LendingPool);

        // assert there are liquidity available on aave lending pool for aUSDC
        assertGt(ERC20(USDC).balanceOf(aUSDC), 0, "assert there are liquidity available on aave lending pool for aUSDC");

        assertEq(aaveV3Farm.assets(), 0);
        assertEq(aaveV3Farm.cap(), type(uint256).max);
    }

    function testDeposit() public {
        vm.prank(farmManagerAddress);
        aaveV3Farm.deposit();

        assertEq(aaveV3Farm.assets(), 1_000e6, "Assets should be 1000e6");

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1000 * 12);

        // assert the assets have increased due to interest
        assertGt(aaveV3Farm.assets(), 1_000e6, "Assets should have increased due to interest");
    }

    function testWithdraw() public {
        vm.startPrank(farmManagerAddress);
        aaveV3Farm.deposit();

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1000 * 12);

        uint256 liquidity = aaveV3Farm.liquidity();
        assertGt(liquidity, 0);

        aaveV3Farm.withdraw(liquidity, address(this));
        vm.stopPrank();

        assertEq(aaveV3Farm.assets(), 0);
        assertEq(ERC20(USDC).balanceOf(address(this)), liquidity);
    }

    function testWithdrawMax() public {
        vm.startPrank(farmManagerAddress);
        aaveV3Farm.deposit();

        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 1000 * 12);

        uint256 liquidity = aaveV3Farm.liquidity();
        assertGt(liquidity, 0);

        aaveV3Farm.withdraw(type(uint256).max, address(this));
        vm.stopPrank();

        assertEq(aaveV3Farm.assets(), 0);
        assertEq(ERC20(USDC).balanceOf(address(this)), liquidity);
    }
}
