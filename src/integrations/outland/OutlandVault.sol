// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {OutlandFarm} from "@integrations/outland/OutlandFarm.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

/// @title OutlandVault
/// @notice A cross-chain asset vault managing deposits and withdrawals for farms with liquidity tracking
/// @dev Simplified ERC4626-style vault with non-transferable shares and portal-controlled cross-chain operations
/// @dev can only support assets that have similar value, for iUSD instances it would be USDC, USDe, DAI, USDT, etc
/// @dev Requires Oracle to function, Should set price to 1e18 (1$) as it is supposed to work with stables
contract OutlandVault is ERC20, CoreControlled {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    error NotFarm(address _sender);
    error InvalidAmount(uint256 _amount);
    error TransfersNotAllowed();
    error InsufficientLiquidity(address _token, uint256 _requested, uint256 _available);

    event Redeemed(uint256 indexed timestamp, address token, uint256 shares, uint256 amount);
    event Deposited(uint256 indexed timestamp, address token, uint256 amount, uint256 shares);
    event PortalUpdate(uint256 indexed timestamp, uint256 oldAssets, uint256 newAssets);
    event PortalDeposit(uint256 indexed timestamp, address token, uint256 amount, uint256 sharesMinted);
    event PortalWithdraw(uint256 indexed timestamp, address token, uint256 amount);

    /// @notice The chain ID where this vault operates
    uint256 public immutable chainId;

    /// @notice Address of the outland farm contract that can deposit/redeem from this vault
    address public immutable outlandFarm;

    /// @notice Initializes the OutlandVault contract
    /// @dev Sets up ERC20 token with dynamic name based on chain ID
    /// @param _core Address of the Core contract for role management
    /// @param _farm Address of the farm of this vault
    constructor(address _core, address _farm)
        ERC20(
            string.concat("Outland - ", Strings.toString(OutlandFarm(_farm).chainId()), " Vault"),
            string.concat("OV-", Strings.toString(OutlandFarm(_farm).chainId()))
        )
        CoreControlled(_core)
    {
        outlandFarm = _farm;
        chainId = OutlandFarm(_farm).chainId();
    }

    /// @notice Restricts function access to only registered farm
    modifier onlyOutlandFarm() {
        require(msg.sender == outlandFarm, NotFarm(msg.sender));
        _;
    }

    /// @notice Returns the total amount of liquid shares in the vault
    function liquidShares() public view returns (uint256 totalLiquidShares) {
        address[] memory assets = OutlandFarm(outlandFarm).assetTokens();
        for (uint256 i = 0; i < assets.length; i++) {
            totalLiquidShares += convertToShares(assets[i], ERC20(assets[i]).balanceOf(address(this)));
        }
    }

    /// @notice helper method which allows reading share liquidity per token
    /// @return how many shares are instantly redeemable for a given token
    function liquidShares(address _token) public view returns (uint256) {
        return convertToShares(_token, ERC20(_token).balanceOf(address(this)));
    }

    /// ============================================================
    /// Farm Operations
    /// ============================================================

    /// @notice Deposits an asset into the vault and mints shares
    /// @dev Can only be called by the registered outland farm
    /// @dev Converts deposited tokens to asset token equivalent and mints shares
    /// @param _token The asset token to deposit
    /// @param _amount The amount of asset to deposit
    function deposit(address _token, uint256 _amount) external onlyOutlandFarm returns (uint256) {
        require(_amount > 0, InvalidAmount(_amount));
        _syncSharesToLiquidity();

        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 shares = convertToShares(_token, _amount);
        _mint(msg.sender, shares);

        emit Deposited(block.timestamp, _token, _amount, shares);
        return shares;
    }

    /// @notice Redeems shares from the vault and withdraws assets
    /// @dev Can only be called by the registered outland farm
    /// @dev Burns shares and transfers equivalent amount of tokens to the farm
    /// @param _token The asset token to withdraw
    /// @param _shares The amount of shares to redeem
    function redeem(address _token, uint256 _shares) external onlyOutlandFarm returns (uint256) {
        require(_shares > 0, InvalidAmount(_shares));
        _syncSharesToLiquidity();

        uint256 _liquidShares = liquidShares(_token);
        require(_liquidShares >= _shares, InsufficientLiquidity(_token, _shares, _liquidShares));

        uint256 tokenAmount = convertToAssets(_token, _shares);
        ERC20(_token).safeTransfer(outlandFarm, tokenAmount);
        _burn(msg.sender, _shares);

        emit Redeemed(block.timestamp, _token, _shares, tokenAmount);
        return tokenAmount;
    }

    /// @notice Converts token to shares of this vault
    /// @param _tokenIn The asset token to convert from
    /// @param _amountIn The amount of asset to convert
    /// @return The equivalent amount in shares
    function convertToShares(address _tokenIn, uint256 _amountIn) public view returns (uint256) {
        return OutlandFarm(outlandFarm).convert(_tokenIn, address(this), _amountIn);
    }

    /// @notice Converts from vault shares to specific token asset
    /// @param _tokenOut The asset token to convert to
    /// @param _sharesIn The amount of shares to convert
    /// @return The equivalent amount in the target token denomination
    function convertToAssets(address _tokenOut, uint256 _sharesIn) public view returns (uint256) {
        return OutlandFarm(outlandFarm).convert(address(this), _tokenOut, _sharesIn);
    }

    /// ============================================================
    /// Portal Operations
    /// ============================================================

    /// @notice Updates the vault's total assets based on portal accounting
    /// @dev Syncs the farm's share balance with the external accounting system
    /// @dev Mints shares on profit, burns shares on loss (up to available liquidity)
    /// @param _totalAssetsValue New total assets value reported by the external accounting
    function portalUpdate(uint256 _totalAssetsValue) external onlyCoreRole(CoreRoles.OUTLAND_PORTAL) {
        _syncSharesToLiquidity();

        // what is reported on other chain + what is held by this vault
        uint256 sharesTotalAfter = _totalAssetsValue + liquidShares();
        uint256 sharesTotalBefore = balanceOf(outlandFarm);

        if (sharesTotalAfter > sharesTotalBefore) {
            _mint(outlandFarm, sharesTotalAfter - sharesTotalBefore);
        } else if (sharesTotalAfter < sharesTotalBefore) {
            uint256 sharesToBurn = sharesTotalBefore - sharesTotalAfter;
            _burn(outlandFarm, sharesToBurn);
            _syncSharesToLiquidity();
        }

        emit PortalUpdate(block.timestamp, sharesTotalBefore, sharesTotalAfter);
    }

    /// @notice Deposits assets into the vault via the portal
    /// @dev Can only be called by the registered portal contract
    /// @dev Mints shares if the liquidity exceeds the farm's current share balance
    /// @param _token The asset token to deposit
    /// @param _amount The amount of asset token to deposit
    function portalDeposit(address _token, uint256 _amount) external onlyCoreRole(CoreRoles.OUTLAND_PORTAL) {
        require(_amount > 0, InvalidAmount(_amount));
        ERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 sharesMinted = _syncSharesToLiquidity();

        emit PortalDeposit(block.timestamp, _token, _amount, sharesMinted);
    }

    /// @notice Withdraws assets from the vault via the portal
    /// @dev Can only be called by the registered portal contract
    /// @dev Does not burn shares, only transfers tokens from vault to portal
    /// @param _token The asset token to withdraw
    /// @param _amount The amount of asset to withdraw
    function portalWithdraw(address _token, uint256 _amount) external onlyCoreRole(CoreRoles.OUTLAND_PORTAL) {
        uint256 tokenBalance = ERC20(_token).balanceOf(address(this));
        require(tokenBalance >= _amount, InvalidAmount(_amount));

        ERC20(_token).safeTransfer(msg.sender, _amount);

        _syncSharesToLiquidity();
        emit PortalWithdraw(block.timestamp, _token, _amount);
    }

    /// ============================================================
    /// Internal Operations
    /// ============================================================

    /// @notice Enforces that liqudity and issued shares are in sync
    /// @return how many new shares are minted
    function _syncSharesToLiquidity() internal returns (uint256) {
        uint256 sharesLiquid = liquidShares();
        uint256 sharesInFarm = balanceOf(outlandFarm);

        // nothing to reconcile
        if (sharesInFarm >= sharesLiquid) return 0;

        uint256 sharesToMint = sharesLiquid - sharesInFarm;
        _mint(outlandFarm, sharesToMint);
        return sharesToMint;
    }

    /// @notice Internal hook that prevents transfers between non-zero addresses
    /// @dev Overrides ERC20._update to make vault shares non-transferable
    /// @dev Allows minting (from=0) and burning (to=0) but blocks regular transfers
    /// @param _from Source address (zero for minting)
    /// @param _to Destination address (zero for burning)
    /// @param _value Amount of shares being transferred
    function _update(address _from, address _to, uint256 _value) internal override {
        if (_from != address(0) && _to != address(0)) {
            revert TransfersNotAllowed();
        }

        super._update(_from, _to, _value);
    }
}
