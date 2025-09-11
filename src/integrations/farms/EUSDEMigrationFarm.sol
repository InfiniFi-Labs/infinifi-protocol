// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";

/// @notice InfiniFi eUSDe Migration Farm that can migrate eUSDe to USDe
contract EUSDEMigrationFarm is MultiAssetFarm, IMaturityFarm {
    /// @notice USDC token address
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice eUSDe token address (Ethena eUSDe)
    address public constant EUSDE = 0x90D2af7d622ca3141efA4d8f1F24d86E5974Cc8F;

    /// @notice USDe token address (Ethena USDe)
    address public constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    error InsufficientEUSDeShares(uint256 requested, uint256 available);

    event EUSDeUnwrapped(uint256 indexed timestamp, uint256 eUsdeShares, uint256 usdeReceived);

    constructor(address _core, address _accounting) MultiAssetFarm(_core, USDC, _accounting) {}

    /// @notice Override assets() to handle multiple asset valuation
    /// @dev Calculates total value across all supported assets converted to assetToken value
    function assets() public view override(MultiAssetFarm, IFarm) returns (uint256) {
        return MultiAssetFarm.assets();
    }

    /// @notice Returns all supported asset tokens
    /// @dev Returns USDC, eUSDe, and USDe tokens
    function assetTokens() public pure override returns (address[] memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = EUSDE;
        tokens[1] = USDE;
        tokens[2] = USDC;
        return tokens;
    }

    function isAssetSupported(address _asset) public pure override returns (bool) {
        return _asset == EUSDE || _asset == USDE || _asset == USDC;
    }

    /// @notice Returns the maturity timestamp for this migration farm
    /// @dev After maturity, the farm should be considered for winding down
    /// @return uint256 Timestamp when the migration period ends
    function maturity() public view override returns (uint256) {
        return block.timestamp + 1 weeks;
    }

    /// @notice Unwraps eUSDe shares to USDe. Farm will pause after conversion.
    /// @param _eUsdeShares Amount of eUSDe shares to redeem
    /// @param _recipient Address to receive the USDe
    /// @return usdeReceived Amount of USDe received from redemption
    function convertToUSDeAndSend(uint256 _eUsdeShares, address _recipient)
        external
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        whenNotPaused
        returns (uint256 usdeReceived)
    {
        uint256 availableShares = IERC20(EUSDE).balanceOf(address(this));
        require(
            _eUsdeShares > 0 && _eUsdeShares <= availableShares, InsufficientEUSDeShares(_eUsdeShares, availableShares)
        );
        usdeReceived = IERC4626(EUSDE).redeem(_eUsdeShares, _recipient, address(this));
        emit EUSDeUnwrapped(block.timestamp, _eUsdeShares, usdeReceived);
    }
}
