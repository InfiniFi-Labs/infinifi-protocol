// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Fixture} from "@test/Fixture.t.sol";
import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {MockFarm} from "@test/mock/MockFarm.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {console} from "forge-std/console.sol";

contract AllocationVotingUnitTest is Fixture {
    using EpochLib for uint256;

    // Helper to prepare 50-50 votes
    function _prepareVote(uint256 _balance)
        internal
        view
        returns (AllocationVoting.AllocationVote[] memory, AllocationVoting.AllocationVote[] memory)
    {
        uint96 weight = uint96(_balance / 2);

        AllocationVoting.AllocationVote[] memory liquidVotes = new AllocationVoting.AllocationVote[](2);
        AllocationVoting.AllocationVote[] memory illiquidVotes = new AllocationVoting.AllocationVote[](2);
        liquidVotes[0] = AllocationVoting.AllocationVote({farm: address(farm1), weight: weight});
        liquidVotes[1] = AllocationVoting.AllocationVote({farm: address(farm2), weight: weight});
        illiquidVotes[0] = AllocationVoting.AllocationVote({farm: address(illiquidFarm1), weight: weight});
        illiquidVotes[1] = AllocationVoting.AllocationVote({farm: address(illiquidFarm2), weight: weight});

        return (liquidVotes, illiquidVotes);
    }

    function testInitialState() public view {
        assertEq(allocationVoting.getVote(address(farm1)), 0, "Error: Initial vote for farm1 is not 0");
        assertEq(allocationVoting.getVote(address(farm2)), 0, "Error: Initial vote for farm2 is not 0");
        assertEq(allocationVoting.getVote(address(illiquidFarm1)), 0, "Error: Initial vote for illiquidFarm1 is not 0");
        assertEq(allocationVoting.getVote(address(illiquidFarm2)), 0, "Error: Initial vote for illiquidFarm2 is not 0");
    }

    function _initLocking(address _user, uint256 _amount) internal {
        vm.startPrank(_user);
        {
            // mint iUSD
            uint256 iusdBalanceBefore = iusd.balanceOf(_user);
            usdc.mint(_user, _amount);
            usdc.approve(address(gateway), _amount);
            gateway.mint(_user, _amount);
            vm.warp(block.timestamp + 12);
            uint256 iusdBalanceAfter = iusd.balanceOf(_user);
            uint256 iusdReceived = iusdBalanceAfter - iusdBalanceBefore;

            // lock for 4 epochs
            iusd.approve(address(gateway), iusdReceived);
            gateway.createPosition(iusdReceived, 4, _user);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + EpochLib.EPOCH);
    }

    function _initAliceLocking(uint256 amount) internal {
        _initLocking(alice, amount);
    }

    function _initBobLocking(uint256 amount) internal {
        _initLocking(bob, amount);
    }

    function testVote() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        (AllocationVoting.AllocationVote[] memory liquidVotes, AllocationVoting.AllocationVote[] memory illiquidVotes) =
            _prepareVote(aliceWeight);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.InvalidAsset.selector, address(0)));
        gateway.vote(address(0), 4, liquidVotes, illiquidVotes);

        // cast vote
        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        // alice cannot transfer her tokens
        address shareToken = lockingController.shareToken(4);
        vm.prank(alice);
        vm.expectRevert();
        MockERC20(shareToken).transfer(bob, 1);

        // vote is not applied immediately
        assertEq(allocationVoting.getVote(address(farm1)), 0, "Error: Vote for farm1 should not be applied immediately");
        assertEq(allocationVoting.getVote(address(farm2)), 0, "Error: Vote for farm2 should not be applied immediately");
        assertEq(
            allocationVoting.getVote(address(illiquidFarm1)),
            0,
            "Error: Vote for illiquidFarm1 should not be applied immediately"
        );
        assertEq(
            allocationVoting.getVote(address(illiquidFarm2)),
            0,
            "Error: Vote for illiquidFarm2 should not be applied immediately"
        );

        // on next epoch, vote is applied
        vm.warp(block.timestamp + EpochLib.EPOCH);
        assertEq(
            allocationVoting.getVote(address(farm1)),
            aliceWeight / 2,
            "Error: Vote for farm1 should be applied in the next epoch"
        );
        assertEq(
            allocationVoting.getVote(address(farm2)),
            aliceWeight / 2,
            "Error: Vote for farm2 should be applied in the next epoch"
        );
        assertEq(
            allocationVoting.getVote(address(illiquidFarm1)),
            aliceWeight / 2,
            "Error: Vote for illiquidFarm1 should be applied in the next epoch"
        );
        assertEq(
            allocationVoting.getVote(address(illiquidFarm2)),
            aliceWeight / 2,
            "Error: Vote for illiquidFarm2 should be applied in the next epoch"
        );

        // alice can transfer her tokens again
        vm.prank(alice);
        MockERC20(shareToken).transfer(bob, 1);

        (address[] memory liquidFarms, uint256[] memory liquidWeights,) =
            allocationVoting.getVoteWeights(FarmTypes.LIQUID);
        (address[] memory illiquidFarms, uint256[] memory illiquidWeights,) =
            allocationVoting.getVoteWeights(FarmTypes.MATURITY);

        (address[] memory liquidAssetFarms, uint256[] memory liquidAssetWeights,) =
            allocationVoting.getAssetVoteWeights(address(usdc), FarmTypes.LIQUID);
        (address[] memory illiquidAssetFarms, uint256[] memory illiquidAssetWeights,) =
            allocationVoting.getAssetVoteWeights(address(usdc), FarmTypes.MATURITY);

        for (uint256 i = 0; i < liquidAssetFarms.length; i++) {
            assertEq(liquidAssetFarms[i], liquidFarms[i], "Liquid farms must match liquid asset farms");
            assertEq(illiquidAssetFarms[i], illiquidFarms[i], "Illiquid farms must match illiquid asset farms");
            assertEq(
                liquidAssetWeights[i],
                liquidWeights[i],
                "All liquid weights should be the same as asset weights when there is a single asset"
            );
            assertEq(
                illiquidAssetWeights[0],
                illiquidWeights[0],
                "All illiquid weights should be the same as asset weights when there is a single asset"
            );
        }

        assertEq(liquidFarms[0], address(farm1), "Error: farm1 address is not set correctly in liquidFarms");
        assertEq(liquidFarms[1], address(farm2), "Error: farm2 address is not set correctly in liquidFarms");
        assertEq(
            illiquidFarms[0],
            address(illiquidFarm1),
            "Error: illiquidFarm1 address is not set correctly in illiquidFarms"
        );
        assertEq(
            illiquidFarms[1],
            address(illiquidFarm2),
            "Error: illiquidFarm2 address is not set correctly in illiquidFarms"
        );
        assertEq(liquidWeights[0], aliceWeight / 2, "Error: liquidWeights[0] should be aliceWeight / 2");
        assertEq(liquidWeights[1], aliceWeight / 2, "Error: liquidWeights[1] should be aliceWeight / 2");
        assertEq(illiquidWeights[0], aliceWeight / 2, "Error: illiquidWeights[0] should be aliceWeight / 2");
        assertEq(illiquidWeights[1], aliceWeight / 2, "Error: illiquidWeights[1] should be aliceWeight / 2");

        // on the epoch after, vote is discarded (have to vote every week)
        vm.warp(block.timestamp + EpochLib.EPOCH);
        assertEq(allocationVoting.getVote(address(farm1)), 0, "Error: Vote for farm1 should be discarded");
        assertEq(allocationVoting.getVote(address(farm2)), 0, "Error: Vote for farm2 should be discarded");
        assertEq(
            allocationVoting.getVote(address(illiquidFarm1)), 0, "Error: Vote for illiquidFarm1 should be discarded"
        );
        assertEq(
            allocationVoting.getVote(address(illiquidFarm2)), 0, "Error: Vote for illiquidFarm2 should be discarded"
        );
    }

    function testMaturityChecks() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        uint256 farmMaturity = block.timestamp + EpochLib.EPOCH * 6;
        illiquidFarm1.mockSetMaturity(farmMaturity);

        // alice cannot cast a vote for illiquidFarm1 because maturity is
        // too far into the future
        (AllocationVoting.AllocationVote[] memory liquidVotes, AllocationVoting.AllocationVote[] memory illiquidVotes) =
            _prepareVote(aliceWeight);
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AllocationVoting.InvalidTargetBucket.selector,
                address(illiquidFarm1),
                farmMaturity,
                (block.timestamp.epoch() + 4).epochToTimestamp()
            )
        );
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testVoteWithUnknownFarm() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        AllocationVoting.AllocationVote[] memory liquidVotes = new AllocationVoting.AllocationVote[](1);
        liquidVotes[0] = AllocationVoting.AllocationVote({farm: address(0x123), weight: uint96(aliceWeight)});
        AllocationVoting.AllocationVote[] memory illiquidVotes = new AllocationVoting.AllocationVote[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.UnknownFarm.selector, address(0x123), true));
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testVoteWithNoVotingPower() public {
        // Try to vote without having any locked tokens
        AllocationVoting.AllocationVote[] memory liquidVotes = new AllocationVoting.AllocationVote[](1);
        liquidVotes[0] = AllocationVoting.AllocationVote({farm: address(farm1), weight: 100});
        AllocationVoting.AllocationVote[] memory illiquidVotes = new AllocationVoting.AllocationVote[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.NoVotingPower.selector, alice, 4));
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testVoteWithInvalidWeights() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        // Create votes with total weight more than user's voting power
        AllocationVoting.AllocationVote[] memory liquidVotes = new AllocationVoting.AllocationVote[](2);
        liquidVotes[0] = AllocationVoting.AllocationVote({farm: address(farm1), weight: uint96(aliceWeight)});
        liquidVotes[1] = AllocationVoting.AllocationVote({farm: address(farm2), weight: uint96(aliceWeight)});
        AllocationVoting.AllocationVote[] memory illiquidVotes = new AllocationVoting.AllocationVote[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.InvalidWeights.selector, aliceWeight, aliceWeight * 2));
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testVoteWithMultipleAssets() public {
        // Setup a second asset and its farms
        MockERC20 secondAsset = new MockERC20("Mock Asset", "MA");
        MockFarm secondFarm1 = new MockFarm(address(core), address(secondAsset));
        MockFarm secondFarm2 = new MockFarm(address(core), address(secondAsset));

        address[] memory farms = new address[](2);
        farms[0] = address(secondFarm1);
        farms[1] = address(secondFarm2);

        vm.startPrank(governorAddress);
        farmRegistry.enableAsset(address(secondAsset));
        farmRegistry.addFarms(FarmTypes.LIQUID, farms);
        vm.stopPrank();

        _initAliceLocking(1000e6);
        _initBobLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);
        uint96 weight = uint96(aliceWeight / 2);

        // Vote for first asset
        AllocationVoting.AllocationVote[] memory firstAssetVotes = new AllocationVoting.AllocationVote[](2);
        firstAssetVotes[0] = AllocationVoting.AllocationVote({farm: address(farm1), weight: weight});
        firstAssetVotes[1] = AllocationVoting.AllocationVote({farm: address(farm2), weight: weight});

        vm.prank(alice);
        gateway.vote(address(usdc), 4, firstAssetVotes, new AllocationVoting.AllocationVote[](0));

        // Vote for second asset
        AllocationVoting.AllocationVote[] memory secondAssetVotes = new AllocationVoting.AllocationVote[](2);
        secondAssetVotes[0] = AllocationVoting.AllocationVote({farm: address(secondFarm1), weight: weight});
        secondAssetVotes[1] = AllocationVoting.AllocationVote({farm: address(secondFarm2), weight: weight});

        vm.prank(bob);
        gateway.vote(address(secondAsset), 4, secondAssetVotes, new AllocationVoting.AllocationVote[](0));

        // Verify votes are tracked separately per asset
        vm.warp(block.timestamp + EpochLib.EPOCH);

        (address[] memory firstAssetFarms, uint256[] memory firstAssetWeights,) =
            allocationVoting.getAssetVoteWeights(address(usdc), FarmTypes.LIQUID);
        (address[] memory secondAssetFarms, uint256[] memory secondAssetWeights,) =
            allocationVoting.getAssetVoteWeights(address(secondAsset), FarmTypes.LIQUID);

        assertEq(firstAssetFarms[0], address(farm1));
        assertEq(firstAssetFarms[1], address(farm2));
        assertEq(firstAssetWeights[0], weight);
        assertEq(firstAssetWeights[1], weight);

        assertEq(secondAssetFarms[0], address(secondFarm1));
        assertEq(secondAssetFarms[1], address(secondFarm2));
        assertEq(secondAssetWeights[0], weight);
        assertEq(secondAssetWeights[1], weight);
    }

    function testVoteWithZeroWeights() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        // Create votes with zero weights
        AllocationVoting.AllocationVote[] memory liquidVotes = new AllocationVoting.AllocationVote[](2);
        liquidVotes[0] = AllocationVoting.AllocationVote({farm: address(farm1), weight: 0});
        liquidVotes[1] = AllocationVoting.AllocationVote({farm: address(farm2), weight: uint96(aliceWeight)});
        AllocationVoting.AllocationVote[] memory illiquidVotes = new AllocationVoting.AllocationVote[](0);

        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        vm.warp(block.timestamp + EpochLib.EPOCH);
        assertEq(allocationVoting.getVote(address(farm1)), 0, "Vote weight should be zero for farm1");
        assertEq(allocationVoting.getVote(address(farm2)), aliceWeight, "Vote weight should be full for farm2");
    }

    function testVoteWhenPaused() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        (AllocationVoting.AllocationVote[] memory liquidVotes, AllocationVoting.AllocationVote[] memory illiquidVotes) =
            _prepareVote(aliceWeight);

        // Pause the contract
        vm.prank(guardianAddress);
        allocationVoting.pause();

        // Try to vote while paused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        // Unpause and verify voting works
        vm.prank(guardianAddress);
        allocationVoting.unpause();

        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }
}
