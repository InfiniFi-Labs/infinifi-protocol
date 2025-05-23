// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {IBeforeRedeemHook} from "@interfaces/IRedeemController.sol";

contract BeforeRedeemHook is IBeforeRedeemHook, CoreControlled {
    using FixedPointMathLib for uint256;

    error AssetNotEnabled(address _asset);

    address public immutable accounting;
    address public immutable allocationVoting;
    address public immutable mintController;

    constructor(address _core, address _accounting, address _allocationVoting, address _mintController)
        CoreControlled(_core)
    {
        accounting = _accounting;
        allocationVoting = _allocationVoting;
        mintController = _mintController;
    }

    /// @notice returns leftover amount to be redeemed if the amount is greater than the total assets
    function beforeRedeem(address, uint256, uint256 _assetAmountOut)
        external
        onlyCoreRole(CoreRoles.RECEIPT_TOKEN_BURNER)
    {
        // if the hook is paused, do nothing
        if (paused()) return;

        if (_assetAmountOut == 0) return;

        address _asset = IFarm(msg.sender).assetToken();
        bool assetEnabled = FarmRegistry(Accounting(accounting).farmRegistry()).isAssetEnabled(_asset);
        require(assetEnabled, AssetNotEnabled(_asset));

        _assetAmountOut = _processMintController(_assetAmountOut);
        if (_assetAmountOut == 0) return;

        uint256 totalAssets = Accounting(accounting).totalAssetsOf(_asset, FarmTypes.LIQUID);
        // No assets available
        if (totalAssets == 0) return;

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

        // No optimal farm found, redeem from all farms
        if (farm == address(0)) {
            _processProportionalRedeem(liquidFarms, totalAssets, _assetAmountOut);
            return;
        }

        IFarm(farm).withdraw(_assetAmountOut, msg.sender);
        IFarm(msg.sender).deposit();
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
            if (Pausable(farm).paused()) continue;

            uint256 farmBalance = IFarm(farm).liquidity();

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
    /// @dev doesn't check if the farm is paused and is expected to revert if it is, users can always opt to redeem less.
    function _processProportionalRedeem(address[] memory _farms, uint256 _totalAssets, uint256 _amount) internal {
        for (uint256 i = 0; i < _farms.length; i++) {
            uint256 farmBalance = IFarm(_farms[i]).assets();
            uint256 assetsOut = _amount.mulDivUp(farmBalance, _totalAssets);

            if (assetsOut > 0) {
                IFarm(_farms[i]).withdraw(assetsOut, msg.sender);
            }
        }
        IFarm(msg.sender).deposit();
    }

    function _processMintController(uint256 _assetAmountOut) internal returns (uint256) {
        address _mintController = mintController;
        if (_mintController == address(0)) return _assetAmountOut;

        uint256 liquidity = IFarm(_mintController).liquidity();
        if (liquidity == 0) return _assetAmountOut;

        // in case mint controller can only partially cover the amount to redeem
        // we redeem from the mint controller and return the difference
        if (_assetAmountOut > liquidity) {
            IFarm(_mintController).withdraw(liquidity, msg.sender);
            return _assetAmountOut - liquidity;
        }

        IFarm(_mintController).withdraw(_assetAmountOut, msg.sender);
        IFarm(msg.sender).deposit();
        return 0;
    }
}
