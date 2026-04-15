// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IERC7540} from "@interfaces/IERC7540.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {GatewayLib} from "@libraries/GatewayLib.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {IInfiniFiGateway} from "@interfaces/IInfiniFiGateway.sol";

// follow erc7540 pattern.
abstract contract ERC7540 is CoreControlled, IERC7540 {
    using SafeERC20 for IERC20;
    using GatewayLib for IInfiniFiGateway;
    using EnumerableSet for EnumerableSet.UintSet;
    using FixedPointMathLib for uint256;

    error NotOperator(address _owner, address _operator);
    error NotWhitelisted(address _sender);

    event WhitelistSet(address _address, bool _whitelisted);
    event OperatorSet(uint256 indexed timestamp, address controller, address operator, bool approved);
    event DepositRequest(uint256 indexed timestamp, address controller, address owner, uint256 assets);
    event RedeemRequest(uint256 indexed timestamp, address controller, address owner, uint256 shares);
    event Mint(uint256 indexed timestamp, address controller, address receiver, uint256 assets, uint256 shares);
    event Deposit(uint256 indexed timestamp, address controller, address receiver, uint256 assets, uint256 shares);
    event Redeem(uint256 indexed timestamp, address controller, address receiver, uint256 assets, uint256 shares);
    event Withdraw(uint256 indexed timestamp, address controller, address receiver, uint256 assets, uint256 shares);

    bytes4 public constant ERC7540_OPERATOR_ID = 0xe3bc4e65;
    // @notice EIP-7575 interface id
    bytes4 public constant ERC7540_7575_ID = 0x2f0a18c5;

    address public immutable asset;
    address public immutable share;
    IInfiniFiGateway public immutable gateway;

    mapping(address owner => bool isWhitelisted) public whitelist;
    mapping(address controller => uint256 amount) public deposits;
    mapping(address controller => mapping(address operator => bool enabled)) public operators;

    constructor(address _core, address _gateway, address _assetToken, address _share) CoreControlled(_core) {
        gateway = IInfiniFiGateway(_gateway);
        asset = _assetToken;
        share = _share;
    }

    modifier onlyOperatorOrOwner(address _controller) {
        require(msg.sender == _controller || operators[_controller][msg.sender], NotOperator(_controller, msg.sender));
        _;
    }

    modifier onlyWhitelisted() {
        require(whitelist[msg.sender], NotWhitelisted(msg.sender));
        _;
    }

    function setWhitelist(address _address, bool _whitelisted) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        whitelist[_address] = _whitelisted;
        emit WhitelistSet(_address, _whitelisted);
    }

    function setOperator(address _operator, bool _approved) external onlyWhitelisted returns (bool) {
        operators[msg.sender][_operator] = _approved;
        emit OperatorSet(block.timestamp, msg.sender, _operator, _approved);
        return true;
    }

    function isOperator(address _controller, address _operator) public view returns (bool) {
        return operators[_controller][_operator];
    }

    function supportsInterface(bytes4 _interfaceID) external pure returns (bool) {
        return _interfaceID == ERC7540_7575_ID || _interfaceID == ERC7540_OPERATOR_ID;
    }

    function balanceOf(address _owner) public view returns (uint256) {
        return IERC20(share).balanceOf(_owner);
    }

    function totalSupply() public view returns (uint256) {
        return IERC20(share).totalSupply();
    }

    function totalAssets() public view returns (uint256) {
        return convertToAssets(IERC20(share).totalSupply());
    }

    function pendingDepositRequest(uint256, address) public pure returns (uint256 assets) {
        return 0;
    }

    function claimableDepositRequest(uint256, address _controller) public view returns (uint256 assets) {
        return deposits[_controller];
    }

    function maxDeposit(address _receiver) public view returns (uint256) {
        return claimableDepositRequest(0, _receiver);
    }

    function maxMint(address _receiver) public view returns (uint256) {
        return convertToShares(maxDeposit(_receiver));
    }

    function maxWithdraw(address _receiver) public view returns (uint256) {
        return convertToAssets(maxRedeem(_receiver));
    }

    function maxRedeem(address _receiver) public view returns (uint256) {
        return claimableRedeemRequest(0, _receiver);
    }

    function requestDeposit(uint256 _assets, address _controller, address _owner)
        external
        whenNotPaused
        onlyWhitelisted
        onlyOperatorOrOwner(_controller)
        returns (uint256 requestId)
    {
        if (_controller != _owner) {
            require(isOperator(_owner, _controller), NotOperator(_owner, _controller));
        }

        deposits[_controller] += _assets;
        IERC20(asset).safeTransferFrom(_owner, address(this), _assets);
        emit DepositRequest(block.timestamp, _controller, _owner, _assets);
        return 0;
    }

    function deposit(uint256 _assets, address _receiver, address _controller)
        external
        whenNotPaused
        onlyWhitelisted
        onlyOperatorOrOwner(_controller)
        returns (uint256 shares)
    {
        shares = _deposit(_assets, _receiver, _controller);
        emit Deposit(block.timestamp, _controller, _receiver, _assets, shares);
    }

    function mint(uint256 _shares, address _receiver, address _controller)
        external
        whenNotPaused
        onlyWhitelisted
        onlyOperatorOrOwner(_controller)
        returns (uint256 assets)
    {
        assets = convertToAssets(_shares);
        uint256 shares = _deposit(assets, _receiver, _controller);
        emit Mint(block.timestamp, _controller, _receiver, assets, shares);
    }

    function requestRedeem(uint256 _shares, address _controller, address _owner)
        external
        whenNotPaused
        onlyWhitelisted
        onlyOperatorOrOwner(_controller)
        returns (uint256 requestId)
    {
        if (_controller != _owner) {
            require(isOperator(_owner, _controller), NotOperator(_owner, _controller));
        }

        _requestRedeem(_shares, _controller, _owner);
        emit RedeemRequest(block.timestamp, _controller, _owner, _shares);
        return 0;
    }

    function withdraw(uint256 _assets, address _receiver, address _controller)
        external
        whenNotPaused
        onlyWhitelisted
        onlyOperatorOrOwner(_controller)
        returns (uint256 shares)
    {
        shares = _withdraw(_assets, _receiver, _controller);
        emit Withdraw(block.timestamp, _controller, _receiver, _assets, shares);
    }

    function redeem(uint256 _shares, address _receiver, address _controller)
        external
        whenNotPaused
        onlyWhitelisted
        onlyOperatorOrOwner(_controller)
        returns (uint256 assets)
    {
        assets = _redeem(_shares, _controller, _receiver);
        emit Redeem(block.timestamp, _controller, _receiver, assets, _shares);
    }

    /// Virtual methods

    function convertToShares(uint256 _assets) public view virtual returns (uint256);

    function convertToAssets(uint256 _shares) public view virtual returns (uint256);

    function pendingRedeemRequest(uint256, address _controller) public view virtual returns (uint256 shares);

    function claimableRedeemRequest(uint256, address _controller) public view virtual returns (uint256 shares);

    function _requestRedeem(uint256 _shares, address _controller, address _receiver) internal virtual returns (uint256);

    function _deposit(uint256 _assets, address _receiver, address _controller) internal virtual returns (uint256 shares);

    function _redeem(uint256 _shares, address _controller, address _receiver) internal virtual returns (uint256 assets);

    function _withdraw(uint256 _assets, address _receiver, address _controller)
        internal
        virtual
        returns (uint256 shares);
}
