// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {OutlandMsgCodec} from "@integrations/outland/OutlandMsgCodec.sol";
import {IOutlandPortal, IOutlandConnector} from "@interfaces/IOutlandPortal.sol";

/// @title PortalBase
/// @notice Base contract for portal contracts with common connector logic
/// @dev Provides shared functionality for managing multiple connectors
abstract contract PortalBase is CoreControlled, IOutlandPortal {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The chain ID where this portal operates
    uint256 public chainId;

    /// @notice Set of authorized addresses that can send cross-chain messages
    EnumerableSet.AddressSet internal connectors;

    error AlreadyInitialized();
    error InvalidAsset(address _asset);
    error InvalidVault(address _vault);
    error InvalidAmount(uint256 _amount);
    error InvalidSender(address _sender);
    error InvalidChainId(uint256 _chainId, uint256 _decodedChainId);
    error InvalidReceiver(address _receiver);
    error ChainNotSupported(uint256 _chainId);

    error ZeroAddress();
    error EntryNotFound(address _entry);
    error DuplicateEntry(address _entry);

    event TokensSent(uint256 indexed timestamp, uint256 chainId, address token, uint256 amount, address sender);
    event TokensReceived(uint256 indexed timestamp, uint256 chainId, address token, uint256 amount, address receiver);
    event AssetsUpdateReceived(uint256 indexed timestamp, uint256 chainId, uint256 totalAssets);

    event ConnectorAdded(uint256 indexed timestamp, address connector);
    event ConnectorRemoved(uint256 indexed timestamp, address connector);

    uint256[100] private __gap;

    /// @notice Initializes the PortalBase contract
    /// @param _core Address of the Core contract for role management
    /// @param _chainId Chain ID where this portal operates
    constructor(address _core, uint256 _chainId) CoreControlled(_core) {
        chainId = _chainId;
    }

    function getSendTokensFee(uint256 _targetChainId, address _token, uint256 _amount, address payable _connector)
        external
        view
        returns (uint256)
    {
        TransferPayload memory payload = TransferPayload({
            selector: OutlandMsgCodec.TRANSFER, chainId: chainId, assetToken: _token, amount: _amount
        });

        return IOutlandConnector(_connector).getSendTokensFee(_targetChainId, _token, _amount, abi.encode(payload));
    }

    function getMessageFee(uint256 _targetChainId, uint256 _amount, address payable _connector)
        external
        view
        returns (uint256)
    {
        AssetsUpdatePayload memory payload =
            AssetsUpdatePayload({selector: OutlandMsgCodec.MESSAGE, chainId: chainId, totalAssetsValue: _amount});

        return IOutlandConnector(_connector).getMessageFee(_targetChainId, abi.encode(payload));
    }

    /// @notice Add a new authorized connector
    /// @dev Reverts if the address is zero or already exists in the set
    /// @param _connector The address of the connector to add
    function addConnector(address _connector) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(_connector != address(0), ZeroAddress());
        require(connectors.add(_connector), DuplicateEntry(_connector));
        emit ConnectorAdded(block.timestamp, _connector);
    }

    /// @notice Remove an authorized connector
    /// @dev Can only be called by PROTOCOL_PARAMETERS role
    /// @dev Reverts if the address is not found in the set
    /// @param _connector The address of the connector to remove
    function removeConnector(address _connector) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(connectors.remove(_connector), EntryNotFound(_connector));
        emit ConnectorRemoved(block.timestamp, _connector);
    }

    /// @notice Check if an address is an authorized connector
    /// @param _connector The address to check
    /// @return True if the address is an authorized connector
    function isConnector(address _connector) public view returns (bool) {
        return connectors.contains(_connector);
    }

    /// @notice Get all authorized connectors
    /// @return Array of all authorized connectors
    function getConnectors() public view returns (address[] memory) {
        return connectors.values();
    }

    /// @notice Get the number of authorized connectors
    /// @return The count of authorized connectors
    function getConnectorsCount() public view returns (uint256) {
        return connectors.length();
    }
}
