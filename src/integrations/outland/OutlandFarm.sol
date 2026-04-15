// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {OutlandVault} from "@integrations/outland/OutlandVault.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";

/// @title OutlandFarm [1 week farm]
/// @notice A farm contract that integrates with OutlandVault for cross-chain yield
contract OutlandFarm is MultiAssetFarmV2, IMaturityFarm {
    using SafeERC20 for ERC20;

    error VaultNotSet();

    event VaultSet(address indexed vault);
    event VaultDeposited(uint256 indexed timestamp, address _token, uint256 amount);
    event VaultWithdrawn(uint256 indexed timestamp, address _token, uint256 amount);

    /// @notice The chain ID where this farm operates
    uint256 public immutable chainId;

    /// @notice Offsets maturity to always be in future. (eg. 1 week, 2 weeks, etc)
    uint256 public immutable maturityOffset;

    /// @notice Vault contract
    OutlandVault public vault;

    /// @notice Initializes the OutlandFarm contract
    /// @param _core Address of the Core contract for role management
    /// @param _assetToken Address of the primary asset token for this farm
    /// @param _chainId Chain ID where this farm operates
    /// @param _accounting Address of the accounting module for asset tracking
    constructor(address _core, address _assetToken, uint256 _chainId, address _accounting, uint256 _maturityOffset)
        MultiAssetFarmV2(_core, _assetToken, _accounting)
    {
        chainId = _chainId;
        maturityOffset = _maturityOffset;
        _enableAsset(_assetToken);
    }

    /// @notice Sets the vault contract address
    /// @dev Should be called once,
    /// but in case of changing it be make sure to bring the old vault shares to zero
    /// @param _vault Address of the OutlandVault contract
    function setVault(address _vault) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        vault = OutlandVault(_vault);
        _enableAsset(_vault);
        emit VaultSet(_vault);
    }

    /// @notice Indicates that this farm is a 1 week duration asset
    /// @dev Returns current timestamp plus 7 days, representing the maturity date
    /// @return The maturity timestamp (current time + 7 days)
    function maturity() public view returns (uint256) {
        return block.timestamp + maturityOffset;
    }

    /// @notice Deposits tokens to the OutlandVault contract
    /// @param _token Token to deposit into vault
    /// @param _amount Amount of vault tokens to deposit
    function depositToVault(address _token, uint256 _amount)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_KEEPER)
    {
        require(address(vault) != address(0), VaultNotSet());
        require(isAssetSupported(_token), InvalidAsset(_token));

        ERC20(_token).forceApprove(address(vault), _amount);
        vault.deposit(_token, _amount);
        emit VaultDeposited(block.timestamp, _token, _amount);
    }

    /// @notice Withdraws vault shares and receives vault tokens
    /// @param _token Token to withdraw from the vault
    /// @param _shares Amount of vault shares to withdraw
    function withdrawFromVault(address _token, uint256 _shares)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_KEEPER)
    {
        require(address(vault) != address(0), VaultNotSet());
        require(isAssetSupported(_token), InvalidAsset(_token));

        uint256 tokenAmount = vault.redeem(_token, _shares);
        emit VaultWithdrawn(block.timestamp, _token, tokenAmount);
    }
}
