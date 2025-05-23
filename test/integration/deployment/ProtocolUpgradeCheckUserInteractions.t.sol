pragma solidity 0.8.28;

import "@test/integration/deployment/ProtocolUpgradeFixture.sol";

contract ProtocolUpgradeCheckUserInteractions is ProtocolUpgradeFixture {
    using AddressStoreLib for Vm;

    address public alice = makeAddr("ALICE");

    function testAliceMint() public {
        deal(address(usdc), address(alice), 100e6);
        vm.startPrank(alice);
        {
            usdc.approve(address(gateway), 100e6);
            gateway.mint(alice, 100e6);
        }
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(iusd.balanceOf(alice), 100e18);
    }

    function testAliceRedeem() public {
        testAliceMint();

        vm.startPrank(alice);
        {
            iusd.approve(address(gateway), 100e18);
            gateway.redeem(alice, 100e18, 0);
        }
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(iusd.balanceOf(alice), 0);
    }

    function testAliceStake() public returns (uint256) {
        testAliceMint();

        vm.startPrank(alice);
        iusd.approve(address(siusd), 100e18);
        uint256 siusdBalance = siusd.deposit(100e18, alice);
        vm.stopPrank();

        assertEq(iusd.balanceOf(alice), 0);
        assertEq(siusd.balanceOf(alice), siusdBalance);

        return siusdBalance;
    }

    function testAliceUnstake() public {
        uint256 siusdBalance = testAliceStake();

        vm.prank(alice);
        siusd.redeem(siusdBalance, alice, alice);

        assertApproxEqAbs(iusd.balanceOf(alice), 100e18, 2);
        assertEq(siusd.balanceOf(alice), 0);
    }
}
