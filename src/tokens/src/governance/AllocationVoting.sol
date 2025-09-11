// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {EpochLib} from "@libraries/EpochLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {LockingController} from "@locking/LockingController.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";

/// @notice Allocation voting contract
/// In this contract, locked users can vote for the farms where they want the protocol to allocate
/// their assets. Liquid farm & Illiquid farm votes are treated separately: liquid votes are used
/// to rebalance capital to the desired allocation (vote result) at every epoch, while illiquid votes
/// are only deciding where funds are allocated on a given week (in an additive manner, there is no
/// rebalancing between farms on the illiquid side).
/// Votes on a given epoch are only applying on the next epoch, leaving users with a full epoch
/// to cast their votes. Votes should be performed every week, or they will be considered outdated.
/// This means that a farm with 0 votes on a given epoch will not persist its weight on the next
/// epoch, its weight will become 0 on the next epoch.
contract AllocationVoting is CoreControlled {
    using EpochLib for uint256;
    using FixedPointMathLib for uint256;

    error InvalidAsset(address _asset);
    error AlreadyVoted(address _user, uint32 _unwindingEpochs);
    error NoVotingPower(address _user, uint32 _unwindingEpochs);
    error UnknownFarm(address farm, bool liquid);
    error InvalidWeights(uint256 _expectedPower, uint256 _actualPower);
    error InvalidTargetBucket(address _farm, uint256 _maturity, uint256 _userUnbondingTimestamp);

    event FarmVoteRegistered(
        uint256 indexed timestamp,
        uint256 indexed epoch,
        address indexed user,
        uint32 unwindingEpochs,
        AllocationVote[] liquidVotes,
        AllocationVote[] illiquidVotes,
        uint256 userWeight
    );

    struct AllocationVote {
        address farm;
        uint96 weight;
    }

    struct FarmWeightData {
        // epoch of the last vote
        uint32 epoch;
        // weight returned if the current epoch is exactly equal to `epoch`
        uint112 currentWeight;
        // weight updated on votes, committed to the `currentWeight` when a vote is cast
        // on an epoch that is later than the stored epoch.
        uint112 nextWeight;
    }

    address public lockingController;
    address public farmRegistry;

    mapping(address farm => FarmWeightData) public farmWeightData;
    mapping(address user => mapping(uint32 unwindingEpochs => uint32 epoch)) public lastVoteEpoch;

    constructor(address _core, address _lockingController, address _farmRegistry) CoreControlled(_core) {
        lockingController = _lockingController;
        farmRegistry = _farmRegistry;
    }

    /// @notice Returns the weight of the farm for the given epoch
    /// @param _farm The address of the farm
    /// @return uint256 The weight of the farm for the given epoch
    function getVote(address _farm) external view returns (uint256) {
        return _getFarmWeight(farmWeightData[_farm], uint32(block.timestamp.epoch()));
    }

    /// @notice Returns the vote weights for the given farm type (liquid or illiquid)
    /// @param _farmType Determine for which farm type subset to return votes for
    /// @return address[] farms
    /// @return uint256[] farms percentage
    /// @return uint256 total power
    function getVoteWeights(uint256 _farmType) external view returns (address[] memory, uint256[] memory, uint256) {
        address[] memory farms = FarmRegistry(farmRegistry).getTypeFarms(_farmType);
        (uint256[] memory weights, uint256 totalPower) = _getVoteWeights(farms);
        return (farms, weights, totalPower);
    }

    function getAssetVoteWeights(address _asset, uint256 _farmType)
        external
        view
        returns (address[] memory, uint256[] memory, uint256)
    {
        address[] memory farms = FarmRegistry(farmRegistry).getAssetTypeFarms(_asset, _farmType);
        (uint256[] memory weights, uint256 totalPower) = _getVoteWeights(farms);
        return (farms, weights, totalPower);
    }

    /// @notice Casts a vote for the given farm
    /// @param _asset to which asset do these farms belong to
    /// @param _unwindingEpochs The number of epochs to unwind of the user
    /// @param _liquidVotes The liquid votes
    /// @param _illiquidVotes The illiquid votes
    function vote(
        address _user,
        address _asset,
        uint32 _unwindingEpochs,
        AllocationVote[] calldata _liquidVotes,
        AllocationVote[] calldata _illiquidVotes
    ) external whenNotPaused onlyCoreRole(CoreRoles.ENTRY_POINT) {
        require(FarmRegistry(farmRegistry).isAssetEnabled(_asset), InvalidAsset(_asset));

        uint32 epoch = uint32(block.timestamp.epoch());
        require(lastVoteEpoch[_user][_unwindingEpochs] < epoch, AlreadyVoted(_user, _unwindingEpochs));
        lastVoteEpoch[_user][_unwindingEpochs] = epoch;

        uint256 weight = LockingController(lockingController).rewardWeightForUnwindingEpochs(_user, _unwindingEpochs);
        require(weight > 0, NoVotingPower(_user, _unwindingEpochs));

        if (_illiquidVotes.length > 0) {
            _storeUserVotes(_asset, _unwindingEpochs, epoch, weight, _illiquidVotes, false);
        }
        if (_liquidVotes.length > 0) {
            _storeUserVotes(_asset, _unwindingEpochs, epoch, weight, _liquidVotes, true);
        }

        // restrict transfer until the next epoch after voting
        address shareToken = LockingController(lockingController).shareToken(_unwindingEpochs);
        LockedPositionToken(shareToken).restrictTransferUntilNextEpoch(_user);

        emit FarmVoteRegistered(block.timestamp, epoch, _user, _unwindingEpochs, _liquidVotes, _illiquidVotes, weight);
    }

    /// -----------------------------------------------------------------------------------------------
    /// Internal helpers
    /// -----------------------------------------------------------------------------------------------

    /// @notice Returns the weight of the farm for the given epoch
    /// @param _data The farm weight data
    /// @param _epoch The epoch of the vote
    /// @return uint256 The weight of the farm for the given epoch
    function _getFarmWeight(FarmWeightData memory _data, uint32 _epoch) internal pure returns (uint256) {
        // if last vote was in current epoch, return the currentWeight
        if (_data.epoch == _epoch) {
            return _data.currentWeight;
        }
        // if last vote was in previous epoch, return the nextWeight
        if (_data.epoch == _epoch - 1) {
            return _data.nextWeight;
        }
        // otherwise, return 0 (do not persist votes if they are older than 1 epoch ago)
        return 0;
    }

    /// @notice Stores the user's votes for the given farms
    /// @param _unwindingEpochs The number of epochs to unwind of the user
    /// @param _epoch The epoch of the vote
    /// @param _userWeight The weight of the user
    /// @param _votes The votes to store
    /// @param _liquid Whether the farms are liquid or illiquid
    function _storeUserVotes(
        address _asset,
        uint32 _unwindingEpochs,
        uint32 _epoch,
        uint256 _userWeight,
        AllocationVote[] calldata _votes,
        bool _liquid
    ) internal {
        uint256 weightAllocated = 0;

        for (uint256 i = 0; i < _votes.length; i++) {
            address farm = _votes[i].farm;
            if (_liquid) {
                _validateAssetAndType(_asset, farm, FarmTypes.LIQUID);
            } else {
                _validateAssetAndType(_asset, farm, FarmTypes.MATURITY);
                _validateFarmBucket(farm, _unwindingEpochs);
            }

            FarmWeightData memory data = farmWeightData[farm];
            if (data.epoch != _epoch) {
                // roll over pending weight votes that are in "nextWeight" into "currentWeight"
                // when a new epoch starts and a vote is cast
                if (data.epoch == _epoch - 1) {
                    data = FarmWeightData({epoch: _epoch, currentWeight: data.nextWeight, nextWeight: 0});
                } else {
                    data = FarmWeightData({epoch: _epoch, currentWeight: 0, nextWeight: 0});
                }
            }

            data.nextWeight += uint112(_userWeight.mulWadDown(_votes[i].weight));
            farmWeightData[farm] = data;
            weightAllocated += _votes[i].weight;
        }

        // user must allocate all of their voting power when casting a vote
        // or not vote for a particular farm type at all
        // for example, user can choose to vote only for liquid farms, or only for maturity farms
        require(
            weightAllocated == FixedPointMathLib.WAD || weightAllocated == 0,
            InvalidWeights(FixedPointMathLib.WAD, weightAllocated)
        );
    }

    function _getVoteWeights(address[] memory _farms) internal view returns (uint256[] memory, uint256) {
        uint32 epoch = uint32(block.timestamp.epoch());
        uint256[] memory weights = new uint256[](_farms.length);

        uint256 totalPower = 0;

        for (uint256 i = 0; i < _farms.length; i++) {
            weights[i] = _getFarmWeight(farmWeightData[_farms[i]], epoch);
            totalPower += weights[i];
        }

        return (weights, totalPower);
    }

    function _validateAssetAndType(address _asset, address _farm, uint256 _type) internal view {
        FarmRegistry _farmRegistry = FarmRegistry(farmRegistry);
        require(_farmRegistry.isFarmOfType(_farm, uint256(_type)), UnknownFarm(_farm, true));
        require(_farmRegistry.isFarmOfAsset(_farm, _asset), InvalidAsset(_asset));
    }

    function _validateFarmBucket(address _farm, uint32 _unwindingEpochs) internal view {
        uint256 maturity = IMaturityFarm(_farm).maturity();
        uint256 userUnwindingTimestamp = (block.timestamp.nextEpoch() + _unwindingEpochs).epochToTimestamp();
        require(maturity <= userUnwindingTimestamp, InvalidTargetBucket(_farm, maturity, userUnwindingTimestamp));
    }
}
