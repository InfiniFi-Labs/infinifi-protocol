// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "@forge-std/console.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {MockAToken} from "@test/mock/aave/MockAToken.sol";
import {AaveV3Farm} from "@integrations/farms/AaveV3Farm.sol";
import {MockAaveV3Pool} from "@test/mock/aave/MockAaveV3Pool.sol";
import {MockAaveDataProvider} from "@test/mock/aave/MockAaveDataProvider.sol";
import {MockAaveAddressProvider} from "@test/mock/aave/MockAaveAddressProvider.sol";

contract AaveV3FarmUnitTest is Fixture {
    MockAaveV3Pool aavePool;
    MockAToken aToken;
    MockAaveDataProvider aaveDataProvider;
    MockAaveAddressProvider aaveAddressProvider;
    AaveV3Farm farm;

    // Aave returns the borrow cap and supply cap for the asset with 0 decimals
    // example for 1000 USDC it returns 1000 !
    // here we set each cap to 1B
    uint256 public constant _AAVE_BORROW_CAP = 1_000_000_000;
    uint256 public constant _AAVE_SUPPLY_CAP = 1_000_000_000;

    function setUp() public override {
        super.setUp();

        aToken = new MockAToken("Aave USDC", "aUSDC");
        aToken.setDecimals(usdc.decimals());
        aavePool = new MockAaveV3Pool(address(usdc), address(aToken));
        aaveDataProvider = new MockAaveDataProvider(_AAVE_BORROW_CAP, _AAVE_SUPPLY_CAP);
        aaveAddressProvider = new MockAaveAddressProvider(address(aaveDataProvider));
        aavePool.setAddressProvider(address(aaveAddressProvider));
        farm = new AaveV3Farm(address(aToken), address(aavePool), address(core), address(usdc));
    }

    function scenario_Deposit500USDCToAave() public {
        usdc.mint(address(farm), 500e6);
        vm.prank(farmManagerAddress);
        farm.deposit();
    }

    function _externalDepositToAave(uint256 _amount) public {
        // if alice supply to the aave pool, it will add more USDC to the withdrawn by the farm
        usdc.mint(address(alice), _amount);
        vm.startPrank(alice);
        usdc.approve(address(aavePool), _amount);
        aavePool.supply(address(usdc), _amount, address(alice), 0);
        vm.stopPrank();
    }

    function testInitialState() public view {
        assertEq(farm.aToken(), address(aToken));
        assertEq(farm.lendingPool(), address(aavePool));
        assertEq(farm.assets(), 0);
        assertEq(farm.liquidity(), 0);
        assertEq(aToken.decimals(), usdc.decimals());
    }

    function testAirdropTokens() public {
        usdc.mint(address(farm), 100e6);
        assertEq(farm.assets(), 0, "Assets should be 0");
        assertEq(farm.liquidity(), 0, "Liquidity should be 0");
    }

    function testDeposit() public {
        scenario_Deposit500USDCToAave();
        assertEq(farm.assets(), 500e6, "Assets should be 500e6");
        assertEq(farm.liquidity(), 500e6, "Liquidity should be 500e6");
        assertEq(usdc.balanceOf(address(farm)), 0, "USDC balance should be 0");
    }

    function testNoLiquidityAvailable() public {
        // deposit 500 USDC to the aave pool
        scenario_Deposit500USDCToAave();
        // someone will borrow 500 USDC from the aave pool
        aavePool.fakeBorrow(500e6);
        // assets should still be 500e6
        assertEq(farm.assets(), 500e6, "Assets should be 500e6");
        // now the liquidity should be 0 because 100% of the assets are borrowed (no liquidity available on aave)
        assertEq(farm.liquidity(), 0, "Liquidity should be 0");
    }

    function testDepositAndAccrueInterest() public {
        scenario_Deposit500USDCToAave();
        // update the multiplier to simulate the accrual of interest
        // here +10% interest
        MockAToken(aToken).setMultiplier(1.1e18);
        assertEq(farm.assets(), 550e6, "Assets should be 550e6");
        // but the liquidity should not change as no USDC were added to the aave pool
        assertEq(farm.liquidity(), 500e6, "Liquidity should be 500e6");

        // here we simulate an external deposit to the aave pool for 1000 USDC
        _externalDepositToAave(1000e6);

        assertEq(farm.assets(), 550e6, "Assets should be 550e6");
        assertEq(farm.liquidity(), 550e6, "Liquidity should be 550e6");
    }

    function testWithdraw() public {
        scenario_Deposit500USDCToAave();
        vm.prank(farmManagerAddress);
        farm.withdraw(500e6, address(farm));
        assertEq(usdc.balanceOf(address(farm)), 500e6, "USDC balance should be 500e6");
    }
}
