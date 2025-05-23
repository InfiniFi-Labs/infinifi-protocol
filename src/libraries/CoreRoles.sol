// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Holds a complete list of all roles which can be held by contracts inside the InfiniFi protocol.
library CoreRoles {
    /// ----------- Core roles for access control --------------

    /// @notice the all-powerful role. Controls all other roles and protocol functionality.
    bytes32 internal constant GOVERNOR = keccak256("GOVERNOR");

    /// @notice Can pause contracts in an emergency.
    bytes32 internal constant PAUSE = keccak256("PAUSE");

    /// @notice Can unpause contracts after an emergency.
    bytes32 internal constant UNPAUSE = keccak256("UNPAUSE");

    /// @notice can tweak protocol parameters
    bytes32 internal constant PROTOCOL_PARAMETERS = keccak256("PROTOCOL_PARAMETERS");

    /// @notice can manage minor roles
    bytes32 internal constant MINOR_ROLES_MANAGER = keccak256("MINOR_ROLES_MANAGER");

    /// ----------- User Flow Management -----------------------

    /// @notice Granted to the user entry point of the system
    bytes32 internal constant ENTRY_POINT = keccak256("ENTRY_POINT");

    /// ----------- Token Management ---------------------------

    /// @notice can mint DebtToken arbitrarily
    bytes32 internal constant RECEIPT_TOKEN_MINTER = keccak256("RECEIPT_TOKEN_MINTER");

    /// @notice can burn DebtToken tokens
    bytes32 internal constant RECEIPT_TOKEN_BURNER = keccak256("RECEIPT_TOKEN_BURNER");

    /// @notice can mint arbitrarily & burn held LockedPositionToken
    bytes32 internal constant LOCKED_TOKEN_MANAGER = keccak256("LOCKED_TOKEN_MANAGER");

    /// @notice can prevent transfers of LockedPositionToken
    bytes32 internal constant TRANSFER_RESTRICTOR = keccak256("TRANSFER_RESTRICTOR");

    /// ----------- Funds Management & Accounting --------------

    /// @notice contract that can allocate funds between farms
    bytes32 internal constant FARM_MANAGER = keccak256("FARM_MANAGER");

    /// @notice addresses who can use the manual rebalancer
    bytes32 internal constant MANUAL_REBALANCER = keccak256("MANUAL_REBALANCER");

    /// @notice addresses who can use the periodic rebalancer
    bytes32 internal constant PERIODIC_REBALANCER = keccak256("PERIODIC_REBALANCER");

    /// @notice addresses who can move funds from farms to a safe address
    bytes32 internal constant EMERGENCY_WITHDRAWAL = keccak256("EMERGENCY_WITHDRAWAL");

    /// @notice addresses who can trigger swaps in Farms
    bytes32 internal constant FARM_SWAP_CALLER = keccak256("FARM_SWAP_CALLER");

    /// @notice can set oracles references within the system
    bytes32 internal constant ORACLE_MANAGER = keccak256("ORACLE_MANAGER");

    /// @notice trusted to report profit and losses in the system.
    /// This role can be used to slash depositors in case of losses, and
    /// can also deposit profits for distribution to end users.
    bytes32 internal constant FINANCE_MANAGER = keccak256("FINANCE_MANAGER");

    /// ----------- Timelock management ------------------------
    /// The hashes are the same as OpenZeppelins's roles in TimelockController

    /// @notice can propose new actions in timelocks
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");

    /// @notice can execute actions in timelocks after their delay
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice can cancel actions in timelocks
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
}
