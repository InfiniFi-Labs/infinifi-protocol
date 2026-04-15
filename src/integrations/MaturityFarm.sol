// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Farm} from "@integrations/Farm.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";

abstract contract MaturityFarm is Farm, IMaturityFarm {
    bool public immutable perpetual;
    uint256 public immutable duration;

    /// @notice mark it as perpetual if farm never expires
    constructor(address _core, address _assetToken, uint256 _duration, bool _perpetual) Farm(_core, _assetToken) {
        duration = _duration;
        perpetual = _perpetual;
    }

    function maturity() external view override returns (uint256) {
        return perpetual ? block.timestamp + duration : duration;
    }
}
