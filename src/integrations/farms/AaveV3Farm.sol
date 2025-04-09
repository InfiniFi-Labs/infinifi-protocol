// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Farm} from "@integrations/Farm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAaveV3Pool} from "@interfaces/aave/IAaveV3Pool.sol";
import {IAddressProvider} from "@interfaces/aave/IAddressProvider.sol";
import {IAaveDataProvider} from "@interfaces/aave/IAaveDataProvider.sol";

/// @title Aave V3 Farm
/// @notice This contract is used to deploy assets to aave v3
contract AaveV3Farm is Farm {
    address public immutable aToken;

    /// @notice the aave v3 lending pool
    address public immutable lendingPool;

    /// @notice the aave v3 data provider contract
    address public immutable dataProvider;

    constructor(address _aToken, address _aaveV3Pool, address _core, address _assetToken) Farm(_core, _assetToken) {
        aToken = _aToken;
        lendingPool = _aaveV3Pool;
        address _addressProvider = IAaveV3Pool(lendingPool).ADDRESSES_PROVIDER();
        dataProvider = IAddressProvider(_addressProvider).getPoolDataProvider();
    }

    /// @notice Returns the total assets in the farm + the rebasing balance of the aToken
    function assets() public view override returns (uint256) {
        return super.assets() + ERC20(aToken).balanceOf(address(this));
    }

    /// @notice Returns the liquidity available on aave for the assetToken
    /// @dev This is the amount of assetToken that is available to withdraw from aave for asset Token
    /// @dev and also adds the amount of assetToken held by the Farm contract (not deposited to aave if any)
    function liquidity() public view override returns (uint256) {
        uint256 totalAssets = this.assets();
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
        ERC20(assetToken).approve(address(lendingPool), availableBalance);
        // trigger the deposit the asset tokens to the lending pool
        IAaveV3Pool(lendingPool).supply(assetToken, availableBalance, address(this), 0);
    }

    /// @notice Returns the max deposit amount for the underlying protocol
    function _underlyingProtocolMaxDeposit() internal view override returns (uint256) {
        // aave returns the supply cap with 0 decimals. e.g 1000 USDC supply cap returns 1000
        (, uint256 supplyCap) = IAaveDataProvider(dataProvider).getReserveCaps(assetToken);

        // convert the supply cap to the asset token decimals
        uint256 supplyCapInAssetTokenDecimals = supplyCap * 10 ** ERC20(assetToken).decimals();

        // get the amount already supplied to aave
        // which is expressed by the total supply of the aToken
        uint256 currentUnderlyingProtocolSupply = ERC20(aToken).totalSupply();

        // max deposit in the underlying protocol is the supply cap minus the current protocol supply
        return supplyCapInAssetTokenDecimals - currentUnderlyingProtocolSupply;
    }

    /// @notice Withdraw from the aave v3 lending pool
    /// @dev this function withdraw the amount of assetToken from the aave v3 lending pool
    /// @dev this function assumes that the amount of assetToken to withdraw is available on aave
    /// @dev if amount is uint256.max, it will withdraw all that is available on aave
    function _withdraw(uint256 _amount, address _to) internal override {
        IAaveV3Pool(lendingPool).withdraw(assetToken, _amount, _to);
    }
}
