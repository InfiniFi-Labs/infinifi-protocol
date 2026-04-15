// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {Accounting} from "@finance/Accounting.sol";
import {ERC4626Oracle} from "@finance/oracles/ERC4626Oracle.sol";
import {FixedPriceOracle} from "@finance/oracles/FixedPriceOracle.sol";
import {CoreControlled, CoreRoles} from "@core/CoreControlled.sol";

/// @notice Factory contract for deploying Oracle contracts for new assets without timelock
/// @dev This contract must have ORACLE_MANAGER role
/// @dev Can only create oracles for new assets, can not update
contract OracleFactory is CoreControlled {
    /// @notice Emitted when an oracle is deployed and registered
    event OracleDeployedAndRegistered(address indexed asset, address indexed oracle, bytes32 salt);

    /// @notice Reference to the Accounting contract
    Accounting public immutable accounting;

    error DeploymentFailed();
    error OracleAlreadyExists(address asset);
    error AssetOracleNotFound(address asset);

    constructor(address _core, address _accounting) CoreControlled(_core) {
        accounting = Accounting(_accounting);
    }

    /// @notice Deploys a FixedPriceOracle using CREATE2 and registers it with Accounting
    /// @param _asset The asset address to register the oracle for
    /// @param _price The fixed price for the oracle
    /// @param _salt The salt for deterministic address generation
    /// @return oracle The address of the deployed and registered oracle
    function deployFixedPriceOracle(address _asset, uint256 _price, bytes32 _salt)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER)
        returns (address oracle)
    {
        // Check if oracle already exists for this asset
        require(accounting.oracle(_asset) == address(0), OracleAlreadyExists(_asset));

        // Get creation code with constructor parameters
        bytes memory creationCode =
            abi.encodePacked(type(FixedPriceOracle).creationCode, abi.encode(address(core()), _price));

        // Deploy using CREATE2
        assembly {
            oracle := create2(0, add(creationCode, 0x20), mload(creationCode), _salt)
        }

        require(oracle != address(0), DeploymentFailed());
        // Register with Accounting
        accounting.setOracle(_asset, oracle);

        emit OracleDeployedAndRegistered(_asset, oracle, _salt);
    }

    /// @notice Deploys an ERC4626Oracle using CREATE2 and registers it with Accounting
    /// @param _vault The ERC4626 vault address
    /// @param _salt The salt for deterministic address generation
    /// @return oracle The address of the deployed and registered oracle
    function deployERC4626Oracle(address _vault, bytes32 _salt)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.MINOR_ROLES_MANAGER)
        returns (address oracle)
    {
        // Check if oracle already exists for this vault
        require(accounting.oracle(_vault) == address(0), OracleAlreadyExists(_vault));

        address assetOracle = accounting.oracle(ERC4626(_vault).asset());
        require(assetOracle != address(0), AssetOracleNotFound(assetOracle));

        // Get creation code with constructor parameters
        bytes memory creationCode = abi.encodePacked(type(ERC4626Oracle).creationCode, abi.encode(_vault, assetOracle));

        // Deploy using CREATE2
        assembly {
            oracle := create2(0, add(creationCode, 0x20), mload(creationCode), _salt)
        }

        require(oracle != address(0), DeploymentFailed());
        // Register with Accounting
        accounting.setOracle(_vault, oracle);

        emit OracleDeployedAndRegistered(_vault, oracle, _salt);
    }
}
