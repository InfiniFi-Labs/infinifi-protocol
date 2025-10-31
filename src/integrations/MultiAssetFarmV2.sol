// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {Farm, IFarm} from "@integrations/Farm.sol";

/// @title MultiAssetFarmV2
/// @notice InfiniFi Farm that can hold multiple asset tokens.
/// @dev This abstract contract extends the base Farm contract to support multiple asset tokens.
/// @dev It provides functionality to manage supported assets, convert between them using oracle prices,
/// @dev and handle deposits/withdrawals of various asset types.
abstract contract MultiAssetFarmV2 is Farm {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Emitted when a new asset is enabled for the farm
    /// @param timestamp The block timestamp when the asset was enabled
    /// @param asset The address of the enabled asset token
    event AssetEnabled(uint256 indexed timestamp, address asset);

    /// @notice Emitted when an asset is disabled for the farm
    /// @param timestamp The block timestamp when the asset was disabled
    /// @param asset The address of the disabled asset token
    event AssetDisabled(uint256 indexed timestamp, address asset);

    /// @notice Thrown when an invalid array length is provided
    error InvalidLength();

    /// @notice Thrown when an invalid farm address is provided
    /// @param farm The invalid farm address
    error InvalidFarm(address farm);

    /// @notice Thrown when an invalid asset address is provided
    /// @param asset The invalid asset address
    error InvalidAsset(address asset);

    /// @notice Thrown when an asset doesn't have a valid oracle
    /// @param _asset The asset address without a valid oracle
    error InvalidOracle(address _asset);

    /// @notice Thrown when trying to disable an asset with non-zero balance
    /// @param _asset The asset address with non-zero balance
    /// @param _balance The current balance of the asset
    error InvalidBalance(address _asset, uint256 _balance);

    /// @notice Base amount of assets required to prevent removal without decimals
    uint256 public constant ASSET_REMOVAL_THRESHOLD = 1;

    /// @notice Reference to the accounting contract used for price oracles and asset management
    address public immutable accounting;

    /// @notice Set of supported asset tokens (excluding the primary assetToken)
    EnumerableSet.AddressSet private _assetTokens;

    /// @notice Constructor for MultiAssetFarmV2
    /// @param _core The address of the core contract
    /// @param _assetToken The primary asset token for this farm
    /// @param _accounting The address of the accounting contract
    constructor(address _core, address _assetToken, address _accounting) Farm(_core, _assetToken) {
        accounting = _accounting;
    }

    /// @notice Returns the list of asset tokens that the farm can hold
    /// @dev MUST include the assetToken of the farm
    /// @dev MUST only include tokens that can be freely airdropped to the farm
    /// while being accounted properly in the assets() function
    /// @return Array of supported asset token addresses
    function assetTokens() public view virtual returns (address[] memory) {
        return _assetTokens.values();
    }

    /// @notice Checks if the farm can hold the given asset token
    /// @param _asset The asset token address to check
    /// @return True if the asset is supported, false otherwise
    function isAssetSupported(address _asset) public view virtual returns (bool) {
        return _asset == assetToken || (_assetTokens.contains(_asset) && _hasOracle(_asset));
    }

    /// @notice Returns the total value of all assets held by the farm in terms of the primary assetToken
    /// @dev Note that there may be conversion fees between supported assets and the assetToken.
    /// This is not reflected in the amount returned by assets()
    /// @return Total value of all assets in terms of the primary assetToken
    function assets() public view virtual override returns (uint256) {
        uint256 assetTokenBalance = ERC20(assetToken).balanceOf(address(this));
        uint256 assetTokenPrice = Accounting(accounting).price(assetToken);

        address[] memory supportedAssets = assetTokens();
        for (uint256 i = 0; i < supportedAssets.length; i++) {
            if (supportedAssets[i] == assetToken) continue;
            uint256 balance = ERC20(supportedAssets[i]).balanceOf(address(this));
            uint256 price = Accounting(accounting).price(supportedAssets[i]);
            assetTokenBalance += balance.mulDivDown(price, assetTokenPrice);
        }

        return assetTokenBalance;
    }

    /// @notice Returns the current liquidity of the farm (held reference assetToken)
    /// @return The balance of the primary assetToken held by the farm
    function liquidity() public view override returns (uint256) {
        return ERC20(assetToken).balanceOf(address(this));
    }

    /// @notice Converts a number of tokens to another token based on oracle rates
    /// @param _tokenIn The input token address
    /// @param _tokenOut The output token address
    /// @param _amountIn The amount of input tokens to convert
    /// @return The equivalent amount of output tokens
    function convert(address _tokenIn, address _tokenOut, uint256 _amountIn) public view returns (uint256) {
        if (_tokenIn == _tokenOut) return _amountIn;
        uint256 tokenInPrice = Accounting(accounting).price(_tokenIn);
        uint256 tokenOutPrice = Accounting(accounting).price(_tokenOut);
        return _amountIn.mulDivDown(tokenInPrice, tokenOutPrice);
    }

    /// @notice Enables a set of assets that will be reported by this farm
    /// @param _assetList Array of asset token addresses to enable
    function enableAssets(address[] calldata _assetList) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_assetList.length > 0, InvalidLength());
        for (uint256 i = 0; i < _assetList.length; i++) {
            address _asset = _assetList[i];
            require(!isAssetSupported(_asset), InvalidAsset(_asset));
            _enableAsset(_asset);
        }
    }

    /// @notice Disables a set of assets that are no longer required by this farm
    /// @param _assetList Array of asset token addresses to disable
    function disableAssets(address[] calldata _assetList) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_assetList.length > 0, InvalidLength());
        for (uint256 i = 0; i < _assetList.length; i++) {
            _disableAsset(_assetList[i]);
        }
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm
    /// @dev There should be other functions to do conversions between the assetTokens or deploying
    /// the funds to a productive yield source
    /// @param _amount The amount to deposit (unused in this implementation)
    function _deposit(uint256 _amount) internal view virtual override {}

    /// @notice Deposits assets into the farm (used for airdrops)
    /// @dev Note that in airdrops we do not know the amount of assets before the deposit,
    /// therefore we emit an event that contains twice the assets after the deposit
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

    /// @dev Withdrawal can only handle the reference assetToken (i.e. the liquidity())
    /// @dev There should be other functions to do conversions between the assetTokens or pulling
    /// the funds out of a productive yield source
    /// @param _amount The amount of assetToken to withdraw
    /// @param _to The address to send the withdrawn tokens to
    function _withdraw(uint256 _amount, address _to) internal virtual override {
        ERC20(assetToken).safeTransfer(_to, _amount);
    }

    /// @notice Withdraws the reference assetToken from the farm
    /// @param amount The amount of assetToken to withdraw
    /// @param to The address to send the withdrawn tokens to
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

    /// @notice Withdraws any supported secondary asset tokens from the farm
    /// @param _asset The address of the asset token to withdraw
    /// @param _amount The amount of the asset to withdraw
    /// @param _to The address to send the withdrawn tokens to
    function withdrawSecondaryAsset(address _asset, uint256 _amount, address _to)
        external
        onlyCoreRole(CoreRoles.FARM_MANAGER)
        whenNotPaused
    {
        require(isAssetSupported(_asset) && _asset != assetToken, InvalidAsset(_asset));

        uint256 assetsBefore = assets();
        ERC20(_asset).safeTransfer(_to, _amount);
        uint256 assetsAfter = assets();

        emit AssetsUpdated(block.timestamp, assetsBefore, assetsAfter);
    }

    /// @notice Internal function to enable a new asset for the farm
    /// @param _asset The address of the asset token to enable
    /// @dev Can add if already added but doesn't hurt as it is a set
    function _enableAsset(address _asset) internal {
        require(_hasOracle(_asset), InvalidOracle(_asset));
        // Oracle has to exist in order for new assets to be added
        _assetTokens.add(_asset);
        emit AssetEnabled(block.timestamp, _asset);
    }

    /// @dev Internal function to disable an asset for the farm
    /// @param _asset The address of the asset token to disable
    function _disableAsset(address _asset) internal {
        require(_asset != assetToken, InvalidAsset(_asset));
        require(isAssetSupported(_asset), InvalidAsset(_asset));

        // do not allow removal of nonzero balance assets
        uint256 balance = ERC20(_asset).balanceOf(address(this));
        uint256 decimals = ERC20(_asset).decimals();
        require(balance <= ASSET_REMOVAL_THRESHOLD * 10 ** decimals, InvalidBalance(_asset, balance));

        _assetTokens.remove(_asset);
        emit AssetDisabled(block.timestamp, _asset);
    }

    function _hasOracle(address _asset) internal view returns (bool) {
        try Accounting(accounting).price(_asset) returns (uint256 _price) {
            return _price > 0;
        } catch {
            return false;
        }
    }
}
