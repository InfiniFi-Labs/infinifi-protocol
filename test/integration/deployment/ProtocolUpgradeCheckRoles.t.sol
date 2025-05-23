pragma solidity 0.8.28;

import {Vm} from "@forge-std/Vm.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {InfiniFiCore} from "@core/InfiniFiCore.sol";
import {AddressStoreLib} from "@deployment/AddressStoreLib.sol";
import {ProtocolUpgradeCheck} from "@test/integration/deployment/ProtocolUpgradeCheck.sol";

contract ProtocolUpgradeCheckRoles is ProtocolUpgradeCheck {
    using AddressStoreLib for Vm;

    function testCurrentRoles() public {
        string memory root = vm.projectRoot();
        string memory path =
            string.concat(root, "/deployment/configuration/roles.", Strings.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        string[] memory roles = vm.parseJsonKeys(json, "$");

        assertEq(roles.length, 20, "incorrect role count");

        InfiniFiCore core = InfiniFiCore(vm.getAddr("CORE"));
        for (uint256 i = 0; i < roles.length; i++) {
            bytes32 role = keccak256(bytes(roles[i]));

            assertEq(
                core.getRoleAdmin(role),
                CoreRoles.GOVERNOR,
                string.concat("Wrong admin for role ", roles[i], ", expected GOVERNOR")
            );

            bytes memory parsedJson = vm.parseJson(json, string.concat(".", roles[i]));
            string[] memory addressNames = abi.decode(parsedJson, (string[]));

            assertEq(
                core.getRoleMemberCount(role),
                addressNames.length,
                string.concat(
                    "Expected role ", roles[i], " to have ", Strings.toString(addressNames.length), " members"
                )
            );

            for (uint256 j = 0; j < addressNames.length; j++) {
                assertEq(
                    core.hasRole(role, vm.getAddr(addressNames[j])),
                    true,
                    string.concat("Expected ", addressNames[j], " to have role ", roles[i])
                );
            }
        }
    }
}
