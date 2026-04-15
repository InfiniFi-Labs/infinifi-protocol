// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RWAEscrow} from "@finance/RWAEscrow.sol";
import {Farm, IFarm} from "@integrations/Farm.sol";
import {MaturityFarm} from "@integrations/MaturityFarm.sol";

/// @title RWAEscrowFarm
/// @dev This farm should not hold USDC.
///      Any USDC held here will be considered as a welcome donation
contract RWAEscrowFarm is MaturityFarm {
    using SafeERC20 for IERC20;

    error InsufficientLiquidity(uint256 _amount, uint256 _liquidity);

    RWAEscrow public immutable escrow;

    constructor(address _core, address _assetToken, uint256 _duration, address _receiver, address _keeper)
        MaturityFarm(_core, _assetToken, _duration, true)
    {
        escrow = new RWAEscrow(_core, _assetToken, _receiver, _keeper);
        IERC20(assetToken).forceApprove(address(escrow), type(uint256).max);
    }

    /// @notice Returns the escrow total assets (tokens held directly by this farm are excluded)
    function assets() public view override(Farm, IFarm) returns (uint256) {
        return escrow.totalAssets();
    }

    function liquidity() public view override returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this)) + escrow.liquidity();
    }

    /// @notice immediatelly deposits into the escrow
    function _deposit(uint256 _amount) internal override {
        escrow.deposit(_amount);
    }

    /// @notice can withdraw only up to liquidity
    function _withdraw(uint256 _amount, address _to) internal override {
        require(_amount <= liquidity(), InsufficientLiquidity(_amount, liquidity()));

        // pulls out any airdropped tokens from this farm first
        uint256 assetTokenBalance = IERC20(assetToken).balanceOf(address(this));
        if (_amount > assetTokenBalance) {
            uint256 amountToWithdraw = _amount - assetTokenBalance;
            escrow.withdraw(amountToWithdraw);
        }

        IERC20(assetToken).safeTransfer(_to, _amount);
    }
}
