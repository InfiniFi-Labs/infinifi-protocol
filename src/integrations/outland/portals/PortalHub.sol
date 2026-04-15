// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {OutlandVault} from "@integrations/outland/OutlandVault.sol";

import {PortalBase} from "@integrations/outland/portals/PortalBase.sol";
import {OutlandMsgCodec} from "@integrations/outland/OutlandMsgCodec.sol";
import {IOutlandConnector} from "@interfaces/IOutlandPortal.sol";

/// @title PortalHub
/// @notice Main hub portal contract on Ethereum mainnet for managing cross-chain vault operations
/// @dev Manages multiple OutlandVaults for different chains and handles cross-chain token transfers and asset updates
contract PortalHub is PortalBase {
    using SafeERC20 for ERC20;
    using EnumerableMap for EnumerableMap.UintToAddressMap;
    using EnumerableMap for EnumerableMap.AddressToAddressMap;

    event VaultSet(uint256 timestamp, uint256 chainId, address indexed vault);
    event AssetMappingSet(uint256 timestamp, uint256 chainId, address indexed hubAsset, address indexed outpostAsset);

    /// @notice Maps chainId to vault address for each supported chain
    EnumerableMap.UintToAddressMap vaults;

    /// @notice Maps chainId to asset registry (hub asset => chain asset)
    /// @dev Helpful when token addresses are not the same over multiple chains
    mapping(uint256 chainId => EnumerableMap.AddressToAddressMap) assetMapping;

    constructor() PortalBase(address(1), 1) {}

    function init(address _core, uint256 _hubChainId) external {
        require(address(core()) == address(0), AlreadyInitialized());
        chainId = _hubChainId;
        _setCore(_core);
    }

    /// ============================================================
    /// Vault Management
    /// ============================================================

    function setVault(address _vault) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_vault != address(0), InvalidVault(_vault));
        uint256 chainId = OutlandVault(_vault).chainId();
        vaults.set(chainId, _vault);
        emit VaultSet(block.timestamp, chainId, _vault);
    }

    /// @notice Returns the vault address for a given chain
    /// @param _chainId The chain ID to query
    /// @return The vault address for the specified chain
    function getVault(uint256 _chainId) public view returns (address) {
        return vaults.get(_chainId);
    }

    /// @notice Returns all chain IDs that have registered vaults
    /// @return Array of chain IDs with registered vaults
    function getVaultChainIds() external view returns (uint256[] memory) {
        return vaults.keys();
    }

    /// ============================================================
    /// Asset Registry Management
    /// ============================================================

    /// @notice Configures mapping of assets between this chain and other chains
    /// @dev To be used in case when token addresses are different between chains
    /// @dev Creates bidirectional mapping: hubAsset <-> outpostAsset
    /// @param _chainId The chain ID for which to set the asset mapping
    /// @param _hubAsset The asset token address on the hub (mainnet)
    /// @param _outpostAsset The asset token address on the outpost
    function setAssetMapping(uint256 _chainId, address _hubAsset, address _outpostAsset)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        assetMapping[_chainId].set(_hubAsset, _outpostAsset);
        assetMapping[_chainId].set(_outpostAsset, _hubAsset);
        emit AssetMappingSet(block.timestamp, _chainId, _hubAsset, _outpostAsset);
    }

    /// @notice Returns the mapped asset address for a given chain and asset
    /// @param _chainId The chain ID to query
    /// @param _asset The asset token address to look up
    /// @return The corresponding asset address on the target chain
    function getAssetMapping(uint256 _chainId, address _asset) external view returns (address) {
        return assetMapping[_chainId].get(_asset);
    }

    /// ============================================================
    /// Sender side
    /// ============================================================

    /// @notice Sends tokens from the hub to an outpost chain
    /// @dev Withdraws tokens from vault, approves connector, and initiates cross-chain transfer
    /// @dev Can only be called by OUTLAND_KEEPER role
    /// @param _chainId The destination chain ID
    /// @param _token The token address to send
    /// @param _amount The amount of tokens to send
    /// @param _connector The authorized connector address
    function sendTokens(uint256 _chainId, address _token, uint256 _amount, address payable _connector)
        external
        payable
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_KEEPER)
    {
        require(_amount > 0, InvalidAmount(_amount));
        require(vaults.contains(_chainId), ChainNotSupported(_chainId));
        require(assetMapping[_chainId].contains(_token), InvalidAsset(_token));
        require(isConnector(_connector), InvalidSender(_connector));

        TransferPayload memory payload = TransferPayload({
            selector: OutlandMsgCodec.TRANSFER,
            chainId: chainId,
            assetToken: assetMapping[_chainId].get(_token),
            amount: _amount
        });

        address vault = vaults.get(_chainId);
        OutlandVault(vault).portalWithdraw(_token, _amount);

        ERC20(_token).forceApprove(_connector, _amount);
        IOutlandConnector(_connector).sendTokens{value: msg.value}(_chainId, _token, _amount, abi.encode(payload));

        emit TokensSent(block.timestamp, _chainId, _token, _amount, _connector);
    }

    /// ============================================================
    /// Receiver side
    /// ============================================================

    /// @notice Receives and processes cross-chain messages from outpost chains
    /// @dev Validates the sender, decodes message type, and routes to appropriate handler
    /// @dev Can only be called by authorized message receivers
    /// @param _chainId The source chain ID from which the message originated
    /// @param _data Encoded message data containing message type, chainId, and payload
    function receiveMessage(uint256 _chainId, bytes calldata _data) external whenNotPaused {
        address connector = msg.sender;
        require(isConnector(connector), InvalidReceiver(connector));

        bytes1 messageType = OutlandMsgCodec.getMessageType(_data);
        uint256 senderChainId = OutlandMsgCodec.getChainId(_data);
        require(_chainId == senderChainId, InvalidChainId(_chainId, senderChainId));
        require(vaults.contains(senderChainId), ChainNotSupported(senderChainId));

        if (messageType == OutlandMsgCodec.TRANSFER) {
            (address senderToken, uint256 amount) = OutlandMsgCodec.getTransferPayload(_data);
            address actualToken = assetMapping[senderChainId].get(senderToken);
            require(actualToken != address(0), InvalidAsset(senderToken));
            _handleReceiveTokenTransfer(connector, senderChainId, actualToken, amount);
        } else if (messageType == OutlandMsgCodec.MESSAGE) {
            uint256 totalAssetsValue = OutlandMsgCodec.getAssetsUpdatePayload(_data);
            _handleReceiveAssetsUpdate(senderChainId, totalAssetsValue);
        }
    }

    /// @notice Internal handler for receiving token transfers from outpost chains
    /// @dev Pulls assets from receiver, approves vault, and deposits to the vault
    /// @param _receiver The message receiver contract that holds the tokens
    /// @param _chainId The source chain ID
    /// @param _token The token address to receive
    /// @param _amount The amount of tokens to receive
    function _handleReceiveTokenTransfer(address _receiver, uint256 _chainId, address _token, uint256 _amount)
        internal
    {
        OutlandVault vault = OutlandVault(vaults.get(_chainId));
        IOutlandConnector(_receiver).pullAssets(_token, _amount);

        ERC20(_token).forceApprove(address(vault), _amount);
        vault.portalDeposit(_token, _amount);
        emit TokensReceived(block.timestamp, _chainId, _token, _amount, _receiver);
    }

    /// @notice Internal handler for receiving asset updates from outpost chains
    /// @dev Updates the vault with the latest total assets from the outpost chain
    /// @param _chainId The source chain ID
    /// @param _totalAssetsValue The new total assets value reported from the outpost
    function _handleReceiveAssetsUpdate(uint256 _chainId, uint256 _totalAssetsValue) internal {
        OutlandVault(vaults.get(_chainId)).portalUpdate(_totalAssetsValue);
        emit AssetsUpdateReceived(block.timestamp, _chainId, _totalAssetsValue);
    }
}
