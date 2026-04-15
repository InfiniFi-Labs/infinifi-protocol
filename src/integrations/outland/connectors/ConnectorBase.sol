// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {IOutlandPortal, IOutlandConnector} from "@interfaces/IOutlandPortal.sol";

abstract contract ConnectorBase is CoreControlled, IOutlandConnector {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    error NoGasLimit(uint256 _chainId);
    error MissingPeer(uint256 _chainId);
    error InvalidAmount(uint256 amount);
    error AssetNotSupported(address _asset);
    error NotEnoughBalance(uint256 balance, uint256 fees);

    event GovReceive(uint256 timestamp, uint256 chainId, bytes message);
    event AssetEnabled(uint256 timestamp, uint256 chainId, address indexed asset);
    event AssetDisabled(uint256 timestamp, uint256 chainId, address indexed asset);
    event ConfigurationSet(
        uint256 timestamp, uint256 chainId, address indexed peer, uint256 selector, uint256 gasLimit
    );

    struct Configuration {
        address peer;
        uint128 gasLimit;
        uint128 chainSelector;
    }

    // Bidirectional configuration
    mapping(uint256 chainId => Configuration) public chainConfig;
    mapping(uint256 selector => Configuration) public selectorConfig;

    mapping(uint256 chainId => EnumerableSet.AddressSet assets) chainAssets;

    address public immutable portal;

    constructor(address _core, address _portal) CoreControlled(_core) {
        portal = _portal;
    }

    /// @notice Configures bidirectional relation between chain configs
    function setConfiguration(uint256 _chainId, address _peer, uint256 _selector, uint256 _gasLimit)
        external
        virtual
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        _setConfiguration(_chainId, _peer, _selector, _gasLimit);
    }

    /// @notice allows manual updates by the governance
    /// @dev should be gated behind 1 day timelock
    function govReceive(uint256 _chainId, bytes calldata _message)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        IOutlandPortal(portal).receiveMessage(_chainId, _message);
        emit GovReceive(block.timestamp, _chainId, _message);
    }

    function enableChainAsset(uint256 _chainId, address _chainAsset)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        chainAssets[_chainId].add(_chainAsset);
        emit AssetEnabled(block.timestamp, _chainId, _chainAsset);
    }

    function disableChainAsset(uint256 _chainId, address _chainAsset)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        chainAssets[_chainId].remove(_chainAsset);
        emit AssetDisabled(block.timestamp, _chainId, _chainAsset);
    }

    function pullAssets(address _assetToken, uint256 _amount) external onlyCoreRole(CoreRoles.OUTLAND_PORTAL) {
        uint256 balance = IERC20(_assetToken).balanceOf(address(this));
        require(_amount <= balance, InvalidAmount(_amount));
        IERC20(_assetToken).safeTransfer(portal, _amount);
    }

    function getEnabledAssets(uint256 _chainId) public view returns (address[] memory) {
        return chainAssets[_chainId].values();
    }

    function isAssetSupported(uint256 _chainId, address _asset) public view returns (bool) {
        return chainAssets[_chainId].contains(_asset);
    }

    /// @notice Configures bidirectional relation between chain configs
    function _setConfiguration(uint256 _chainId, address _peer, uint256 _selector, uint256 _gasLimit) internal {
        Configuration memory _config =
            Configuration({peer: _peer, gasLimit: uint128(_gasLimit), chainSelector: uint128(_selector)});
        chainConfig[_chainId] = _config;

        // forge-lint: disable-next-line(unsafe-typecast)
        _config.chainSelector = uint128(_chainId);
        selectorConfig[_selector] = _config;
        emit ConfigurationSet(block.timestamp, _chainId, _peer, _selector, _gasLimit);
    }

    /// @notice Needs to be payable to receive ETH for CCIP Gas Fees
    receive() external payable {}

    fallback() external payable {}
}
