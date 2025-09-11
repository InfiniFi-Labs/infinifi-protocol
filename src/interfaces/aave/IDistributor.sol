// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// interface of distributor contract at `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae`
interface IDistributor {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
