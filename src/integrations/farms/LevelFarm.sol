// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";

struct UserCooldown {
    uint104 cooldownEnd;
    uint152 underlyingAmount;
}

interface ISLVLUSD {
    function unstake(address receiver) external;
    function cooldownShares(uint256 shares) external;
    function cooldowns(address user) external view returns (UserCooldown memory);
}

interface ILvlMinting {
    function pendingRedemption(address user, address asset) external view returns (uint256);
    function initiateRedeem(address asset, uint256 lvlUsdAmount, uint256 minAssetAmount)
        external
        returns (uint256, uint256);
    function completeRedeem(address asset, address beneficiary) external returns (uint256);
}

/// @title LevelFarm
/// @notice This contract can hold USDC, lvlUSD, and slvlUSD.
/// @dev exit only, no new deposits as the protocol announced their shutdown.
contract LevelFarm is MultiAssetFarm, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    address public constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant _LVLUSD = 0x7C1156E515aA1A2E851674120074968C905aAF37;
    address public constant _SLVLUSD = 0x4737D9b4592B40d51e110b94c9C043c6654067Ae;
    address public constant _LVL_MINTING = 0x9136aB0294986267b71BeED86A75eeb3336d09E1;

    constructor(address _core, address _accounting) MultiAssetFarm(_core, _USDC, _accounting) {}

    function assets() public view virtual override(IFarm, MultiAssetFarm) returns (uint256) {
        uint256 usdcBalance = IERC20(_USDC).balanceOf(address(this));
        uint256 usdcPrice = Accounting(accounting).price(_USDC);

        uint256 lvlusdBalance = IERC20(_LVLUSD).balanceOf(address(this));
        uint256 lvlusdPrice = Accounting(accounting).price(_LVLUSD);

        uint256 slvlusdBalance = IERC20(_SLVLUSD).balanceOf(address(this));
        uint256 slvlusdPrice = Accounting(accounting).price(_SLVLUSD);

        // add lvlUSD in the process of unstaking
        lvlusdBalance += ISLVLUSD(_SLVLUSD).cooldowns(address(this)).underlyingAmount;
        // add USDC in the process of redeeming
        usdcBalance += ILvlMinting(_LVL_MINTING).pendingRedemption(address(this), _USDC);

        usdcBalance += lvlusdBalance.mulDivDown(lvlusdPrice, usdcPrice);
        usdcBalance += slvlusdBalance.mulDivDown(slvlusdPrice, usdcPrice);

        return usdcBalance;
    }

    function assetTokens() public pure override returns (address[] memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = _USDC;
        tokens[1] = _LVLUSD;
        tokens[2] = _SLVLUSD;
        return tokens;
    }

    function isAssetSupported(address _asset) public pure override returns (bool) {
        return _asset == _USDC || _asset == _LVLUSD || _asset == _SLVLUSD;
    }

    function maturity() public view virtual override returns (uint256) {
        return 1759177354;
    }

    /// @notice Begin unstaking process of slvlUSD to lvlUSD.
    function cooldownShares(uint256 _slvlusdToUnstake) external whenNotPaused {
        ISLVLUSD(_SLVLUSD).cooldownShares(_slvlusdToUnstake);
    }

    /// @notice Complete the unstaking process of slvlUSD to lvlUSD.
    function unstake() external whenNotPaused {
        ISLVLUSD(_SLVLUSD).unstake(address(this));
    }

    /// @notice Begin redeeming lvlUSD to USDC.
    function initiateRedeem(uint256 _lvlusdToRedeem) external whenNotPaused {
        IERC20(_LVLUSD).approve(_LVL_MINTING, _lvlusdToRedeem);
        ILvlMinting(_LVL_MINTING).initiateRedeem(_USDC, _lvlusdToRedeem, 0);
    }

    /// @notice Complete the redeeming process of lvlUSD to USDC.
    function completeRedeem() external whenNotPaused {
        ILvlMinting(_LVL_MINTING).completeRedeem(_USDC, address(this));
    }
}
