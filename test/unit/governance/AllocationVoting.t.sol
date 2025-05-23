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

    AllocationVoting.AllocationVote[] liquidVotes;
    AllocationVoting.AllocationVote[] illiquidVotes;

    function _createVote(address _farm, uint96 _weight)
        internal
        pure
        returns (AllocationVoting.AllocationVote memory)
    {
        return AllocationVoting.AllocationVote({farm: _farm, weight: _weight});
    }

    function _assertVoteEq(MockFarm _farm, uint256 _weight, string memory _message) internal view {
        assertEq(allocationVoting.getVote(address(_farm)), _weight, _message);
    }

    function testInitialState() public view {
        _assertVoteEq(farm1, 0, "Initial vote for farm1 is not 0");
        _assertVoteEq(farm2, 0, "Initial vote for farm2 is not 0");
        _assertVoteEq(illiquidFarm1, 0, "Initial vote for illiquidFarm1 is not 0");
        _assertVoteEq(illiquidFarm2, 0, "Initial vote for illiquidFarm2 is not 0");
    }

    function _initLocking(address _user, uint256 _amount, uint32 _unwindingEpochs) internal {
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
            gateway.createPosition(iusdReceived, _unwindingEpochs, _user);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + EpochLib.EPOCH);
    }

    function _initAliceLocking(uint256 amount) internal {
        _initLocking(alice, amount, 4);
    }

    function _initBobLocking(uint256 amount) internal {
        _initLocking(bob, amount, 4);
    }

    function testVote() public {
        _initAliceLocking(1000e6);

        liquidVotes.push(_createVote(address(farm1), 0.5e18));
        liquidVotes.push(_createVote(address(farm2), 0.5e18));
        illiquidVotes.push(_createVote(address(illiquidFarm1), 0.5e18));
        illiquidVotes.push(_createVote(address(illiquidFarm2), 0.5e18));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.InvalidAsset.selector, address(0)));
        gateway.vote(address(0), 4, liquidVotes, illiquidVotes);

        // cast vote
        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        uint256 aliceWeight = lockingController.rewardWeight(alice);

        // alice cannot transfer her tokens
        address shareToken = lockingController.shareToken(4);
        vm.prank(alice);
        vm.expectRevert();
        MockERC20(shareToken).transfer(bob, 1);

        // vote is not applied immediately
        _assertVoteEq(farm1, 0, "Vote for farm1 should not be applied immediately");
        _assertVoteEq(farm2, 0, "Vote for farm2 should not be applied immediately");
        _assertVoteEq(illiquidFarm1, 0, "Vote for illiquidFarm1 should not be applied immediately");
        _assertVoteEq(illiquidFarm2, 0, "Vote for illiquidFarm2 should not be applied immediately");

        // on next epoch, vote is applied
        advanceEpoch(1);

        _assertVoteEq(farm1, aliceWeight / 2, "Vote for farm1 should be applied in the next epoch");
        _assertVoteEq(farm2, aliceWeight / 2, "Vote for farm2 should be applied in the next epoch");
        _assertVoteEq(illiquidFarm1, aliceWeight / 2, "Vote for illiquidFarm1 should be applied in the next epoch");
        _assertVoteEq(illiquidFarm2, aliceWeight / 2, "Vote for illiquidFarm2 should be applied in the next epoch");

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

        assertEq(liquidFarms[0], address(farm1), "farm1 address is not set correctly in liquidFarms");
        assertEq(liquidFarms[1], address(farm2), "farm2 address is not set correctly in liquidFarms");
        assertEq(
            illiquidFarms[0], address(illiquidFarm1), "illiquidFarm1 address is not set correctly in illiquidFarms"
        );
        assertEq(
            illiquidFarms[1], address(illiquidFarm2), "illiquidFarm2 address is not set correctly in illiquidFarms"
        );
        assertEq(liquidWeights[0], aliceWeight / 2, "liquidWeights[0] should be aliceWeight / 2");
        assertEq(liquidWeights[1], aliceWeight / 2, "liquidWeights[1] should be aliceWeight / 2");
        assertEq(illiquidWeights[0], aliceWeight / 2, "illiquidWeights[0] should be aliceWeight / 2");
        assertEq(illiquidWeights[1], aliceWeight / 2, "illiquidWeights[1] should be aliceWeight / 2");

        // on the epoch after, vote is discarded (have to vote every week)
        advanceEpoch(1);
        _assertVoteEq(farm1, 0, "Vote for farm1 should be discarded");
        _assertVoteEq(farm2, 0, "Vote for farm2 should be discarded");
        _assertVoteEq(illiquidFarm1, 0, "Vote for illiquidFarm1 should be discarded");
        _assertVoteEq(illiquidFarm2, 0, "Vote for illiquidFarm2 should be discarded");
    }

    function testMultiVote() public {
        // setup alice with 2 positions, one locked for 4 epochs, the other locked for 8 epochs
        _initLocking(alice, 1000e6, 4);
        _initLocking(alice, 1000e6, 8);

        uint256 aliceWeight4 = lockingController.rewardWeightForUnwindingEpochs(alice, 4);
        uint256 aliceWeight8 = lockingController.rewardWeightForUnwindingEpochs(alice, 8);

        AllocationVoting.AllocationVote[][] memory batchLiquidVotes = new AllocationVoting.AllocationVote[][](2);
        AllocationVoting.AllocationVote[][] memory batchIlliquidVotes = new AllocationVoting.AllocationVote[][](2);
        liquidVotes.push(_createVote(address(farm1), 0.5e18));
        liquidVotes.push(_createVote(address(farm2), 0.5e18));
        batchLiquidVotes[0] = liquidVotes;
        batchLiquidVotes[1] = liquidVotes;

        illiquidVotes.push(_createVote(address(illiquidFarm1), 0.5e18));
        illiquidVotes.push(_createVote(address(illiquidFarm2), 0.5e18));
        batchIlliquidVotes[0] = illiquidVotes;
        batchIlliquidVotes[1] = illiquidVotes;

        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(usdc);
        uint32[] memory unwindingEpochs = new uint32[](2);
        unwindingEpochs[0] = 4;
        unwindingEpochs[1] = 8;

        vm.prank(alice);
        gateway.multiVote(assets, unwindingEpochs, batchLiquidVotes, batchIlliquidVotes);

        // check votes
        advanceEpoch(1);

        _assertVoteEq(farm1, aliceWeight4 / 2 + aliceWeight8 / 2, "Vote for farm1 is incorrect");
        _assertVoteEq(farm2, aliceWeight4 / 2 + aliceWeight8 / 2, "Vote for farm2 is incorrect");
        _assertVoteEq(illiquidFarm1, aliceWeight4 / 2 + aliceWeight8 / 2, "Vote for illiquidFarm1 is incorrect");
        _assertVoteEq(illiquidFarm2, aliceWeight4 / 2 + aliceWeight8 / 2, "Vote for illiquidFarm2 is incorrect");
    }

    function testMaturityChecks() public {
        _initAliceLocking(1000e6);
        uint256 farmMaturity = block.timestamp + EpochLib.EPOCH * 5;
        illiquidFarm1.mockSetMaturity(farmMaturity);

        // alice cannot cast a vote for illiquidFarm1 because maturity is
        // too far into the future
        liquidVotes.push(_createVote(address(farm1), 0.5e18));
        liquidVotes.push(_createVote(address(farm2), 0.5e18));
        illiquidVotes.push(_createVote(address(illiquidFarm1), 0.5e18));
        illiquidVotes.push(_createVote(address(illiquidFarm2), 0.5e18));

        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                AllocationVoting.InvalidTargetBucket.selector,
                address(illiquidFarm1),
                farmMaturity,
                (block.timestamp.nextEpoch() + 4).epochToTimestamp()
            )
        );
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        // alice can vote if the maturity is exactly equal to her number of unwindign epochs
        illiquidFarm1.mockSetMaturity(block.timestamp + EpochLib.EPOCH * 4);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testMaturityEdgeCase() public {
        _initAliceLocking(1000e6);
        uint256 farmMaturity = (block.timestamp.nextEpoch() + 4).epochToTimestamp();
        illiquidFarm1.mockSetMaturity(farmMaturity);

        illiquidVotes.push(_createVote(address(illiquidFarm1), 0.5e18));
        illiquidVotes.push(_createVote(address(illiquidFarm2), 0.5e18));

        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        uint256 actualTimeGap = farmMaturity.epoch() - block.timestamp.nextEpoch();

        assertEq(actualTimeGap, 4, "User should be able to vote for 4 week assets");
    }

    function testVoteWithUnknownFarm() public {
        _initAliceLocking(1000e6);

        liquidVotes.push(_createVote(address(0x123), 1e18));
        illiquidVotes.push(_createVote(address(0x123), 1e18));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.UnknownFarm.selector, address(0x123), true));
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testVoteWithNoVotingPower() public {
        // Try to vote without having any locked tokens
        liquidVotes.push(_createVote(address(farm1), 1e18));
        illiquidVotes.push(_createVote(address(illiquidFarm1), 1e18));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.NoVotingPower.selector, alice, 4));
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);
    }

    function testVoteWithInvalidWeights() public {
        _initAliceLocking(1000e6);

        // Create votes with total weight more than user's voting power
        liquidVotes.push(_createVote(address(farm1), 0.6e18));
        liquidVotes.push(_createVote(address(farm2), 0.5e18));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AllocationVoting.InvalidWeights.selector, 1e18, 1.1e18));
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

        vm.prank(governorAddress);
        farmRegistry.enableAsset(address(secondAsset));
        vm.prank(parametersAddress);
        farmRegistry.addFarms(FarmTypes.LIQUID, farms);

        _initAliceLocking(1000e6);
        _initBobLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);
        uint96 weight = uint96(aliceWeight / 2);

        // Vote for first asset
        liquidVotes.push(_createVote(address(farm1), 0.5e18));
        liquidVotes.push(_createVote(address(farm2), 0.5e18));

        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, new AllocationVoting.AllocationVote[](0));

        delete liquidVotes;

        // Vote for second asset
        liquidVotes.push(_createVote(address(secondFarm1), 0.5e18));
        liquidVotes.push(_createVote(address(secondFarm2), 0.5e18));

        vm.prank(bob);
        gateway.vote(address(secondAsset), 4, liquidVotes, new AllocationVoting.AllocationVote[](0));

        // Verify votes are tracked separately per asset
        advanceEpoch(1);

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
        liquidVotes.push(_createVote(address(farm1), 0));
        liquidVotes.push(_createVote(address(farm2), 1e18));

        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        advanceEpoch(1);
        _assertVoteEq(farm1, 0, "Vote weight should be zero for farm1");
        _assertVoteEq(farm2, aliceWeight, "Vote weight should be full for farm2");
    }

    function testVoteWhenPaused() public {
        _initAliceLocking(1000e6);

        liquidVotes.push(_createVote(address(farm1), 0.5e18));
        liquidVotes.push(_createVote(address(farm2), 0.5e18));

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

    // validate / test the fix of Spearbit audit 2025-03 issue #37
    // the votes could be carried over multiple epochs if there was no vote for a given
    // farm and then a user voted for the farm.
    // see commit 53db79cf90b01eac2f785fe6f17d226bffe0976d
    function testAccumulateVote37() public {
        _initAliceLocking(1000e6);
        uint256 aliceWeight = lockingController.rewardWeight(alice);

        liquidVotes.push(_createVote(address(farm1), 1e18));
        illiquidVotes.push(_createVote(address(illiquidFarm1), 1e18));

        // cast vote
        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        // Votes should not apply yet
        _assertVoteEq(farm1, 0, "Vote for farm1 should not apply yet");
        _assertVoteEq(illiquidFarm1, 0, "Vote for illiquidFarm1 should not apply yet");

        advanceEpoch(1);

        // Vote should apply now
        _assertVoteEq(farm1, aliceWeight, "Vote for farm1 should apply");
        _assertVoteEq(illiquidFarm1, aliceWeight, "Vote for illiquidFarm1 should apply");

        // Move past lockup
        advanceEpoch(4);

        // Votes should be discarded
        _assertVoteEq(farm1, 0, "Vote for farm1 should be discarded (1)");
        _assertVoteEq(illiquidFarm1, 0, "Vote for illiquidFarm1 should be discarded (1)");

        // Vote again
        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        // Votes should still be discarded on the epoch of the vote
        _assertVoteEq(farm1, 0, "Vote for farm1 should be discarded (2)");
        _assertVoteEq(illiquidFarm1, 0, "Vote for illiquidFarm1 should be discarded (2)");

        advanceEpoch(1);

        // Vote should apply now

        _assertVoteEq(farm1, aliceWeight, "Vote for farm1 should apply");
        _assertVoteEq(illiquidFarm1, aliceWeight, "Vote for illiquidFarm1 should apply");

        advanceEpoch(1);

        // Votes should be discarded
        _assertVoteEq(farm1, 0, "Vote for farm1 should be discarded (3)");
        _assertVoteEq(illiquidFarm1, 0, "Vote for illiquidFarm1 should be discarded (3)");
    }

    function testVoteFuzz(uint256 _percentage1, uint256 _percentage2, uint256 _assetAmount) public {
        _assetAmount = bound(_assetAmount, 1e6, 10000000e6);
        _percentage1 = bound(_percentage1, 0, 1e18);
        _percentage2 = bound(_percentage2, 0, 1e18 - _percentage1);
        uint256 _percentage3 = 1e18 - _percentage1 - _percentage2;

        _initAliceLocking(_assetAmount);

        uint256 aliceWeight = lockingController.rewardWeight(alice);

        liquidVotes.push(_createVote(address(farm1), uint96(_percentage1)));
        liquidVotes.push(_createVote(address(farm2), uint96(_percentage2)));
        liquidVotes.push(_createVote(address(farm2), uint96(_percentage3)));

        vm.prank(alice);
        gateway.vote(address(usdc), 4, liquidVotes, illiquidVotes);

        advanceEpoch(1);

        uint256 farm1AllocatedVote = allocationVoting.getVote(address(farm1));
        uint256 farm2AllocatedVote = allocationVoting.getVote(address(farm2));

        uint256 totalAllocatedVote = farm1AllocatedVote + farm2AllocatedVote;

        // allow for some rounding error up to 2 wei
        assertApproxEqAbs(
            totalAllocatedVote, aliceWeight, 2, "Total allocated vote should be almost equal to committed voting power"
        );
    }
}
