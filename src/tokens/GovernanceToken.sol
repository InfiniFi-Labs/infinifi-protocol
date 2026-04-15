// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OFTCore} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTCore.sol";
import {Ownable} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/OAppCore.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {CoreControlled} from "@core/CoreControlled.sol";

/// @notice InfiniFi Governance Token.
/// This contract is meant to be used for INFI & wINFI tokens.
/// @dev /!\ This contract is initially owned by the deployer, and the deployer is set as the OApp delegate,
/// to enable easier initial configuration. Make sure to transfer the privileges before enabling it in the protocol.
/// This can be checked by reading this.owner() and this.endpoint().delegates(this).
contract GovernanceToken is CoreControlled, ERC20Burnable, ERC20Votes, OFTCore {
    bytes32 private immutable _MINTER_ROLE;
    bytes32 private immutable _BURNER_ROLE;

    struct TokenConfig {
        string name;
        string symbol;
        bytes32 minterRole;
        bytes32 burnerRole;
    }

    /// @dev Escrow of tokens that have been bridged to other chains through OFT logic.
    /// This escrow only exists on the L1. It is meant to allow a representative totalSupply()
    /// on the L1, and contains bridge attacks to the part of the supply that has been bridged.
    address public immutable escrow = address(uint160(uint256(keccak256("escrow"))));

    constructor(address _core, TokenConfig memory _config, address _lzEndpoint)
        CoreControlled(_core)
        ERC20(_config.name, _config.symbol)
        EIP712(_config.name, "1")
        OFTCore(decimals(), _lzEndpoint, msg.sender)
        Ownable(msg.sender)
    {
        _MINTER_ROLE = _config.minterRole;
        _BURNER_ROLE = _config.burnerRole;
    }

    function mint(address _to, uint256 _amount) external onlyCoreRole(_MINTER_ROLE) {
        // only allow minting on L1, the supply shall be created on L1 and then
        // bridged to L2s through the OFT logic.
        require(block.chainid == 1);
        _mint(_to, _amount);
    }

    function burn(uint256 _value) public override onlyCoreRole(_BURNER_ROLE) {
        _burn(_msgSender(), _value);
    }

    function burnFrom(address _account, uint256 _value) public override onlyCoreRole(_BURNER_ROLE) {
        _spendAllowance(_account, _msgSender(), _value);
        _burn(_account, _value);
    }

    function _update(address _from, address _to, uint256 _value) internal override(ERC20, ERC20Votes) {
        return ERC20Votes._update(_from, _to, _value);
    }

    // ERC-6372 time-based checkpoints.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // ERC-6372 time-based checkpoints.
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    // OFT function
    function token() public view returns (address) {
        return address(this);
    }

    // OFT function
    function approvalRequired() external pure virtual returns (bool) {
        return false;
    }

    // OFT function: bridge out
    function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // bridging L1->L2 sends tokens to the escrow
        // bridging L2->L1 burns the tokens on the L2
        if (block.chainid == 1) {
            _update(_from, escrow, amountSentLD);
        } else {
            _burn(_from, amountSentLD);
        }
    }

    // OFT function: bridge in
    function _credit(
        address _to,
        uint256 _amount,
        uint32 /*_srcEid*/
    )
        internal
        virtual
        override
        returns (uint256)
    {
        // can't mint to address(0)
        if (_to == address(0x0)) _to = address(this);

        // bridging L2->L1 sends tokens from escrow to the recipient
        // bridging L1->L2 mints new tokens on the L2
        if (block.chainid == 1) {
            _update(escrow, _to, _amount);
        } else {
            _mint(_to, _amount);
        }
        return _amount;
    }
}
