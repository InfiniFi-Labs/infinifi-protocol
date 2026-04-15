// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAny2EVMMessageReceiver} from "@chainlink/contracts/interfaces/IAny2EVMMessageReceiver.sol";

import {Client} from "@chainlink/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts/interfaces/IRouterClient.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IOutlandPortal} from "@interfaces/IOutlandPortal.sol";

import {ConnectorBase} from "@integrations/outland/connectors/ConnectorBase.sol";

/// @title ConnectorCCIP
/// @notice Cross-chain communication contract using Chainlink
contract ConnectorCCIP is ConnectorBase, IAny2EVMMessageReceiver, IERC165 {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error InvalidRouter(address router);

    event MessageFailed(uint256 indexed timestamp, Client.Any2EVMMessage message, bytes reason);
    event MessageDelivered(uint256 indexed timestamp, Client.Any2EVMMessage message);

    IRouterClient public immutable router;

    constructor(address _core, address _portal, address _router) ConnectorBase(_core, _portal) {
        router = IRouterClient(_router);
    }

    /// @notice This makes it compatible with CCIP
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function getMessageFee(uint256 _chainId, bytes calldata _data) public view override returns (uint256) {
        Configuration memory _config = chainConfig[_chainId];
        Client.EVM2AnyMessage memory message =
            _buildCCIPMessage(_config.peer, _config.gasLimit, _createTokenAmount(address(0), 0), _data);
        return router.getFee(uint64(_config.chainSelector), message);
    }

    function getSendTokensFee(uint256 _chainId, address _assetToken, uint256 _amount, bytes calldata _data)
        external
        view
        override
        returns (uint256)
    {
        Configuration memory _config = chainConfig[_chainId];
        Client.EVM2AnyMessage memory message =
            _buildCCIPMessage(_config.peer, _config.gasLimit, _createTokenAmount(_assetToken, _amount), _data);
        return router.getFee(uint64(_config.chainSelector), message);
    }

    function sendMessage(uint256 _chainId, bytes calldata _data)
        external
        payable
        override
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_PORTAL)
    {
        Configuration memory _config = chainConfig[_chainId];

        require(_config.gasLimit != 0, NoGasLimit(_chainId));
        require(_config.peer != address(0), MissingPeer(_chainId));

        Client.EVM2AnyMessage memory message =
            _buildCCIPMessage(_config.peer, _config.gasLimit, _createTokenAmount(address(0), 0), _data);

        uint256 fees = router.getFee(uint64(_config.chainSelector), message);
        require(address(this).balance >= fees, NotEnoughBalance(address(this).balance, fees));

        bytes32 messageId = router.ccipSend{value: fees}(uint64(_config.chainSelector), message);

        emit MessageSent({
            timestamp: block.timestamp,
            messageId: messageId,
            chainId: _chainId,
            fee: fees,
            receiver: _config.peer,
            messageData: _data
        });
    }

    function sendTokens(uint256 _chainId, address _assetToken, uint256 _amount, bytes calldata _data)
        external
        payable
        override
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_PORTAL)
    {
        Configuration memory _config = chainConfig[_chainId];

        require(_config.gasLimit != 0, NoGasLimit(_chainId));
        require(_config.peer != address(0), MissingPeer(_chainId));
        require(chainAssets[_chainId].contains(_assetToken), AssetNotSupported(_assetToken));

        IERC20(_assetToken).safeTransferFrom(msg.sender, address(this), _amount);
        Client.EVM2AnyMessage memory message =
            _buildCCIPMessage(_config.peer, _config.gasLimit, _createTokenAmount(_assetToken, _amount), _data);

        uint256 fees = router.getFee(uint64(_config.chainSelector), message);
        require(address(this).balance >= fees, NotEnoughBalance(address(this).balance, fees));

        IERC20(_assetToken).forceApprove(address(router), _amount);
        bytes32 messageId = router.ccipSend{value: fees}(uint64(_config.chainSelector), message);

        emit TokensSent({
            timestamp: block.timestamp,
            messageId: messageId,
            chainId: _chainId,
            assetToken: _assetToken,
            amount: _amount,
            fee: fees,
            receiver: _config.peer,
            messageData: _data
        });
    }

    function _buildCCIPMessage(
        address _peer,
        uint256 _gasLimit,
        Client.EVMTokenAmount[] memory _tokenAmounts,
        bytes calldata _message
    ) private pure returns (Client.EVM2AnyMessage memory) {
        Client.GenericExtraArgsV2 memory extraArgs = Client.GenericExtraArgsV2({
            gasLimit: _gasLimit, // Gas limit for the callback on the destination chain
            allowOutOfOrderExecution: false // Allows the message to be executed out of order relative to other messages from the same sender
        });

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_peer),
            data: _message,
            tokenAmounts: _tokenAmounts,
            extraArgs: Client._argsToBytes(extraArgs),
            feeToken: address(0) // pay fees in native token
        });
    }

    /// @notice returns CCIP formatted token send payload
    /// @dev in case amount is 0, will return empty array
    function _createTokenAmount(address _assetToken, uint256 _amount)
        internal
        pure
        returns (Client.EVMTokenAmount[] memory)
    {
        if (_amount == 0) return new Client.EVMTokenAmount[](0);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: _assetToken, amount: _amount});

        return tokenAmounts;
    }

    function ccipReceive(Client.Any2EVMMessage calldata _message) external override whenNotPaused {
        require(msg.sender == address(router), InvalidRouter(msg.sender));

        uint256 senderChainId = selectorConfig[uint256(_message.sourceChainSelector)].chainSelector;
        if (senderChainId == 0) {
            emit MessageFailed(block.timestamp, _message, "Chain Id was not supported");
            return;
        }

        address _sender = abi.decode(_message.sender, (address));
        address peer = chainConfig[senderChainId].peer;
        if (peer != _sender) {
            emit MessageFailed(block.timestamp, _message, "Sender was unknown");
            return;
        }

        try IOutlandPortal(portal).receiveMessage(senderChainId, _message.data) {
            emit MessageDelivered(block.timestamp, _message);
        } catch (bytes memory _reason) {
            emit MessageFailed(block.timestamp, _message, _reason);
        }
    }
}
