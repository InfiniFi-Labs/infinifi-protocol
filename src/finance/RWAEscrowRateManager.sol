// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {RWAEscrow} from "@finance/RWAEscrow.sol";
import {CoreControlled, CoreRoles} from "@core/CoreControlled.sol";

/// @title RWAEscrowRateManager
/// Purpose of this contract is to allow updating RWA escrow total assets based on a predefined rate
/// instead of relying on governance members to calculate it every time;
/// This drastically reduces chances of creating inaccurate accounting.
/// Should be set as keeper of the RWAEscrow contracts.
contract RWAEscrowRateManager is CoreControlled {
    using FixedPointMathLib for uint256;

    error InvalidRate(uint256 _rate, uint256 _min, uint256 _max);

    event RateUpdated(uint256 indexed _timestamp, address _escrow, uint256 _rate);

    /// @notice Return rate can be positive or negative.
    ///         Rates below 1e18 are negative and higher are positive.
    uint256 public constant BASE_RATE = FixedPointMathLib.WAD;

    /// @notice Cap profit rate to 20%.
    uint256 public constant MAX_RATE = BASE_RATE + 0.2e18;
    /// @notice Cap loss rate to 20%.
    uint256 public constant MIN_RATE = BASE_RATE - 0.2e18;

    /// @notice Number of seconds in a year.
    uint256 public constant YEAR = 365 days;

    mapping(address escrow => uint256 rate) public rates;

    constructor(address _core) CoreControlled(_core) {}

    /// @notice Sets a new rate for the given escrow
    /// @dev if escrow is already in the contract, it will first harvest the yield
    function setRate(address _escrow, uint256 _rate) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        require((_rate >= MIN_RATE && _rate <= MAX_RATE), InvalidRate(_rate, MIN_RATE, MAX_RATE));
        harvest(_escrow);
        rates[_escrow] = _rate;
        emit RateUpdated(block.timestamp, _escrow, _rate);
    }

    /// @notice Allows our timelock to bypass the rate limitations (sudden loss, etc)
    ///         by calling the escrow directly and updating the total assets
    /// @dev Can be called even if the contract is paused
    function governanceUpdateTotalAssets(address _escrow, uint256 _assets)
        external
        onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS)
    {
        RWAEscrow(_escrow).reportTotalAssets(_assets);
    }

    /// @notice Harvests yield on a specific escrow
    ///         based on the rate provided, positive or negative
    ///         the calculation here is non-compounding but considering
    ///         the frequency of keeper updates it can be made as such.
    /// @dev !!! MUST call this prior to new deposits or withdrawals otherwise rate calculation might get messed up.
    function harvest(address _escrow) public whenNotPaused {
        uint256 rate = rates[_escrow];
        if (rate == 0) return;

        uint256 timeDelta = block.timestamp - RWAEscrow(_escrow).lastUpdatedAt();
        // sanity check, this should never happen
        assert(timeDelta <= YEAR);
        if (timeDelta == 0) return;

        uint256 assets = RWAEscrow(_escrow).totalAssets();
        if (rate > BASE_RATE) {
            uint256 assetsInAYear = assets.mulWadDown(rate - BASE_RATE);
            assets += assetsInAYear.mulDivDown(timeDelta, YEAR);
        } else if (rate < BASE_RATE) {
            // Take note that frequent loss reporting will cause the loss to be exponential.
            uint256 assetsInAYear = assets.mulWadDown(BASE_RATE - rate);
            assets -= assetsInAYear.mulDivDown(timeDelta, YEAR);
        }

        RWAEscrow(_escrow).reportTotalAssets(assets);
    }
}
