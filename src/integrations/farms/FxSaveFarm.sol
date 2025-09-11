// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IMaturityFarm} from "@interfaces/IMaturityFarm.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";
import {CoWSwapFarmBase} from "@integrations/farms/CoWSwapFarmBase.sol";

interface ISavingFxUSDFacet {
    struct ConvertInParams {
        address tokenIn; // The address of source token.
        uint256 amount; // The amount of source token.
        address target; // The address of converter contract.
        bytes data; // The calldata passing to the target contract.
        uint256 minOut; // The minimum amount of output token should receive.
        bytes signature; // The optional data for future usage.
    }

    function depositToFxSave(ConvertInParams memory params, address tokenOut, uint256 minShares, address receiver)
        external
        payable;
}

interface IFxSave {
    function requestRedeem(uint256 shares) external;

    function claim(address receiver) external;

    function lockedProxy(address user) external view returns (address);

    function previewRedeem(uint256 shares) external view returns (uint256);
}

interface IFxUSDBasePool {
    function previewRedeem(uint256 shares) external view returns (uint256, uint256);
}

/// @title FxSaveFarm
/// @notice This contract can hold USDC, fxUSD, and fxSave.
/// It can be used to swap between fxUSD and USDC, and (un)wrap fxUSD <> fxSave.
contract FxSaveFarm is CoWSwapFarmBase, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    address public constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant _FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address public constant _FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    address public constant _FXUSD_BASE_POOL = 0x65C9A641afCEB9C0E6034e558A319488FA0FA3be;
    address public constant _FXDIAMOND = 0x33636D49FbefBE798e15e7F356E8DBef543CC708;
    address public constant _FXMULTIPATHCONVERTER = 0x12AF4529129303D7FbD2563E242C4a2890525912;
    address public constant _COW_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address public constant _COW_VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110;

    constructor(address _core, address _accounting)
        MultiAssetFarm(_core, _USDC, _accounting)
        CoWSwapFarmBase(_COW_SETTLEMENT, _COW_VAULT_RELAYER)
    {
        maxSlippage = 0.999e18; // default: max 0.1% slippage
    }

    function assets() public view virtual override(IFarm, MultiAssetFarm) returns (uint256) {
        uint256 usdcBalance = IERC20(_USDC).balanceOf(address(this));
        uint256 usdcPrice = Accounting(accounting).price(_USDC);

        uint256 fxUSDBalance = IERC20(_FXUSD).balanceOf(address(this));
        uint256 fxUSDPrice = Accounting(accounting).price(_FXUSD);

        uint256 fxBaseBalance = IFxSave(_FXSAVE).previewRedeem(IERC20(_FXSAVE).balanceOf(address(this)));
        address lockedProxy = IFxSave(_FXSAVE).lockedProxy(address(this));
        if (lockedProxy != address(0)) {
            fxBaseBalance += IERC20(_FXUSD_BASE_POOL).balanceOf(lockedProxy);
        }
        (uint256 fxUsdOut, uint256 usdcOut) = IFxUSDBasePool(_FXUSD_BASE_POOL).previewRedeem(fxBaseBalance);
        usdcBalance += usdcOut;
        fxUSDBalance += fxUsdOut;

        usdcBalance += fxUSDBalance.mulDivDown(fxUSDPrice, usdcPrice);

        return usdcBalance;
    }

    function assetTokens() public pure override returns (address[] memory) {
        address[] memory tokens = new address[](3);
        tokens[0] = _USDC;
        tokens[1] = _FXUSD;
        tokens[2] = _FXSAVE;
        return tokens;
    }

    function isAssetSupported(address _asset) public pure override returns (bool) {
        return _asset == _USDC || _asset == _FXUSD || _asset == _FXSAVE;
    }

    function maturity() public view virtual override returns (uint256) {
        return block.timestamp + 7 days;
    }

    /// @notice Stake fxUSD to fxSave.
    function stake(uint256 _amountIn) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IERC20(_FXUSD).forceApprove(_FXDIAMOND, _amountIn);
        ISavingFxUSDFacet(_FXDIAMOND).depositToFxSave(
            ISavingFxUSDFacet.ConvertInParams({
                tokenIn: _FXUSD,
                amount: _amountIn,
                target: _FXMULTIPATHCONVERTER,
                data: abi.encodeWithSignature(
                    "convert(address,uint256,uint256,uint256[])",
                    _FXUSD, // _tokenIn
                    _amountIn, // _amount
                    0, // _encoding
                    new uint256[](0) // _routes
                ),
                minOut: 0,
                signature: ""
            }),
            _FXUSD, // tokenOut
            0, // minShares
            address(this) // receiver
        );
    }

    /// @notice Begin unstaking process of fxSave to USDC+fxUSD.
    /// @dev this will redeem fxSave share tokens to a proxy contract unique to the user,
    /// that will hold the fxUSD base pool shares and register the redemption in fxUSD base pool contract.
    function beginUnstake(uint256 _amountToUnstake) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IFxSave(_FXSAVE).requestRedeem(_amountToUnstake);
    }

    /// @notice Complete the unstaking process of fxSave to USDC+fxUSD.
    /// @dev this will ask the user's proxy contract to call fxUSD base pool redeem() function,
    /// which will burn the fxUSD base pool shares and send USDC & fxUSD to the recipient.
    function completeUnstake() external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        IFxSave(_FXSAVE).claim(address(this));
    }

    /// @notice swap between USDC <> fxUSD
    function signSwapOrder(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minAmountOut)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes memory)
    {
        require(_tokenIn == _USDC || _tokenIn == _FXUSD, InvalidToken(_tokenIn));
        require(_tokenOut == _USDC || _tokenOut == _FXUSD, InvalidToken(_tokenOut));
        require(_tokenIn != _tokenOut, InvalidToken(_tokenOut));

        return _checkSwapApproveAndSignOrder(_tokenIn, _tokenOut, _amountIn, _minAmountOut, maxSlippage);
    }
}
