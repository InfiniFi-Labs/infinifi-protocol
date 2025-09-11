// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {Farm, IFarm} from "@integrations/Farm.sol";

/// @notice InfiniFi Farm that can hold multiple asset tokens.
abstract contract MultiAssetFarm is Farm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// @notice reference to the accounting contract
    address public immutable accounting;

    error InvalidAsset(address asset);
    error InvalidFarm(address farm);

    constructor(address _core, address _assetToken, address _accounting) Farm(_core, _assetToken) {
        accounting = _accounting;
    }

    /// @notice the asset tokens that the farm can hold.
    /// @dev MUST include the assetToken of the farm.
    /// @dev MUST only include tokens that can be freely airdropped to the farm
    /// while being accounted properly in the assets() function.
    function assetTokens() public view virtual returns (address[] memory);

    /// @notice return true if the farm can hold the given asset token.
    function isAssetSupported(address _asset) public view virtual returns (bool);

    /// @dev note that there may be conversion fees between supported assets and the assetToken.
    /// This is not reflected in the amount returned by assets().
    function assets() public view virtual override returns (uint256) {
        uint256 assetTokenBalance = IERC20(assetToken).balanceOf(address(this));
        uint256 assetTokenPrice = Accounting(accounting).price(assetToken);

        address[] memory supportedAssets = assetTokens();
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == assetToken) continue;
            uint256 balance = IERC20(supportedAssets[i]).balanceOf(address(this));
            uint256 price = Accounting(accounting).price(supportedAssets[i]);
            assetTokenBalance += balance.mulDivDown(price, assetTokenPrice);
        }

        return assetTokenBalance;
    }

    /// @notice Current liquidity of the farm is the held reference assetToken.
    function liquidity() public view override returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this));
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm.
    /// @dev There should be other functions to do conversions between the assetTokens or deploying
    /// the funds to a productive yield source.
    function _deposit(uint256) internal view virtual override {}

    function deposit() external virtual override onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        uint256 currentAssets = assets();
        if (currentAssets > cap) {
            revert CapExceeded(currentAssets, cap);
        }

        _deposit(0);

        /// @dev note that in airdrops we do not know the amount of assets before the deposit,
        /// therefore we emit an event that contains twice the assets after the deposit.
        emit AssetsUpdated(block.timestamp, currentAssets, currentAssets);
    }

    /// @dev Withdrawal can only handle the reference assetToken (i.e. the liquidity()).
    /// @dev There should be other functions to do conversions between the assetTokens or pulling
    /// the funds out of a productive yield source.
    function _withdraw(uint256 _amount, address _to) internal virtual override {
        IERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice withdraw the reference assetToken.
    function withdraw(uint256 amount, address to)
        external
        virtual
        override
        onlyCoreRole(CoreRoles.FARM_MANAGER)
        whenNotPaused
    {
        uint256 assetsBefore = assets();
        _withdraw(amount, to);

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsBefore - amount);
    }

    /// @notice function used to withdraw any supported assetTokens.
    function withdrawSecondaryAsset(address _asset, uint256 _amount, address _to)
        external
        onlyCoreRole(CoreRoles.FARM_MANAGER)
        whenNotPaused
    {
        require(isAssetSupported(_asset) && _asset != assetToken, InvalidAsset(_asset));

        uint256 assetsBefore = assets();
        IERC20(_asset).safeTransfer(_to, _amount);
        uint256 assetsAfter = assets();

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsAfter);
    }
}
