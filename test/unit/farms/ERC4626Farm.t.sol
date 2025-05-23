// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "@test/Fixture.t.sol";
import {ERC4626Farm} from "@integrations/farms/ERC4626Farm.sol";
import {ERC20, ERC4626, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract MockERC4626Vault is ERC4626 {
    uint256 public _maxDeposit = type(uint256).max;

    constructor(address _asset) ERC4626(IERC20(_asset)) ERC20("yield USDC", "yUSDC") {}

    function mockSetMaxDeposit(uint256 _value) external {
        _maxDeposit = _value;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return _maxDeposit;
    }
}

contract ERC4626FarmUnitTest is Fixture {
    MockERC4626Vault vault;
    ERC4626Farm farm;

    function test() public pure override {}

    function setUp() public override {
        super.setUp();

        vault = new MockERC4626Vault(address(usdc));
        farm = new ERC4626Farm(address(core), address(usdc), address(vault));
    }

    function testInitialState() public view {
        assertEq(farm.vault(), address(vault));
        assertEq(farm.assets(), 0);
        assertEq(farm.liquidity(), 0);
    }

    function testDeposit() public {
        usdc.mint(address(farm), 100e6);

        assertEq(farm.assets(), 0, "Error: assets is updated after mint");

        vm.prank(farmManagerAddress);
        farm.deposit();

        assertEq(farm.assets(), 100e6, "Error: Farm assets should not change after deposit");
        assertEq(farm.liquidity(), 100e6, "Error: liquidity should not change after deposit");
        assertEq(usdc.balanceOf(address(farm)), 0, "Error: usdc balance of farm should be 0 after deposit");
        assertEq(
            usdc.balanceOf(address(vault)), 100e6, "Error: usdc balance of vault should be increase after farm deposit"
        );
        assertEq(
            vault.balanceOf(address(farm)), 100e6, "Error: vault balance of farm should be increase after farm deposit"
        );
    }

    function testWithdraw() public {
        testDeposit();

        vm.prank(farmManagerAddress);
        farm.withdraw(70e6, alice);

        assertEq(farm.assets(), 30e6, "Error: Farm assets does not reflect the correct amount after withdraw");
        assertEq(
            usdc.balanceOf(address(farm)),
            0,
            "Error: usdc balance of farm should be 0 because farm has already deposited"
        );
        assertEq(
            usdc.balanceOf(address(vault)),
            30e6,
            "Error: usdc balance of vault does not reflect the correct amount after farm withdraw"
        );
        assertEq(
            vault.balanceOf(address(farm)),
            30e6,
            "Error: vault balance of farm does not reflect the correct amount after farm withdraw"
        );
        assertEq(usdc.balanceOf(alice), 70e6, "Error: alice should receive the correct amount after withdraw");
    }

    function testEarnYield() public {
        testDeposit();
        usdc.mint(address(vault), 30e6);
        assertApproxEqAbs(
            farm.assets(),
            130e6,
            1e6,
            "Error: Farm assets does not reflect the correct amount after yield deposited into farm"
        );
    }

    /// @notice verify that the asset mismatch reverts
    /// it can happen if the vault targeted by the farm does not have the same asset as the one of the farm
    function testAssetMisMatch() public {
        address dai = makeAddr("dai");
        MockERC4626Vault vaultDai = new MockERC4626Vault(dai);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Farm.AssetMismatch.selector, address(usdc), dai));
        new ERC4626Farm(address(core), address(usdc), address(vaultDai));
    }
}
