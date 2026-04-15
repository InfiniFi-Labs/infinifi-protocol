// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PLSmoother} from "@finance/PLSmoother.sol";
import {GatewayLib} from "@libraries/GatewayLib.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {IInfiniFiGateway} from "@interfaces/IInfiniFiGateway.sol";
import {YieldSharingV2} from "@finance/YieldSharingV2.sol";

/// @notice PLSmootherHelper
/// This contract is used to smooth the unaccrued yield of the protocol over some duration,
/// and to allow smoothing of yield donations.
/// @dev this contract requires RECEIPT_TOKEN_BURNER & FINANCE_MANAGER role.
contract PLSmootherHelper is CoreControlled {
    using GatewayLib for IInfiniFiGateway;

    /// @notice reference to the receipt token
    address public immutable gateway;

    /// @notice reference to the PL Smoother
    address public immutable smoother;

    /// @notice reference to the receipt token
    address public immutable receiptToken;

    /// @notice absolute maximum duration for smoothing
    uint256 public constant MAX_DURATION = 30 days;

    /// @notice minimum donation amount
    uint256 public constant MIN_DONATION = 1_000e18;

    /// @notice Error thrown when the smoothing duration is invalid
    /// (must be greater than 0 and less than or equal to MAX_DURATION)
    error InvalidDuration(uint256 duration);

    /// @notice Error thrown when the donation amount is too small
    /// (must be greater than the minimum donation amount)
    error InvalidDonation(uint256 donation);

    event DonatedAndSmoothed(uint256 indexed timestamp, uint256 amount, uint256 duration);
    event UnaccruedYieldSmoothed(uint256 indexed timestamp, uint256 amount, uint256 duration);

    constructor(address _core, address _gateway, address _smoother) CoreControlled(_core) {
        gateway = _gateway;
        smoother = _smoother;
        receiptToken = IInfiniFiGateway(_gateway).receiptToken();
    }

    /// @notice Donate iUSD to the protocol and distribute it over some duration as smoothed yield.
    /// @dev note that anyone can donate but there is a minimum donation to avoid spamming the storage
    /// of the PLSmoother contract.
    /// @param _donation The amount of iUSD to donate
    /// @param _duration The duration over which to distribute the iUSD as smoothed yield
    function donateAndSmooth(uint256 _donation, uint256 _duration) external whenNotPaused {
        require(_duration > 0 && _duration <= MAX_DURATION, InvalidDuration(_duration));
        require(_donation > 0 && _donation >= MIN_DONATION, InvalidDonation(_donation));

        ReceiptToken(receiptToken).burnFrom(msg.sender, _donation);
        PLSmoother(smoother).smoothProfit(_donation, _duration);

        emit DonatedAndSmoothed(block.timestamp, _donation, _duration);
    }

    /// @notice Smooth the unaccrued yield of the protocol over some duration.
    /// @param _maxSmoothed The maximum amount of yield that should not go through smoothing (0 for no limit)
    /// @param _duration The duration over which to distribute the yield as smoothed yield
    function smoothUnaccruedYield(uint256 _maxSmoothed, uint256 _duration)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.ACCRUE_YIELD)
    {
        require(_duration > 0 && _duration <= MAX_DURATION, InvalidDuration(_duration));

        address yieldSharing = IInfiniFiGateway(gateway).getAddress("yieldSharing");
        int256 unaccruedYield = YieldSharingV2(yieldSharing).unaccruedYield();
        if (unaccruedYield <= 0) return;

        // casting to 'uint256' is safe because of 'if' above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 yieldToSmooth = uint256(unaccruedYield);
        if (_maxSmoothed > 0 && yieldToSmooth > _maxSmoothed) yieldToSmooth = _maxSmoothed;
        PLSmoother(smoother).smoothProfit(yieldToSmooth, _duration);

        emit UnaccruedYieldSmoothed(block.timestamp, yieldToSmooth, _duration);
    }
}
