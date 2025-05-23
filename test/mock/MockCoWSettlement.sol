// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";
import {GPv2Order} from "@cowprotocol/contracts/libraries/GPv2Order.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

contract MockCoWSettlement {
    using FixedPointMathLib for uint256;

    // disable coverage for this contract
    function test() public view {}

    mapping(bytes32 orderDigest => bool signed) public orderSigned;

    function domainSeparator() public pure returns (bytes32) {
        // GPv2Settlement domain separator
        // deployed at 0x9008D19f58AAbD9eD0D60971565AA8510560ab41 on most chains
        return 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943;
    }

    function setPreSignature(bytes calldata orderUid, bool signed) external {
        // do nothing
        (bytes32 orderDigest,,) = GPv2Order.extractOrderUidParams(orderUid);
        orderSigned[orderDigest] = signed;
    }

    function mockSettle(bytes calldata orderUid, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        external
    {
        (bytes32 orderDigest, address owner, uint32 validTo) = GPv2Order.extractOrderUidParams(orderUid);
        require(orderSigned[orderDigest], "MockCoWSettlement: order not signed");
        require(uint32(block.timestamp) <= validTo, "MockCoWSettlement: invalid deadline");

        // settle
        MockERC20(tokenIn).burnFrom(owner, amountIn);
        MockERC20(tokenOut).mint(owner, amountOut);
    }
}
