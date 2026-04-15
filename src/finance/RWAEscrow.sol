// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {CoreRoles} from "@libraries/CoreRoles.sol";
import {CoreControlled} from "@core/CoreControlled.sol";

contract RWAEscrow is Ownable, CoreControlled {
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    error InvalidKeeper(address);

    event KeeperSet(uint256 indexed _timestamp, address _keeper);
    event TokensSent(uint256 indexed _timestamp, address _farm, address _receiver, uint256 _amount);
    event TokensWithdrawn(uint256 indexed _timestamp, address _farm, address _receiver, uint256 _amount);
    event TotalAssetsUpdated(uint256 indexed _timestamp, address _receiver, uint256 _old, uint256 _new);

    address public immutable receiver;
    address public immutable assetToken;

    /// @notice whitelisted address to make updates on our behalf [team msig initally]
    address public keeper;
    /// @notice accounting of all assets held here and sent to the RWAs
    uint256 public totalAssets;
    /// @notice time when the `totalAssets` were last updated by the keeper.
    uint256 public lastUpdatedAt;

    constructor(address _core, address _assetToken, address _receiver, address _keeper)
        Ownable(msg.sender)
        CoreControlled(_core)
    {
        keeper = _keeper;
        receiver = _receiver;
        assetToken = _assetToken;
    }

    function setKeeper(address _keeper) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        keeper = _keeper;
        emit KeeperSet(block.timestamp, _keeper);
    }

    /// @notice assetTokens withdrawable
    ///         in case there are more asset tokens than the contract is aware of
    ///         we will return the totalAssets as liquidity instead
    function liquidity() public view returns (uint256) {
        uint256 balance = ERC20(assetToken).balanceOf(address(this));
        return totalAssets >= balance ? balance : totalAssets;
    }

    /// @notice Pulls tokens out from the farm and sends it to the RWA address.
    /// @dev Requires escrow contract to be approved by the farm.
    function deposit(uint256 _amount) external onlyOwner {
        totalAssets += _amount;
        lastUpdatedAt = block.timestamp;
        ERC20(assetToken).safeTransferFrom(msg.sender, receiver, _amount);
        emit TokensSent(block.timestamp, msg.sender, receiver, _amount);
    }

    /// @notice Sends asset tokens back to the farm once there is sufficient liquidity.
    ///         In case totalAssets is underflowing, sync the state with `reportTotalAssets` first.
    function withdraw(uint256 _amount) external onlyOwner {
        totalAssets -= _amount;
        lastUpdatedAt = block.timestamp;
        ERC20(assetToken).safeTransfer(msg.sender, _amount);
        emit TokensWithdrawn(block.timestamp, msg.sender, receiver, _amount);
    }

    /// @notice Sets `totalAssets` to the new value
    ///         This can trigger either a yield spike or a loss, use carefully
    ///         It is mandatory to use asset checker for this
    /// @param _totalAssets new absolute total assets value
    /// @dev _totalAssets value must be within given limits
    function reportTotalAssets(uint256 _totalAssets) external {
        require(msg.sender == keeper, InvalidKeeper(msg.sender));

        uint256 previousTotalAssets = totalAssets;
        (totalAssets, lastUpdatedAt) = (_totalAssets, block.timestamp);
        emit TotalAssetsUpdated(block.timestamp, receiver, previousTotalAssets, _totalAssets);
    }
}
