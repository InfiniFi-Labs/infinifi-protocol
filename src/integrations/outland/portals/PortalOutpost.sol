// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {MultiAssetFarmV2} from "@integrations/MultiAssetFarmV2.sol";

import {PortalBase} from "@integrations/outland/portals/PortalBase.sol";
import {OutlandMsgCodec} from "@integrations/outland/OutlandMsgCodec.sol";
import {IOutlandConnector} from "@interfaces/IOutlandPortal.sol";

/// @title PortalOutpost
/// @notice Outpost portal contract on L2 chains for managing cross-chain farm operations
/// @dev Handles token transfers from farms to the hub and receives tokens from the hub
contract PortalOutpost is PortalBase {
    using SafeERC20 for ERC20;

    error InvalidFarm(address _farm);
    error InvalidToken(address _token);

    event ReceiverFarmSet(uint256 indexed timestamp, uint256 chainId, address indexed receiverFarm);
    event AssetsUpdateSent(uint256 indexed timestamp, uint256 chainId, uint256 totalAssets, address sender);

    /// @notice Determines on which chain is the hub of this outpost
    uint256 public hubChainId;

    /// @notice The accounting contract for tracking total assets
    Accounting public accounting;

    /// @notice The farm registry for validating farm addresses
    FarmRegistry public farmRegistry;

    /// @notice The farm that receives tokens from the hub
    address public receiverFarm;

    constructor() PortalBase(address(1), 1) {}

    /// @notice Initializes the PortalOutpost contract
    /// @param _core Address of the Core contract for role management
    /// @param _chainId Chain ID where this portal operates
    /// @param _accounting Accounting contract address
    /// @param _farmRegistry Farm registry contract address
    /// @param _receiverFarm Initial receiver farm address
    function init(
        address _core,
        uint256 _chainId,
        uint256 _hubChainId,
        address _accounting,
        address _farmRegistry,
        address _receiverFarm
    ) external {
        require(address(core()) == address(0), AlreadyInitialized());
        chainId = _chainId;
        hubChainId = _hubChainId;
        accounting = Accounting(_accounting);
        farmRegistry = FarmRegistry(_farmRegistry);
        receiverFarm = _receiverFarm;
        _setCore(_core);
    }

    /// ============================================================
    /// Farm Management
    /// ============================================================

    /// @notice Sets the farm that receives tokens from the hub
    /// @dev Can only be called by PROTOCOL_PARAMETERS role
    /// @dev Validates that the farm is registered and uses the correct asset token
    /// @param _newReceiverFarm Address of the farm to receive tokens
    function setReceiverFarm(address _newReceiverFarm) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require(farmRegistry.isFarm(_newReceiverFarm), InvalidFarm(_newReceiverFarm));
        receiverFarm = _newReceiverFarm;
        emit ReceiverFarmSet(block.timestamp, chainId, _newReceiverFarm);
    }

    /// ============================================================
    /// Sender side
    /// ============================================================

    /// @notice Sends tokens from a farm on this chain to the hub on mainnet
    /// @dev Withdraws tokens from the farm, approves sender, and initiates cross-chain transfer
    /// @dev Can only be called by OUTLAND_KEEPER role
    /// @param _farm The farm address from which to withdraw tokens
    /// @param _token The token address to send
    /// @param _amount The amount of tokens to send
    /// @param _connector The authorized connector
    function sendTokens(address _farm, address _token, uint256 _amount, address payable _connector)
        external
        payable
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_KEEPER)
    {
        require(_amount > 0, InvalidAmount(_amount));
        require(farmRegistry.isFarm(_farm), InvalidFarm(_farm));
        require(MultiAssetFarmV2(_farm).isAssetSupported(_token), InvalidToken(_token));
        require(isConnector(_connector), InvalidSender(_connector));

        TransferPayload memory payload = TransferPayload({
            selector: OutlandMsgCodec.TRANSFER, chainId: chainId, assetToken: _token, amount: _amount
        });

        if (MultiAssetFarmV2(_farm).assetToken() == _token) {
            MultiAssetFarmV2(_farm).withdraw(_amount, address(this));
        } else {
            MultiAssetFarmV2(_farm).withdrawSecondaryAsset(_token, _amount, address(this));
        }

        ERC20(_token).forceApprove(_connector, _amount);
        IOutlandConnector(_connector).sendTokens{value: msg.value}(hubChainId, _token, _amount, abi.encode(payload));

        emit TokensSent(block.timestamp, hubChainId, _token, _amount, _connector);
    }

    /// @notice Sends an assets update message to the hub with the current total assets
    /// @dev Queries the accounting contract for total assets and sends update to mainnet
    /// @dev Can only be called by OUTLAND_KEEPER role
    /// @param _connector The authorized connector
    function sendAssetsUpdate(address payable _connector)
        external
        payable
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_KEEPER)
    {
        require(isConnector(_connector), InvalidSender(_connector));

        AssetsUpdatePayload memory payload = AssetsUpdatePayload({
            selector: OutlandMsgCodec.MESSAGE, chainId: chainId, totalAssetsValue: accounting.totalAssetsValue()
        });

        IOutlandConnector(_connector).sendMessage{value: msg.value}(hubChainId, abi.encode(payload));

        emit AssetsUpdateSent(block.timestamp, hubChainId, payload.totalAssetsValue, _connector);
    }

    /// ============================================================
    /// Receiver side
    /// ============================================================

    /// @notice Receives and processes cross-chain messages from the hub
    /// @dev Validates the sender, decodes message type, and routes to appropriate handler
    /// @dev Can only be called by authorized message receivers
    /// @dev Only accepts messages from Ethereum mainnet
    /// @param _chainId The source chain ID (must be mainnet)
    /// @param _data Encoded message data containing message type, chainId, and payload
    function receiveMessage(uint256 _chainId, bytes calldata _data) external whenNotPaused {
        require(isConnector(msg.sender), InvalidSender(msg.sender));

        bytes1 messageType = OutlandMsgCodec.getMessageType(_data);
        uint256 senderChainId = OutlandMsgCodec.getChainId(_data);

        require(_chainId == senderChainId, ChainNotSupported(_chainId));
        require(senderChainId == hubChainId, ChainNotSupported(_chainId));

        if (messageType == OutlandMsgCodec.TRANSFER) {
            (address token, uint256 amount) = OutlandMsgCodec.getTransferPayload(_data);
            _handleReceiveTokenTransfer(msg.sender, token, amount);
        }
    }

    /// @notice Internal handler for receiving token transfers from the hub
    /// @dev Pulls assets from receiver and transfers them to the receiver farm
    /// @param _receiver The message receiver contract that holds the tokens
    /// @param _token The token address to receive
    /// @param _amount The amount of tokens to receive
    function _handleReceiveTokenTransfer(address _receiver, address _token, uint256 _amount) internal {
        require(farmRegistry.isFarm(receiverFarm), InvalidFarm(receiverFarm));
        require(MultiAssetFarmV2(receiverFarm).isAssetSupported(_token), InvalidToken(_token));

        IOutlandConnector(_receiver).pullAssets(_token, _amount);
        ERC20(_token).safeTransfer(receiverFarm, _amount);

        emit TokensReceived(block.timestamp, hubChainId, _token, _amount, receiverFarm);
    }
}
