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
import {CoWSwapFarmBase} from "@integrations/farms/CoWSwapFarmBase.sol";

struct UserCooldown {
    uint104 cooldownEnd;
    uint152 underlyingAmount;
}

interface ISUSDe {
    function unstake(address receiver) external;
    function cooldownShares(uint256 shares) external;
    function cooldownDuration() external view returns (uint24);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address _owner) external returns (uint256);
    function cooldowns(address user) external view returns (UserCooldown memory);
}

/// @title EthenaFarm
/// @notice This contract can hold USDC, USDe, and sUSDe.
/// It can be used to swap between these assets and (un)wrap USDe <> sUSDe.
contract EthenaFarm is CoWSwapFarmBase, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    address public constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant _USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant _SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant _COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant _COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    constructor(address _core, address _accounting)
        MultiAssetFarm(_core, _USDC, _accounting)
        CoWSwapFarmBase(_COW_SETTLEMENT, _COW_VAULT_RELAYER)
    {
        maxSlippage = 0.998e18; // default: max 0.2% slippage
    }

    /// @dev note that there may be conversion fees between USDe/sUSDe and USDC.
    /// This is not reflected in the amount of USDC returned by assets().
    function assets() public view virtual override(IFarm, MultiAssetFarm) returns (uint256) {
        uint256 usdcBalance = IERC20(_USDC).balanceOf(address(this));
        uint256 usdcPrice = Accounting(accounting).price(_USDC);

        uint256 usdeBalance = IERC20(_USDE).balanceOf(address(this));
        uint256 usdePrice = Accounting(accounting).price(_USDE);

        uint256 susdeBalance = IERC20(_SUSDE).balanceOf(address(this));
        uint256 susdePrice = Accounting(accounting).price(_SUSDE);

        // add USDe in the process of unstaking
        usdeBalance += ISUSDe(_SUSDE).cooldowns(address(this)).underlyingAmount;

        usdcBalance += usdeBalance.mulDivDown(usdePrice, usdcPrice);
        usdcBalance += susdeBalance.mulDivDown(susdePrice, usdcPrice);

        return usdcBalance;
    }

    function assetTokens() public pure override returns (address[] memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = _USDC;
        tokens[1] = _USDE;
        tokens[2] = _SUSDE;
        return tokens;
    }

    function isAssetSupported(address _asset) public pure override returns (bool) {
        return _asset == _USDC || _asset == _USDE || _asset == _SUSDE;
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + uint256(ISUSDe(_SUSDE).cooldownDuration());
    }

    /// @notice Stake USDe to sUSDe.
    function stake(uint256 _usdeIn) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IERC20(_USDE).forceApprove(_SUSDE, _usdeIn);
        ISUSDe(_SUSDE).deposit(_usdeIn, address(this));
    }

    /// @notice Unstake sUSDe to USDe.
    /// @dev note that this will revert if sUSDe.cooldownDuration() is not equal to 0.
    function unstake(uint256 _susdeToUnstake) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        ISUSDe(_SUSDE).redeem(_susdeToUnstake, address(this), address(this));
    }

    /// @notice Begin unstaking process of sUSDe to USDe.
    /// @dev note that this will revert if sUSDe.cooldownDuration() is equal to 0.
    function beginUnstake(uint256 _susdeToUnstake) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        ISUSDe(_SUSDE).cooldownShares(_susdeToUnstake);
    }

    /// @notice Complete the unstaking process of sUSDe to USDe.
    function completeUnstake() external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        ISUSDe(_SUSDE).unstake(address(this));
    }

    /// @notice swap a token in [USDC, USDe, sUSDe] to a token out [USDC, USDe, sUSDe]
    function signSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(_tokenIn == _USDC || _tokenIn == _USDE || _tokenIn == _SUSDE, InvalidToken(_tokenIn));
        require(_tokenOut == _USDC || _tokenOut == _USDE || _tokenOut == _SUSDE, InvalidToken(_tokenOut));
        require(_tokenIn != _tokenOut, InvalidToken(_tokenOut));

        return _checkSwapApproveAndSignOrder(_tokenIn, _tokenOut, _amountIn, _minAmountOut, maxSlippage);
    }
}
