// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {StakedToken} from "@tokens/StakedToken.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {MintController} from "@funding/MintController.sol";
import {RedeemController} from "@funding/RedeemController.sol";
import {AllocationVoting} from "@governance/AllocationVoting.sol";
import {LockingController} from "@locking/LockingController.sol";
import {LockedPositionToken} from "@tokens/LockedPositionToken.sol";

/// @notice Gateway to interact with the InfiniFi protocol
contract InfiniFiGatewayV1 is CoreControlled {
    using SafeERC20 for ERC20;

    /// @notice address registry of the gateway
    mapping(bytes32 => address) public addresses;

    constructor() CoreControlled(address(1)) {}

    /// @notice initializer for the proxy storage
    function init(address _core) external {
        assert(address(core()) == address(0));
        _setCore(_core);
    }

    /// -------------------------------------------------------------------------------------
    /// Configuration
    /// -------------------------------------------------------------------------------------

    /// @notice set an address for a given name
    function setAddress(string memory _name, address _address) external onlyCoreRole(CoreRoles.GOVERNOR) {
        addresses[keccak256(abi.encode(_name))] = _address;
    }

    /// @notice get an address for a given name
    function getAddress(string memory _name) public view returns (address) {
        return addresses[keccak256(abi.encode(_name))];
    }

    /// -------------------------------------------------------------------------------------
    /// User interactions
    /// -------------------------------------------------------------------------------------

    function mint(address _to, uint256 _amount) external whenNotPaused returns (uint256) {
        ERC20 usdc = ERC20(getAddress("USDC"));
        MintController mintController = MintController(getAddress("mintController"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        return mintController.mint(_to, _amount, true);
    }

    function mintAndStake(address _to, uint256 _amount) external whenNotPaused returns (uint256) {
        MintController mintController = MintController(getAddress("mintController"));
        StakedToken siusd = StakedToken(getAddress("stakedToken"));
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        ERC20 usdc = ERC20(getAddress("USDC"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        uint256 receiptTokens = mintController.mint(address(this), _amount, false);

        iusd.approve(address(siusd), receiptTokens);
        siusd.deposit(receiptTokens, _to);
        siusd.restrictActionUntil(_to, block.timestamp + mintController.restrictionDuration());
        return receiptTokens;
    }

    function mintAndLock(address _to, uint256 _amount, uint32 _unwindingEpochs) external whenNotPaused {
        MintController mintController = MintController(getAddress("mintController"));
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        LockingController lockingController = LockingController(getAddress("lockingController"));
        ERC20 usdc = ERC20(getAddress("USDC"));

        usdc.safeTransferFrom(msg.sender, address(this), _amount);
        usdc.approve(address(mintController), _amount);
        uint256 receiptTokens = mintController.mint(address(this), _amount, false);

        iusd.approve(address(lockingController), receiptTokens);
        lockingController.createPosition(receiptTokens, _unwindingEpochs, _to);
    }

    function createPosition(uint256 _amount, uint32 _unwindingEpochs, address _recipient) external whenNotPaused {
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        LockingController lockingController = LockingController(getAddress("lockingController"));

        iusd.transferFrom(msg.sender, address(this), _amount);
        iusd.approve(address(lockingController), _amount);
        lockingController.createPosition(_amount, _unwindingEpochs, _recipient);
    }

    function startUnwinding(uint256 _shares, uint32 _unwindingEpochs) external whenNotPaused {
        LockingController lockingController = LockingController(getAddress("lockingController"));
        LockedPositionToken liusd = LockedPositionToken(lockingController.shareToken(_unwindingEpochs));

        liusd.transferFrom(msg.sender, address(this), _shares);
        liusd.approve(address(lockingController), _shares);
        lockingController.startUnwinding(_shares, _unwindingEpochs, msg.sender);
    }

    function increaseUnwindingEpochs(uint32 _oldUnwindingEpochs, uint32 _newUnwindingEpochs) external whenNotPaused {
        LockingController lockingController = LockingController(getAddress("lockingController"));
        LockedPositionToken liusd = LockedPositionToken(lockingController.shareToken(_oldUnwindingEpochs));

        uint256 shares = liusd.balanceOf(msg.sender);
        liusd.transferFrom(msg.sender, address(this), shares);
        liusd.approve(address(lockingController), shares);
        lockingController.increaseUnwindingEpochs(_oldUnwindingEpochs, _newUnwindingEpochs, msg.sender);
    }

    function cancelUnwinding(uint256 _unwindingTimestamp, uint32 _newUnwindingEpochs) external whenNotPaused {
        LockingController(getAddress("lockingController")).cancelUnwinding(
            msg.sender, _unwindingTimestamp, _newUnwindingEpochs
        );
    }

    function withdraw(uint256 _unwindingTimestamp) external whenNotPaused {
        LockingController(getAddress("lockingController")).withdraw(msg.sender, _unwindingTimestamp);
    }

    function redeem(address _to, uint256 _amount) external whenNotPaused returns (uint256) {
        ReceiptToken iusd = ReceiptToken(getAddress("receiptToken"));
        RedeemController redeemController = RedeemController(getAddress("redeemController"));

        iusd.transferFrom(msg.sender, address(this), _amount);
        iusd.approve(address(redeemController), _amount);
        return redeemController.redeem(_to, _amount);
    }

    function claimRedemption() external whenNotPaused {
        RedeemController(getAddress("redeemController")).claimRedemption(msg.sender);
    }

    function vote(
        address _asset,
        uint32 _unwindingEpochs,
        AllocationVoting.AllocationVote[] calldata _liquidVotes,
        AllocationVoting.AllocationVote[] calldata _illiquidVotes
    ) external whenNotPaused {
        AllocationVoting(getAddress("allocationVoting")).vote(
            msg.sender, _asset, _unwindingEpochs, _liquidVotes, _illiquidVotes
        );
    }
}
