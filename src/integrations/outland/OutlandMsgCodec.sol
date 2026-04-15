// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title OutlandMsgCodec
/// @notice Utility library for decoding cross-chain messages and payloads in the Outland system
/// @dev Provides constants and functions for parsing portal messages
library OutlandMsgCodec {
    error InvalidSize(uint256 _size);

    /// @notice Transport type identifier for general messages
    /// @dev Used as a selector byte in cross-chain message payloads
    bytes1 internal constant MESSAGE = hex"00";

    /// @notice Transport type identifier for token transfers
    /// @dev Used as a selector byte in cross-chain transfer payloads
    bytes1 internal constant TRANSFER = hex"01";

    /// @notice Gets the message type from cross-chain message data
    /// @dev Expects data to be at least 32 bytes for the message type
    /// @param _data The encoded message data
    /// @return messageType The message type identifier (MESSAGE or TRANSFER)
    function getMessageType(bytes calldata _data) internal pure returns (bytes1 messageType) {
        require(_data.length > 32, InvalidSize(_data.length));
        messageType = bytes1(_data[:32]);
    }

    /// @notice Gets the chain ID from cross-chain message data
    /// @dev Expects data to be at least 64 bytes: 32 bytes message type + 32 bytes chain ID
    /// @param _data The encoded message data
    /// @return chainId The target or source chain ID
    function getChainId(bytes calldata _data) internal pure returns (uint256 chainId) {
        require(_data.length > 64, InvalidSize(_data.length));
        chainId = uint256(bytes32(_data[32:64]));
    }

    /// @notice Gets the transfer payload (recipient and amount) from cross-chain data
    /// @dev Extracts ABI-encoded address and uint256 from data after the first 64 bytes
    /// @param _data The encoded message data containing transfer information
    /// @return Recipient address for the transfer
    /// @return Amount of tokens to transfer
    function getTransferPayload(bytes calldata _data) internal pure returns (address, uint256) {
        require(_data.length > 64, InvalidSize(_data.length));
        return abi.decode(_data[64:], (address, uint256));
    }

    /// @notice Gets the assets update payload (token address and amount) from cross-chain data
    /// @dev Extracts ABI-encoded address and uint256 from data after the first 64 bytes
    /// @param _data The encoded message data containing asset update information
    /// @return New total assets value
    function getAssetsUpdatePayload(bytes calldata _data) internal pure returns (uint256) {
        require(_data.length > 64, InvalidSize(_data.length));
        return abi.decode(_data[64:], (uint256));
    }
}
