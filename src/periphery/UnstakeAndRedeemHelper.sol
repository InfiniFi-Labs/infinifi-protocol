// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {GatewayLib} from "@libraries/GatewayLib.sol";
import {IInfiniFiGateway} from "@interfaces/IInfiniFiGateway.sol";

/// @notice Helper contract to unstake and redeem siUSD to USDC
/// This contract is used to atomically unstake and redeem siUSD to USDC,
/// a function that is not available in the infiniFi gateway contract.
contract UnstakeAndRedeemHelper {
    using SafeERC20 for IERC20;
    using GatewayLib for IInfiniFiGateway;

    IInfiniFiGateway public immutable gateway;
    address public immutable iUSD;
    address public immutable siUSD;

    constructor(address _gateway) {
        gateway = IInfiniFiGateway(_gateway);
        iUSD = gateway.receiptToken();
        siUSD = gateway.stakedToken();
        IERC20(siUSD).forceApprove(address(gateway), type(uint256).max);
        IERC20(iUSD).forceApprove(address(gateway), type(uint256).max);
    }

    function siUSD2iUSD(uint256 _siUSDAmount) public view returns (uint256) {
        if (_siUSDAmount == 0) return 0;
        return gateway.stakedToReceipt(_siUSDAmount);
    }

    function siUSD2USDC(uint256 _siUSDAmount) external view returns (uint256) {
        if (_siUSDAmount == 0) return 0;
        return gateway.receiptToAsset(siUSD2iUSD(_siUSDAmount));
    }

    function unstakeAndRedeem(uint256 _siUSDAmount) external returns (uint256) {
        IERC20(siUSD).safeTransferFrom(msg.sender, address(this), _siUSDAmount);
        uint256 iUSDAmount = gateway.unstake(address(this), _siUSDAmount);
        uint256 minUSDCOut = gateway.receiptToAsset(iUSDAmount);
        return gateway.redeem(msg.sender, iUSDAmount, minUSDCOut);
    }
}
