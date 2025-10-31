// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";
import {CoWSwapFarmBase} from "@integrations/farms/CoWSwapFarmBase.sol";

interface IReservoirPSM {
    function redeem(address receiver, uint256 amount) external;
}

interface IReservoirCreditEnforcer {
    function mintStablecoin(uint256 amount) external;
}

/// @title Reservoir Farm
/// @notice This contract can hold USDC, rUSD, and wsrUSD.
contract ReservoirFarm is CoWSwapFarmBase, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    uint256 private constant _RUSD_TO_USDC_SCALE = 1e12;

    address public constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant _RUSD = 0x09D4214C03D01F49544C0448DBE3A27f768F2b34;
    address public constant _WSRUSD = 0xd3fD63209FA2D55B07A0f6db36C2f43900be3094;
    address public constant _PSM = 0x4809010926aec940b550D34a46A52739f996D75D;
    address public constant _CREDIT_ENFORCER = 0x04716DB62C085D9e08050fcF6F7D775A03d07720;
    address public constant _COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant _COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    constructor(address _core, address _accounting)
        MultiAssetFarm(_core, _USDC, _accounting)
        CoWSwapFarmBase(_COW_SETTLEMENT, _COW_VAULT_RELAYER)
    {
        maxSlippage = 0.999e18; // default: max 0.1% slippage
    }

    function assetTokens() public pure override returns (address[] memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = _USDC;
        tokens[1] = _RUSD;
        tokens[2] = _WSRUSD;
        return tokens;
    }

    function isAssetSupported(address _asset) public pure override returns (bool) {
        return _asset == _USDC || _asset == _RUSD || _asset == _WSRUSD;
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + 7 days;
    }

    /// @notice Wrap USDC to rUSD.
    function wrap(uint256 _usdcIn) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IERC20(_USDC).approve(_PSM, _usdcIn);
        IReservoirCreditEnforcer(_CREDIT_ENFORCER).mintStablecoin(_usdcIn);
    }

    /// @notice Unwrap rUSD to USDC.
    function unwrap(uint256 _rUsdIn) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IERC20(_RUSD).approve(_PSM, _rUsdIn);
        IReservoirPSM(_PSM).redeem(address(this), _rUsdIn / _RUSD_TO_USDC_SCALE);
        IERC20(_RUSD).approve(_PSM, 0); // reset approval due to rounding above
    }

    /// @notice Stake rUSD to wsrUSD.
    function stake(uint256 _rUsdIn) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IERC20(_RUSD).approve(_WSRUSD, _rUsdIn);
        ERC4626(_WSRUSD).deposit(_rUsdIn, address(this));
    }

    /// @notice Unstake wsrUSD to rUSD.
    function unstake(uint256 _wsrUsdIn) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        ERC4626(_WSRUSD).redeem(_wsrUsdIn, address(this), address(this));
    }

    /// @notice swap a token in [USDC, rUSD, wsrUSD] to a token out [USDC, rUSD, wsrUSD]
    function signSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(_tokenIn == _USDC || _tokenIn == _RUSD || _tokenIn == _WSRUSD, InvalidToken(_tokenIn));
        require(_tokenOut == _USDC || _tokenOut == _RUSD || _tokenOut == _WSRUSD, InvalidToken(_tokenOut));
        require(_tokenIn != _tokenOut, InvalidToken(_tokenOut));

        return _checkSwapApproveAndSignOrder(_tokenIn, _tokenOut, _amountIn, _minAmountOut, maxSlippage);
    }
}
