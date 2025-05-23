// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {Accounting} from "@finance/Accounting.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {IAfterMintHook} from "@interfaces/IMintController.sol";

contract AfterMintHook is IAfterMintHook, CoreControlled {
    using FixedPointMathLib for uint256;

    error AssetNotEnabled(address _asset);

    /// @notice the threshold for the asset rebalance
    uint256 public assetRebalanceThreshold;

    address public immutable accounting;
    address public immutable allocationVoting;

    constructor(address _core, address _accounting, address _allocationVoting) CoreControlled(_core) {
        accounting = _accounting;
        allocationVoting = _allocationVoting;
    }

    /// @notice set the threshold for the asset rebalance
    function setAssetRebalanceThreshold(uint256 _assetRebalanceThreshold)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        assetRebalanceThreshold = _assetRebalanceThreshold;
        emit AssetRebalanceThresholdUpdated(block.timestamp, _assetRebalanceThreshold);
    }

    function afterMint(address, uint256 _assetsIn) external onlyCoreRole(CoreRoles.RECEIPT_TOKEN_MINTER) {
        // if the hook is paused, do nothing
        if (paused()) return;

        if (_assetsIn < assetRebalanceThreshold) return;

        address _asset = IFarm(msg.sender).assetToken();
        bool assetEnabled = FarmRegistry(Accounting(accounting).farmRegistry()).isAssetEnabled(_asset);
        require(assetEnabled, AssetNotEnabled(_asset));

        uint256 totalAssets = Accounting(accounting).totalAssetsOf(_asset, FarmTypes.LIQUID);

        (address[] memory farms, uint256[] memory weights, uint256 totalPower) =
            AllocationVoting(allocationVoting).getAssetVoteWeights(_asset, FarmTypes.LIQUID);

        if (farms.length == 0) return;

        address farm = _findOptimalDepositFarm(farms, weights, totalPower, totalAssets, _assetsIn);

        if (Pausable(farm).paused()) return;

        // in case the deposit will exceed the max deposit amount,
        // we deposit as much as we can and leave the remainder in the mint controller
        // in case a certain farm is oversaturated, the funds will remain in the mint controller
        // waiting for rebalancer to properly allocate the funds
        uint256 maxDepositAmount = IFarm(farm).maxDeposit();
        uint256 depositAmount = _min(maxDepositAmount, _assetsIn);

        if (depositAmount == 0) return;

        IFarm(msg.sender).withdraw(depositAmount, address(farm));
        IFarm(farm).deposit();
    }

    /// @notice returns the most optimal farm to deposit into based on the current allocation and target allocation
    function _findOptimalDepositFarm(
        address[] memory _farms,
        uint256[] memory _weights,
        uint256 _totalPower,
        uint256 _totalAssets,
        uint256 _amount
    ) internal view returns (address) {
        uint256 targetIndex = 0;
        uint256 farmsLength = _farms.length;
        int256 minChange = type(int256).max;

        _totalAssets += _amount;

        for (uint256 index = 0; index < farmsLength;) {
            unchecked {
                uint256 farmAssets = IFarm(_farms[index]).assets();

                int256 difference =
                    int256((farmAssets + _amount) * _totalPower) - int256(_weights[index] * _totalAssets);

                if (difference < minChange) {
                    // minor optimization to avoid checking pause on unfit candidates
                    if (!Pausable(_farms[index]).paused()) {
                        minChange = difference;
                        targetIndex = index;
                    }
                }

                ++index;
            }
        }

        return _farms[targetIndex];
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
