// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Farm} from "@integrations/Farm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAaveV3Pool} from "@interfaces/aave/IAaveV3Pool.sol";
import {IAddressProvider} from "@interfaces/aave/IAddressProvider.sol";
import {IAaveDataProvider} from "@interfaces/aave/IAaveDataProvider.sol";

/// @title Aave V3 Farm
/// @notice This contract is used to deploy assets to aave v3
contract AaveV3Farm is Farm {
    using SafeERC20 for IERC20;

    address public immutable aToken;

    /// @notice the aave v3 lending pool
    address public immutable lendingPool;

    constructor(address _aToken, address _aaveV3Pool, address _core, address _assetToken) Farm(_core, _assetToken) {
        aToken = _aToken;
        lendingPool = _aaveV3Pool;
    }

    /// @notice Returns the total assets in the farm + the rebasing balance of the aToken
    function assets() public view override returns (uint256) {
        return super.assets() + ERC20(aToken).balanceOf(address(this));
    }

    /// @notice Returns the liquidity available on aave for the assetToken
    /// @dev This is the amount of assetToken that is available to withdraw from aave for asset Token
    /// @dev and also adds the amount of assetToken held by the Farm contract (not deposited to aave if any)
    function liquidity() public view override returns (uint256) {
        uint256 totalAssets = assets();

        // if aave is paused, cannot withdraw from aave
        address dataProvider = IAddressProvider(IAaveV3Pool(lendingPool).ADDRESSES_PROVIDER()).getPoolDataProvider();
        bool isAavePaused = IAaveDataProvider(dataProvider).getPaused(assetToken);
        if (isAavePaused) return super.assets();

        // find the amount of assetToken held by the aToken contract
        // this is the liquidity available on aave for the assetToken
        uint256 availableLiquidity = ERC20(assetToken).balanceOf(aToken);

        // if there is less liquidity on aave than the total assets held by the farm,
        // then the liquidity is the amount of USDC held by the farm (not deposited to aave)
        // + the amount of USDC held by the aToken contract that is available to withdraw
        return availableLiquidity < totalAssets ? availableLiquidity + super.assets() : totalAssets;
    }

    /// @notice Deposit the assetToken to the aave v3 lending pool
    /// @dev this function deposit all the available assetToken held by the farm to the aavev3 lending pool
    function _deposit() internal override {
        // get the pending balance of the asset token
        uint256 availableBalance = ERC20(assetToken).balanceOf(address(this));
        // approve the lending pool to spend the asset tokens
        IERC20(assetToken).forceApprove(address(lendingPool), availableBalance);
        // trigger the deposit the asset tokens to the lending pool
        IAaveV3Pool(lendingPool).supply(assetToken, availableBalance, address(this), 0);
    }

    /// @notice Returns the max deposit amount for the underlying protocol
    function _underlyingProtocolMaxDeposit() internal view override returns (uint256) {
        // aave returns the supply cap with 0 decimals. e.g 1000 USDC supply cap returns 1000
        address dataProvider = IAddressProvider(IAaveV3Pool(lendingPool).ADDRESSES_PROVIDER()).getPoolDataProvider();
        (, uint256 supplyCap) = IAaveDataProvider(dataProvider).getReserveCaps(assetToken);

        // aave pools that return 0 supplyCap are actually uncapped
        if (supplyCap == 0) return type(uint256).max;

        // convert the supply cap to the asset token decimals
        uint256 supplyCapInAssetTokenDecimals = supplyCap * 10 ** ERC20(assetToken).decimals();

        IAaveDataProvider.AaveDataProviderReserveData memory _reserveData =
            IAaveDataProvider(dataProvider).getReserveData(assetToken);

        // supply cap already reached
        if (_reserveData.totalAToken + _reserveData.accruedToTreasuryScaled >= supplyCapInAssetTokenDecimals) {
            return 0;
        }

        return supplyCapInAssetTokenDecimals - (_reserveData.totalAToken + _reserveData.accruedToTreasuryScaled);
    }

    /// @notice Withdraw from the aave v3 lending pool
    /// @dev this function withdraw the amount of assetToken from the aave v3 lending pool
    /// @dev this function assumes that the amount of assetToken to withdraw is available on aave
    /// @dev if amount is uint256.max, it will withdraw all that is available on aave
    function _withdraw(uint256 _amount, address _to) internal override {
        IAaveV3Pool(lendingPool).withdraw(assetToken, _amount, _to);
    }
}
