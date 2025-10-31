// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {Farm} from "@integrations/Farm.sol";
import {EpochLib} from "@libraries/EpochLib.sol";
import {FarmTypes} from "@libraries/FarmTypes.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {Accounting} from "@finance/Accounting.sol";
import {ReceiptToken} from "@tokens/ReceiptToken.sol";
import {FarmRegistry} from "@integrations/FarmRegistry.sol";
import {CoreControlled} from "@core/CoreControlled.sol";
import {MultiAssetFarm} from "@integrations/MultiAssetFarm.sol";
import {PendleV2FarmV2} from "@integrations/farms/PendleV2FarmV2.sol";
import {LockingController} from "@locking/LockingController.sol";
import {IMaturityFarm, IFarm} from "@interfaces/IMaturityFarm.sol";
import {IMintController, IAfterMintHook} from "@interfaces/IMintController.sol";

/// @notice Migration Controller
/// This contract allows users to migrate their funds from other protocols where
/// the InfiniFi protocol is also deploying, to receive InfinFi locked receipt tokens instead.
/// @dev this contract needs RECEIPT_TOKEN_MINTER & ENTRY_POINT roles
contract MigrationController is CoreControlled {
    using EpochLib for uint256;
    using SafeERC20 for ERC20;
    using FixedPointMathLib for uint256;

    error InvalidMaturity();
    error HookFailed(address farm, bytes4 selector);
    error CapExceeded(address farm, address token, uint256 cap);
    error InvalidAmount(uint256 amount);
    error MigrationFailed(address _farm, uint256 _amount);
    error FarmNotRegistered(address farm);
    error MigrationAmountTooLow(uint256 iusdAmount, uint256 minMigrationAmount);

    event SetConfig(uint256 indexed timestamp, address farm, address token, MigrationConfig config);
    event Migrated(
        uint256 indexed timestamp, address indexed user, address farm, address token, uint256 receiptTokenAmount
    );

    /// @notice reference to the FarmRegistry contract
    address public immutable farmRegistry;

    /// @notice reference to the Accounting contract
    address public immutable accounting;

    /// @notice reference to the LockingController contract
    address public immutable lockingController;

    /// @notice reference to the ReceiptToken contract
    address public immutable receiptToken;

    struct MigrationConfig {
        bytes4 selector; // selector of the function to call after migration
        uint112 cap; // maximum amount of iUSD that can be minted by migrating to the farm
        uint112 migrated; // amount of iUSD that has been minted by migrating to the farm
        uint128 minMigrationAmount; // minimum amount of iUSD that can be migrated to the farm
        uint128 migrationFee; // fee as a percent with 18 decimals, e.g. 0.01e18 = 1%
    }

    /// @notice mapping of farms migration cap data
    mapping(address farm => mapping(address token => MigrationConfig data)) public config;

    constructor(
        address _core,
        address _farmRegistry,
        address _accounting,
        address _lockingController,
        address _receiptToken
    ) CoreControlled(_core) {
        farmRegistry = _farmRegistry;
        accounting = _accounting;
        lockingController = _lockingController;
        receiptToken = _receiptToken;
    }

    /// @notice sets a farm's migration cap data
    /// @dev note that this resets the migrated amount to 0
    function setConfig(
        address _farm,
        address _token,
        uint256 _cap,
        bytes4 _selector,
        uint256 _minMigrationAmount,
        uint256 _migrationFee
    ) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        MigrationConfig memory _config = MigrationConfig({
            selector: _selector,
            cap: uint112(_cap),
            migrated: uint112(0),
            minMigrationAmount: uint128(_minMigrationAmount),
            migrationFee: uint128(_migrationFee)
        });

        config[_farm][_token] = _config;

        emit SetConfig(block.timestamp, _farm, _token, _config);
    }

    /// @notice Migrate assets to InfiniFi farms
    /// @return iusdAmount Amount of iUSD locked on behalf of the recipient
    function migrate(address _recipient, address _farm, address _token, uint256 _amount, uint32 _unwindingEpochs)
        external
        onlyCoreRole(CoreRoles.ENTRY_POINT)
        returns (uint256)
    {
        require(_amount > 0, InvalidAmount(_amount));
        // check farm is still in the registry
        require(FarmRegistry(farmRegistry).isFarmOfType(_farm, FarmTypes.MATURITY), FarmNotRegistered(_farm));

        // check lock duration vs farm's maturity
        {
            uint256 userUnwindingTimestamp = (block.timestamp.nextEpoch() + _unwindingEpochs).epochToTimestamp();
            require(IMaturityFarm(_farm).maturity() <= userUnwindingTimestamp, InvalidMaturity());
        }

        // compute iUSD amount owed to the user
        MigrationConfig memory _config = config[_farm][_token];
        uint256 iusdAmount;
        {
            uint256 assetsBefore = IFarm(_farm).assets();
            // airdrop tokens to farm
            ERC20(_token).safeTransferFrom(msg.sender, _farm, _amount);
            _callHookIfConfigured(_farm, _config.selector);
            uint256 assetsAfter = IFarm(_farm).assets();
            uint256 farmCap = IFarm(_farm).cap();
            require(assetsAfter <= farmCap, CapExceeded(_farm, _token, farmCap));

            uint256 assetsIncrease = assetsAfter - assetsBefore;
            require(assetsIncrease > 0, MigrationFailed(_farm, _amount));
            uint256 assetPrice = Accounting(accounting).price(IFarm(_farm).assetToken());
            uint256 iusdPrice = Accounting(accounting).price(receiptToken);

            iusdAmount = assetsIncrease.mulDivDown(assetPrice, iusdPrice);
        }

        // apply fee and check minimum migration amount
        iusdAmount -= iusdAmount.mulWadDown(uint256(_config.migrationFee));
        require(iusdAmount >= _config.minMigrationAmount, MigrationAmountTooLow(iusdAmount, _config.minMigrationAmount));

        // check for farm migration cap
        require(_config.migrated + iusdAmount <= _config.cap, CapExceeded(_farm, _token, _config.cap));

        // mint iUSD, lock it, send to user
        ReceiptToken(receiptToken).mint(address(this), iusdAmount);
        ReceiptToken(receiptToken).approve(lockingController, iusdAmount);
        LockingController(lockingController).createPosition(iusdAmount, _unwindingEpochs, _recipient);

        // update migrated amount
        config[_farm][_token].migrated += uint112(iusdAmount);

        emit Migrated(block.timestamp, _recipient, _farm, _token, iusdAmount);
        return iusdAmount;
    }

    function _callHookIfConfigured(address _farm, bytes4 _selector) internal {
        if (_selector != bytes4(0)) {
            (bool success,) = _farm.call(abi.encodeWithSelector(_selector));
            require(success, HookFailed(_farm, _selector));
        }
    }
}
