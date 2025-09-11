// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFarm} from "@interfaces/IFarm.sol";

/// @notice Interface for an InfiniFi Farm contract that has a maturity date
/// @dev These farms represent illiquid farm/asset class
interface IMaturityFarm is IFarm {
    /// @notice timestamp at which more funds can be made available for withdrawal
    function maturity() external view returns (uint256);
}
