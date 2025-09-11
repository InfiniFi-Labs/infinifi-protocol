// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";
import {IGsm} from "@interfaces/aave/IGsm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {IDistributor} from "@interfaces/aave/IDistributor.sol";
import {IAaveStakeToken} from "@interfaces/aave/IAaveStakeToken.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";

/// @title AAVE sGHO Farm
/// @notice This contract is used to work with AAVE sGHO & Merit program
/// @notice Supports conversion between USDC->GHO->sGHO. waEthUSDC conversion is abstracted behind USDC->GHO conversion
contract sGHOFarm is MultiAssetFarm, IMaturityFarm {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    error NoRewardsToClaim();
    error QuotedGHOExceedCap(uint256 required, uint256 available);
    error InsufficientFunds(uint256 _requested, uint256 _available);

    event RewardsClaimed(uint256 indexed timestamp, uint256 rewards);
    event GHOExtracted(uint256 indexed timestamp, uint256 ghoOut);
    event GHOWrappedToSGHO(uint256 indexed timestamp, uint256 amount);
    event SGHOUnwrappedToGHO(uint256 indexed timestamp, uint256 amount);
    event USDCWrappedToGHO(uint256 indexed timestamp, uint256 amount);
    event GHOUnwrappedToUSDC(uint256 indexed timestamp, uint256 amount);

    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant GSM = 0xFeeb6FE430B7523fEF2a38327241eE7153779535;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant sGHO = 0x1a88Df1cFe15Af22B3c4c783D4e6F7F9e0C1885d;
    address public constant waEthUSDC = 0xD4fa2D31b7968E448877f69A96DE69f5de8cD23E;
    address public constant REWARDS_DISTRIBUTOR = 0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae;

    uint256 public rewards;
    uint256 public lastRewardTimestamp = 1;

    constructor(address _core, address _accounting) MultiAssetFarm(_core, USDC, _accounting) {
        maxSlippage = 0.998e18; // 20 bps
    }

    /// @notice the asset tokens that the farm can hold: USDC, GHO, sGHO
    function assetTokens() public pure override returns (address[] memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = USDC;
        tokens[1] = GHO;
        return tokens;
    }

    /// @notice return true if the farm can hold the given asset token
    function isAssetSupported(address _asset) public pure override returns (bool) {
        return _asset == USDC || _asset == GHO;
    }

    /// @notice Returns USDC value of farm holdings (USDC, GHO, sGHO)
    /// @return total balance expressed in USDC
    /// @dev Actual redeemable amount is always lower due to fees on AAVE GSM
    function assets() public view override(MultiAssetFarm, IFarm) returns (uint256) {
        uint256 totalAssetValue = MultiAssetFarm.assets();

        // sGHO balance (excluding unvested rewards)
        uint256 sghoBalance = _tokenBalance(sGHO) - unvestedRewards();
        if (sghoBalance > 0) {
            uint256 assetPrice = Accounting(accounting).price(assetToken);
            uint256 ghoPrice = Accounting(accounting).price(sGHO);
            totalAssetValue += sghoBalance.mulDivDown(ghoPrice, assetPrice);
        }

        return totalAssetValue;
    }

    function unvestedRewards() public view returns (uint256) {
        uint256 _lastRewardTimestamp = lastRewardTimestamp;
        if (block.timestamp - _lastRewardTimestamp >= 7 days) return 0;
        uint256 rewardRate = rewards.divWadDown(7 days);
        uint256 remainingTime = _lastRewardTimestamp + 7 days - block.timestamp;
        return rewardRate.mulWadDown(remainingTime);
    }

    /// @notice artificial farm maturity,
    /// it is a liquid farm but we want to prevent automatic movement here
    function maturity() external view override returns (uint256) {
        return block.timestamp + 7 days;
    }

    /// @notice Claims the rewards from Distributor contract from AngleLabs in sGHO
    /// @dev Rewards accrue every Tuesday. They are distributed until next Tuesday.
    /// @dev _amount and _proofs retrievable from: https://apps.aavechan.com/api/merit/user-data?user={address}&action-name=ethereum-sgho
    function claimRewards(uint256 _amount, bytes32[][] calldata _proofs) external {
        address[] memory users = new address[](1);
        users[0] = address(this);
        address[] memory tokens = new address[](1);
        tokens[0] = sGHO;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _amount;

        uint256 balanceBefore = _tokenBalance(sGHO);
        IDistributor(REWARDS_DISTRIBUTOR).claim(users, tokens, amounts, _proofs);
        uint256 balanceAfter = _tokenBalance(sGHO);

        uint256 rewardsClaimed = balanceAfter - balanceBefore;
        require(rewardsClaimed > 0, NoRewardsToClaim());

        rewards = rewardsClaimed + unvestedRewards();
        lastRewardTimestamp = block.timestamp;
        emit RewardsClaimed(block.timestamp, rewardsClaimed);
    }

    /// ----------------------------------------------------------------------------
    /// sGHO, GHO
    /// ----------------------------------------------------------------------------

    /// @dev Converts GHO to sGHO by staking it
    function wrapGHOtoSGHO(uint256 _amount) public whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        uint256 amountToConvert = _validateAmount(_tokenBalance(GHO), _amount);
        _approveToken(GHO, sGHO, amountToConvert);
        IAaveStakeToken(sGHO).stake(address(this), amountToConvert);
        emit GHOWrappedToSGHO(block.timestamp, amountToConvert);
    }

    /// @notice Converts sGHO to GHO
    function unwrapSGHOToGHO(uint256 _amount) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        uint256 availableBalance = _tokenBalance(sGHO) - unvestedRewards();
        uint256 amountToConvert = _validateAmount(availableBalance, _amount);

        IAaveStakeToken(sGHO).cooldown();
        IAaveStakeToken(sGHO).redeem(address(this), amountToConvert);
        emit SGHOUnwrappedToGHO(block.timestamp, amountToConvert);
    }

    /// ----------------------------------------------------------------------------
    /// GHO, USDC
    /// ----------------------------------------------------------------------------

    /// @notice Converts USDC to GHO via USDC -> waEthUSDC -> GHO
    function wrapUSDCToGHO(uint256 _amount) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        uint256 usdcAmount = _validateAmount(_tokenBalance(assetToken), _amount);

        uint256 ghoBefore = _tokenBalance(GHO);

        // deposit USDC to get waEthUSDC
        _approveToken(assetToken, waEthUSDC, usdcAmount);
        IERC4626(waEthUSDC).deposit(usdcAmount, address(this));

        // sell waEthUSDC to get GHO
        uint256 waEthUSDCBalance = _tokenBalance(waEthUSDC);
        _approveToken(waEthUSDC, GSM, waEthUSDCBalance);
        IGsm(GSM).sellAsset(waEthUSDCBalance, address(this));

        uint256 ghoReceived = _tokenBalance(GHO) - ghoBefore;

        // Calculate minimum output based on expected 1:1 ratio with slippage tolerance
        // Convert USDC (6 decimals) to GHO equivalent (18 decimals) and apply slippage
        uint256 expectedGHO = usdcAmount * 1e12; // Convert USDC to 18 decimals
        uint256 minGHOOut = expectedGHO.mulWadDown(maxSlippage);
        require(ghoReceived >= minGHOOut, InsufficientFunds(ghoReceived, minGHOOut));

        emit USDCWrappedToGHO(block.timestamp, usdcAmount);
    }

    /// @notice Converts GHO to USDC via GHO -> waEthUSDC -> USDC
    function unwrapGHOToUSDC(uint256 _amount) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        uint256 ghoAmount = _validateAmount(_tokenBalance(GHO), _amount);

        uint256 usdcBefore = _tokenBalance(assetToken);

        // buy waEthUSDC with GHO
        (uint256 waEthUSDCTokensOut, uint256 ghoRequired,,) = IGsm(GSM).getAssetAmountForBuyAsset(ghoAmount);
        require(ghoRequired <= ghoAmount, QuotedGHOExceedCap(ghoRequired, ghoAmount));

        _approveToken(GHO, GSM, ghoRequired);
        IGsm(GSM).buyAsset(waEthUSDCTokensOut, address(this));

        // redeem waEthUSDC back to USDC
        uint256 waEthUSDCBalance = _tokenBalance(waEthUSDC);
        IERC4626(waEthUSDC).redeem(waEthUSDCBalance, address(this), address(this));

        uint256 usdcReceived = _tokenBalance(assetToken) - usdcBefore;

        // Calculate minimum output based on expected 1:1 ratio with slippage tolerance
        // Convert GHO (18 decimals) to USDC equivalent (6 decimals) and apply slippage
        uint256 expectedUSDC = ghoRequired / 1e12; // Convert GHO to 6 decimals
        uint256 minUSDCOut = expectedUSDC.mulWadDown(maxSlippage);
        require(usdcReceived >= minUSDCOut, InsufficientFunds(usdcReceived, minUSDCOut));

        emit GHOUnwrappedToUSDC(block.timestamp, ghoRequired);
    }

    function _tokenBalance(address _token) private view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function _approveToken(address _token, address _to, uint256 _amount) private {
        IERC20(_token).forceApprove(_to, _amount);
    }

    /// @notice Validates and returns the actual amount to use for token operations
    /// @param _balance The available token balance
    /// @param _amount The requested amount (if 0, uses entire balance)
    /// @return The validated amount to use
    function _validateAmount(uint256 _balance, uint256 _amount) private pure returns (uint256) {
        require(_balance > 0, InsufficientFunds(_amount, 0));
        require(_amount <= _balance, InsufficientFunds(_amount, _balance));
        return _amount == 0 ? _balance : _amount;
    }
}
