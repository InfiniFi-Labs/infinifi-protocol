// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IOutlandPortal {
    struct TransferPayload {
        bytes1 selector;
        uint256 chainId;
        address assetToken;
        uint256 amount;
    }

    struct AssetsUpdatePayload {
        bytes1 selector;
        uint256 chainId;
        uint256 totalAssetsValue;
    }

    function receiveMessage(uint256 _chainId, bytes calldata _data) external;
}

interface IOutlandConnector {
    event TokensSent(
        uint256 indexed timestamp,
        bytes32 messageId,
        uint256 chainId,
        address assetToken,
        uint256 amount,
        uint256 fee,
        address receiver,
        bytes messageData
    );

    event MessageSent(
        uint256 indexed timestamp, bytes32 messageId, uint256 chainId, uint256 fee, address receiver, bytes messageData
    );

    function getMessageFee(uint256 _chainId, bytes calldata _data) external view returns (uint256);

    function getSendTokensFee(uint256 _chainId, address _assetToken, uint256 _amount, bytes calldata _data)
        external
        view
        returns (uint256);

    function sendMessage(uint256 _chainId, bytes calldata _data) external payable;

    function sendTokens(uint256 _chainId, address _assetToken, uint256 _amount, bytes calldata _data) external payable;

    function pullAssets(address _assetToken, uint256 _amount) external;
}
