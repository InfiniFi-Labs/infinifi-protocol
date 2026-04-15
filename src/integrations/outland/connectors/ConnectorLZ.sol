// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {OApp} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OApp.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IOFT, OFTReceipt, SendParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ConnectorBase} from "@integrations/outland/connectors/ConnectorBase.sol";
import {IOutlandPortal} from "@interfaces/IOutlandPortal.sol";

/// @title ConnectorLZ
/// @notice LayerZero connector capable of sending and receiving
/// @dev works with individual OFTs and serves as an OApp as well
contract ConnectorLZ is ConnectorBase, OApp {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    error NoOFT(address _asset);
    error InvalidMethod();

    event OFTSet(uint256 timestamp, address indexed assetToken, address indexed oft);
    event OFTDisabled(uint256 timestamp, address indexed assetToken);
    event MessageFailed(uint256 indexed timestamp, bytes message, bytes reason);
    event MessageDelivered(uint256 indexed timestamp, bytes message);
    event MessagingReceiptIssued(uint256 indexed timestamp, MessagingReceipt msgReceipt, OFTReceipt oftReceipt);

    /// @notice supports oft adapters, cases when token was not originally an OFT and external adapter exists for it
    /// @dev case like this is USDe on mainnet, token address and oft address are different while on other chains they are the same
    mapping(address assetToken => address oft) public ofts;

    constructor(address _core, address _portal, address _endpoint, address _owner)
        OApp(_endpoint, _owner)
        Ownable(_owner)
        ConnectorBase(_core, _portal)
    {}

    /// Not allowing this one to modify the state and enforcing the `setConfiguration`
    function setPeer(uint32, bytes32) public view override onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        revert InvalidMethod();
    }

    function setConfiguration(uint256 _chainId, address _peer, uint256 _selector, uint256 _gasLimit)
        external
        override
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        _setConfiguration(_chainId, _peer, _selector, _gasLimit);
        _setPeer(uint32(_selector), OFTComposeMsgCodec.addressToBytes32(_peer));
    }

    function enableOFT(address _assetToken, address _oft) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        ofts[_assetToken] = _oft;
        emit OFTSet(block.timestamp, _assetToken, _oft);
    }

    function disableOFT(address _assetToken) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        delete ofts[_assetToken];
        emit OFTDisabled(block.timestamp, _assetToken);
    }

    function getMessageFee(uint256 _chainId, bytes calldata _data) public view override returns (uint256) {
        Configuration memory _config = chainConfig[_chainId];
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(_config.gasLimit), 0);
        MessagingFee memory fees = _quote(uint32(_config.chainSelector), _data, options, false);
        return fees.nativeFee;
    }

    function getSendTokensFee(uint256 _chainId, address _assetToken, uint256 _amount, bytes calldata _data)
        external
        view
        override
        returns (uint256)
    {
        Configuration memory _config = chainConfig[_chainId];
        bytes32 peer = _getPeerOrRevert(uint32(_config.chainSelector));

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(_config.gasLimit), 0)
            .addExecutorLzComposeOption(0, uint128(_config.gasLimit), 0);

        SendParam memory sendParam = SendParam({
            dstEid: uint32(_config.chainSelector),
            to: peer,
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: options,
            composeMsg: _data,
            oftCmd: hex""
        });

        MessagingFee memory fee = IOFT(ofts[_assetToken]).quoteSend(sendParam, false);
        return fee.nativeFee;
    }

    function sendTokens(uint256 _chainId, address _assetToken, uint256 _amount, bytes calldata _data)
        external
        payable
        override
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_PORTAL)
    {
        Configuration memory _config = chainConfig[_chainId];
        bytes32 peer = _getPeerOrRevert(uint32(_config.chainSelector));

        require(ofts[_assetToken] != address(0), NoOFT(_assetToken));
        require(isAssetSupported(_chainId, _assetToken), AssetNotSupported(_assetToken));

        IERC20(_assetToken).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(_assetToken).forceApprove(address(ofts[_assetToken]), _amount);

        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(_config.gasLimit), 0)
            .addExecutorLzComposeOption(0, uint128(_config.gasLimit), 0);

        SendParam memory sendParam = SendParam({
            dstEid: uint32(_config.chainSelector),
            to: peer,
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: options,
            composeMsg: _data,
            oftCmd: hex""
        });

        MessagingFee memory fee = IOFT(ofts[_assetToken]).quoteSend(sendParam, false);
        require(address(this).balance >= fee.nativeFee, NotEnoughBalance(address(this).balance, fee.nativeFee));

        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) =
            IOFT(ofts[_assetToken]).send{value: fee.nativeFee}(sendParam, fee, address(this));

        emit MessagingReceiptIssued(block.timestamp, msgReceipt, oftReceipt);
    }

    function sendMessage(uint256 _chainId, bytes calldata _data)
        external
        payable
        override
        whenNotPaused
        onlyCoreRole(CoreRoles.OUTLAND_PORTAL)
    {
        Configuration memory _config = chainConfig[_chainId];
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(_config.gasLimit), 0);

        MessagingFee memory fees = _quote(uint32(_config.chainSelector), _data, options, false);
        require(address(this).balance >= fees.nativeFee, NotEnoughBalance(address(this).balance, fees.nativeFee));

        MessagingReceipt memory receipt = endpoint.send{value: fees.nativeFee}(
            MessagingParams({
                dstEid: uint32(_config.chainSelector),
                receiver: _getPeerOrRevert(uint32(_config.chainSelector)),
                message: _data,
                options: options,
                payInLzToken: false
            }),
            address(this)
        );

        emit MessageSent({
            timestamp: block.timestamp,
            messageId: receipt.guid,
            chainId: _chainId,
            fee: fees.nativeFee,
            receiver: _config.peer,
            messageData: _data
        });
    }

    /// @notice lzReceive _message does not contain additional data as compose, it can be decoded using our codec
    /// @dev leaving these unused variables because LZ docs suggests we do it
    function _lzReceive(Origin calldata _origin, bytes32, bytes calldata _message, address, bytes calldata)
        internal
        override
        whenNotPaused
    {
        uint256 chainId = selectorConfig[uint256(_origin.srcEid)].chainSelector;

        try IOutlandPortal(portal).receiveMessage(chainId, _message) {
            emit MessageDelivered(block.timestamp, _message);
        } catch (bytes memory _reason) {
            emit MessageFailed(block.timestamp, _message, _reason);
        }
    }

    /// @notice lzCompose has a custom codec, and OFTComposeMsgCodec library is used to decode it
    function lzCompose(address, bytes32, bytes calldata _message, address, bytes calldata)
        external
        payable
        whenNotPaused
    {
        require(msg.sender == address(endpoint), OnlyEndpoint(msg.sender));

        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes32 peer = peers[srcEid];
        if (peer != OFTComposeMsgCodec.composeFrom(_message)) {
            emit MessageFailed(block.timestamp, _message, "Peer is not equal to the sender");
            return;
        }

        uint256 chainId = selectorConfig[uint256(srcEid)].chainSelector;
        try IOutlandPortal(portal).receiveMessage(chainId, OFTComposeMsgCodec.composeMsg(_message)) {
            emit MessageDelivered(block.timestamp, _message);
        } catch (bytes memory _reason) {
            emit MessageFailed(block.timestamp, _message, _reason);
        }
    }
}
