// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SwapFarmV2} from "@integrations/farms/SwapFarmV2.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";

/// @title SwapFarmV2WithMaturity
/// @notice SwapFarmV2 with a duration
contract SwapFarmV2WithMaturity is SwapFarmV2, IMaturityFarm {
    /// @notice Duration of the farm (maturity() returns block.timestamp + duration)
    uint256 public immutable duration;

    constructor(
        address _core,
        address _assetToken,
        address _accounting,
        address _settlementContract,
        address _vaultRelayer,
        uint256 _duration
    ) SwapFarmV2(_core, _assetToken, _accounting, _settlementContract, _vaultRelayer) {
        duration = _duration;
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + duration;
    }
}
