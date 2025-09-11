// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626Farm} from "@integrations/farms/ERC4626Farm.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";

/// @title ERC4626 Farm with a maturity date
/// @notice This contract is used to deploy assets in an ERC4626 vault that might be
/// illiquid (with async redemptions) or that we want to be virtually illiquid (because
/// there are deposits and withdrawals fees, or we want liquidity to be sticky, etc.).
contract ERC4626FarmWithMaturity is ERC4626Farm, IMaturityFarm {
    uint256 public immutable duration;

    constructor(address _core, address _assetToken, address _vault, uint256 _duration)
        ERC4626Farm(_core, _assetToken, _vault)
    {
        duration = _duration;
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + duration;
    }
}
