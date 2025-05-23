pragma solidity 0.8.28;

import {Vm} from "@forge-std/Vm.sol";
import {Test} from "@forge-std/Test.sol";

import {AddressStoreLib} from "@deployment/AddressStoreLib.sol";

import {Proposal_00} from "@deployment/proposal_0/Proposal_00.sol";
import {Proposal_1_13} from "@deployment/proposal_1/Proposal_1_13.sol";

// Test pending proposals with :
// forge test --match-contract ProtocolUpgradeCheck --rpc-url $ETH_RPC_URL -vvv
contract ProtocolUpgradeCheck is Test {
    using AddressStoreLib for Vm;

    /// @dev Update the setup to include pending proposals, or
    /// parts of the proposals if they have been deployed but have not executed, etc.
    function setUp() public virtual {
        // p0 is a placeholder empty proposal for quick local play
        Proposal_00 p0 = new Proposal_00();
        p0.setDebug(false);
        p0.run();

        Proposal_1_13 p1_13 = new Proposal_1_13();
        p1_13.setDebug(false);
        p1_13.run();
    }
}
