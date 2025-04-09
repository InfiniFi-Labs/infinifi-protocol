// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {Accounting} from "@finance/Accounting.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {IAfterMintHook} from "@interfaces/IMintController.sol";

contract AfterMintHook is IAfterMintHook, CoreControlled {
    using FixedPointMathLib for uint256;

    error NoFarmsFound();

    address public accounting;
    address public allocationVoting;

    constructor(address _core, address _accounting, address _allocationVoting) CoreControlled(_core) {
        accounting = _accounting;
        allocationVoting = _allocationVoting;
    }

    function afterMint(address, uint256 _assetsIn, uint256) public onlyCoreRole(CoreRoles.RECEIPT_TOKEN_MINTER) {
        address _asset = IFarm(msg.sender).assetToken();
        uint256 totalAssets = Accounting(accounting).totalAssetsOf(_asset, FarmTypes.LIQUID);

        (address[] memory farms, uint256[] memory weights, uint256 totalPower) =
            AllocationVoting(allocationVoting).getAssetVoteWeights(_asset, FarmTypes.LIQUID);

        require(farms.length > 0, NoFarmsFound());

        address farm = _findOptimalDepositFarm(farms, weights, totalPower, totalAssets, _assetsIn);

        if (farm == address(0)) {
            // No optimal farm found, skip the deposit
            return;
        }

        IFarm(msg.sender).withdraw(_assetsIn, address(farm));
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
                    minChange = difference;
                    targetIndex = index;
                }

                ++index;
            }
        }

        return _farms[targetIndex];
    }
}
