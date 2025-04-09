// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {IBeforeRedeemHook} from "@interfaces/IRedeemController.sol";

contract BeforeRedeemHook is IBeforeRedeemHook, CoreControlled {
    using FixedPointMathLib for uint256;

    address public accounting;
    address public allocationVoting;

    constructor(address _core, address _accounting, address _allocationVoting) CoreControlled(_core) {
        accounting = _accounting;
        allocationVoting = _allocationVoting;
    }

    /// @notice returns leftover amount to be redeemed if the amount is greater than the total assets
    function beforeRedeem(address, uint256, uint256 _assetAmountOut)
        public
        onlyCoreRole(CoreRoles.RECEIPT_TOKEN_BURNER)
    {
        if (_assetAmountOut == 0) return;

        address _asset = IFarm(msg.sender).assetToken();
        uint256 totalAssets = Accounting(accounting).totalAssetsOf(_asset, FarmTypes.LIQUID);

        if (totalAssets == 0) {
            // No assets available
            return;
        }

        (address[] memory liquidFarms, uint256[] memory votingWeights, uint256 totalPower) =
            AllocationVoting(allocationVoting).getAssetVoteWeights(_asset, FarmTypes.LIQUID);

        if (_assetAmountOut >= totalAssets) {
            // Redeem all available liquidity
            _processProportionalRedeem(liquidFarms, totalAssets, totalAssets);
            return;
        }

        if (totalPower == 0) {
            _processProportionalRedeem(liquidFarms, totalAssets, _assetAmountOut);
            return;
        }

        address farm = _findOptimalRedeemFarm(liquidFarms, votingWeights, totalPower, totalAssets, _assetAmountOut);

        if (farm == address(0)) {
            // Redeem from all farms
            _processProportionalRedeem(liquidFarms, totalAssets, _assetAmountOut);
            return;
        }

        IFarm(farm).withdraw(_assetAmountOut, msg.sender);
    }

    /// @notice returns the most optimal farm to redeem from based on the current allocation and target allocation
    /// @dev if the farm has no weight, the address will be address(0)
    function _findOptimalRedeemFarm(
        address[] memory _farms,
        uint256[] memory _weights,
        uint256 _totalPower,
        uint256 _totalAssets,
        uint256 _amount
    ) internal view returns (address) {
        int256 minChange = type(int256).max;
        int256 targetIndex = -1;

        for (uint256 index = 0; index < _farms.length; ++index) {
            address farm = _farms[index];
            uint256 farmBalance = IFarm(farm).assets();

            if (farmBalance < _amount) {
                // Indicates that the farm has less liquidity than the amount to redeem
                // We should not redeem from this farm but use some other logic
                continue;
            }

            unchecked {
                int256 difference =
                    int256(_weights[index] * (_totalAssets - _amount)) - int256((farmBalance - _amount) * _totalPower);

                if (difference < minChange) {
                    minChange = difference;
                    targetIndex = int256(index);
                }
            }
        }

        return targetIndex == -1 ? address(0) : _farms[uint256(targetIndex)];
    }

    /// @notice process a proportional redeem from all farms
    /// @dev doesn't help with the allocation, but it's a good fallback
    function _processProportionalRedeem(address[] memory _farms, uint256 _totalAssets, uint256 _amount) internal {
        for (uint256 i = 0; i < _farms.length; i++) {
            uint256 farmBalance = IFarm(_farms[i]).assets();
            uint256 assetsOut = _amount.mulDivDown(farmBalance, _totalAssets);
            if (assetsOut > 0) {
                IFarm(_farms[i]).withdraw(assetsOut, msg.sender);
            }
        }
    }
}
