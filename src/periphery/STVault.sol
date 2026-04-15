// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ERC7540} from "@periphery/ERC7540.sol";
import {GatewayLib} from "@libraries/GatewayLib.sol";
import {IInfiniFiGateway} from "@interfaces/IInfiniFiGateway.sol";

contract STVault is ERC7540 {
    using SafeERC20 for IERC20;
    using GatewayLib for IInfiniFiGateway;

    mapping(address controller => uint256 amount) public redemptions;

    constructor(address _core, address _gateway, address _assetToken, address _stakedToken)
        ERC7540(_core, _gateway, _assetToken, _stakedToken)
    {}

    function convertToAssets(uint256 _shares) public view override returns (uint256) {
        if (_shares == 0) return 0;
        uint256 receiptTokens = gateway.stakedToReceipt(_shares);
        return gateway.receiptToAsset(receiptTokens);
    }

    function convertToShares(uint256 _assets) public view override returns (uint256) {
        if (_assets == 0) return 0;
        uint256 receiptTokens = gateway.assetToReceipt(_assets);
        return gateway.receiptToStaked(receiptTokens);
    }

    function pendingRedeemRequest(uint256, address) public pure override returns (uint256 shares) {
        return 0;
    }

    function claimableRedeemRequest(uint256, address _controller) public view override returns (uint256 shares) {
        return redemptions[_controller];
    }

    function _requestRedeem(uint256 _shares, address _controller, address _owner)
        internal
        override
        returns (uint256 requestId)
    {
        IERC20(share).safeTransferFrom(_owner, address(this), _shares);
        redemptions[_controller] += _shares;
        return 0;
    }

    function _deposit(uint256 _assets, address _receiver, address _controller)
        internal
        override
        returns (uint256 shares)
    {
        deposits[_controller] -= _assets;
        IERC20(asset).forceApprove(address(gateway), _assets);
        uint256 stakedTokenBalance = balanceOf(address(_receiver));
        gateway.mintAndStake(address(_receiver), _assets);
        return balanceOf(address(_receiver)) - stakedTokenBalance;
    }

    function _redeem(uint256 _shares, address _controller, address _receiver)
        internal
        override
        returns (uint256 assetsOut)
    {
        redemptions[_controller] -= _shares;
        IERC20(share).forceApprove(address(gateway), _shares);
        uint256 receiptTokens = gateway.unstake(address(this), _shares);
        uint256 minAssetsOut = convertToAssets(_shares);
        IERC20(gateway.receiptToken()).forceApprove(address(gateway), receiptTokens);
        return gateway.redeem(_receiver, receiptTokens, minAssetsOut);
    }

    function _withdraw(uint256 _assets, address _receiver, address _controller)
        internal
        override
        returns (uint256 shares)
    {
        uint256 assetsOut = _redeem(convertToShares(_assets), _controller, _receiver);
        return convertToShares(assetsOut);
    }
}
