// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {FixedPointMathLib} from "@solmate/src/utils/FixedPointMathLib.sol";

import {IFarm} from "@interfaces/IFarm.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IProvisioner} from "@interfaces/gauntlet/IProvisioner.sol";
import {Farm, MaturityFarm} from "@integrations/MaturityFarm.sol";
import {IMultiDepositorVault} from "@interfaces/gauntlet/IMultiDepositorVault.sol";
import {IPriceAndFeeCalculator} from "@interfaces/gauntlet/IPriceAndFeeCalculator.sol";

contract GauntletAlphaFarm is MaturityFarm {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using FixedPointMathLib for uint256;

    error SlippageOutOfRange(uint256 _slippage, uint256 _min, uint256 _max);

    event HashStored(uint256 indexed _timestamp, bytes32 _hash, IProvisioner.Request _request);
    event HashRemoved(uint256 indexed _timestamp, bytes32 _hash);
    event DeadlineUpdated(uint256 indexed _timestamp, uint256 _deadline);
    event MaxPriceAgeUpdated(uint256 indexed _timestamp, uint256 _maxPriceAge);

    IProvisioner public constant PROVISIONER = IProvisioner(0x74C4A66CE4F4779B11E7c63D42e51EEef3A80D11);
    IMultiDepositorVault public constant GAUNTLET_VAULT =
        IMultiDepositorVault(0x3bd9248048df95Db4fBD748C6CD99C1bAa40bAD0);
    IPriceAndFeeCalculator public constant PRICE_AND_FEE_CALCULATOR =
        IPriceAndFeeCalculator(0x8F3FfA11CD5915f0E869192663b905504A2Ef4a5);

    /// @notice [seconds] Time we wait for the requests to be processed
    ///         In case deadline has passed, we have to request a refund
    uint256 public deadline;
    /// @notice [seconds] Price is considered stale if it was last updated before block.timestamp - maxPriceAge
    ///         Requests will not be processed in case of a stale price
    uint256 public maxPriceAge;

    EnumerableSet.Bytes32Set private hashes;
    mapping(bytes32 hash => IProvisioner.Request) private requests;

    constructor(address _core, address _assetToken, uint256 _duration)
        MaturityFarm(_core, _assetToken, _duration, true)
    {
        deadline = 3 days;
        maxPriceAge = 1 hours;
        maxSlippage = 0.99e18; // 1% max slippage
    }

    function setDeadline(uint256 _newDeadline) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        deadline = _newDeadline;
        emit DeadlineUpdated(block.timestamp, _newDeadline);
    }

    function setMaxPriceAge(uint256 _maxPriceAge) external onlyCoreRole(CoreRoles.PROTOCOL_PARAMETERS) {
        maxPriceAge = _maxPriceAge;
        emit MaxPriceAgeUpdated(block.timestamp, _maxPriceAge);
    }

    function assets() public view override(IFarm, Farm) returns (uint256) {
        uint256 totalAssets = IERC20(assetToken).balanceOf(address(this));
        uint256 totalShares = GAUNTLET_VAULT.balanceOf(address(this));

        uint256 hashesLength = hashes.length();
        for (uint256 i = 0; i < hashesLength; i++) {
            bytes32 hash = hashes.at(i);
            (bool isDeposit, bool exists) = _checkTypeAndExistence(hash);
            if (!exists) continue;
            if (isDeposit) totalAssets += requests[hash].tokens;
            else totalShares += requests[hash].units;
        }

        // discount is included as we are using request tokens
        // for redemptions which are lowered by the slippage
        totalAssets += PRICE_AND_FEE_CALCULATOR.convertUnitsToToken(
            address(GAUNTLET_VAULT), IERC20(assetToken), totalShares
        );

        return totalAssets;
    }

    function liquidity() external view override returns (uint256) {
        return IERC20(assetToken).balanceOf(address(this));
    }

    /// @notice Retrieves a specific request by it's hash
    function getRequest(bytes32 _hash) public view returns (IProvisioner.Request memory) {
        return requests[_hash];
    }

    /// @notice Gets all hashes currently stored here, useful for offchain tracking
    function getHashes() public view returns (bytes32[] memory) {
        return hashes.values();
    }

    function vaultRequestDeposit(uint256 _assetsIn, uint256 _slippage)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes32)
    {
        require(
            _slippage >= maxSlippage && _slippage <= FixedPointMathLib.WAD,
            SlippageOutOfRange(_slippage, maxSlippage, FixedPointMathLib.WAD)
        );

        _pruneHashes();
        uint256 minUnitsOut = PRICE_AND_FEE_CALCULATOR.convertTokenToUnits(
                address(GAUNTLET_VAULT), IERC20(assetToken), _assetsIn
            ).mulWadDown(_slippage);

        IERC20(assetToken).forceApprove(address(PROVISIONER), _assetsIn);
        PROVISIONER.requestDeposit(
            IERC20(assetToken), _assetsIn, minUnitsOut, 0, block.timestamp + deadline, maxPriceAge, false
        );

        return _storeHash(_createRequest(IProvisioner.RequestType.DEPOSIT_AUTO_PRICE, _assetsIn, minUnitsOut));
    }

    function vaultRequestRedeem(uint256 _unitsIn, uint256 _slippage)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
        returns (bytes32)
    {
        require(
            _slippage >= maxSlippage && _slippage <= FixedPointMathLib.WAD,
            SlippageOutOfRange(_slippage, maxSlippage, FixedPointMathLib.WAD)
        );

        _pruneHashes();
        uint256 minTokensOut = PRICE_AND_FEE_CALCULATOR.convertUnitsToToken(
                address(GAUNTLET_VAULT), IERC20(assetToken), _unitsIn
            ).mulWadDown(_slippage);

        IERC20(address(GAUNTLET_VAULT)).forceApprove(address(PROVISIONER), _unitsIn);
        PROVISIONER.requestRedeem(
            IERC20(assetToken), _unitsIn, minTokensOut, 0, block.timestamp + deadline, maxPriceAge, false
        );

        return _storeHash(_createRequest(IProvisioner.RequestType.REDEEM_AUTO_PRICE, minTokensOut, _unitsIn));
    }

    /// @notice Allows us to request refund after a deadline has passed.
    function vaultRequestRefund(bytes32 _hash) external whenNotPaused onlyCoreRole(CoreRoles.FARM_SWAP_CALLER) {
        PROVISIONER.refundRequest(IERC20(assetToken), requests[_hash]);
        _pruneHashes();
    }

    function _createRequest(IProvisioner.RequestType _requestType, uint256 _tokens, uint256 _units)
        internal
        view
        returns (IProvisioner.Request memory)
    {
        // 0 is solver tip per their doc
        return
            IProvisioner.Request(
                _requestType, address(this), _units, _tokens, 0, block.timestamp + deadline, maxPriceAge
            );
    }

    function _storeHash(IProvisioner.Request memory _request) internal returns (bytes32 hash) {
        hash = PROVISIONER.getRequestHash(IERC20(assetToken), _request);
        hashes.add(hash);
        requests[hash] = _request;
        emit HashStored(block.timestamp, hash, _request);
    }

    function _checkTypeAndExistence(bytes32 _hash) internal view returns (bool isDeposit, bool exists) {
        IProvisioner.RequestType requestType = requests[_hash].requestType;
        isDeposit = requestType == IProvisioner.RequestType.DEPOSIT_AUTO_PRICE
            || requestType == IProvisioner.RequestType.DEPOSIT_FIXED_PRICE;
        exists = isDeposit ? PROVISIONER.asyncDepositHashes(_hash) : PROVISIONER.asyncRedeemHashes(_hash);
    }

    function _pruneHashes() internal {
        uint256 i = 0;
        while (i < hashes.length()) {
            bytes32 hash = hashes.at(i);
            (, bool exists) = _checkTypeAndExistence(hash);
            if (!exists) {
                hashes.remove(hash);
                delete requests[hash];
                emit HashRemoved(block.timestamp, hash);
            } else {
                ++i;
            }
        }
    }

    /// @dev Deposit does nothing, assetTokens are just held on this farm
    /// @dev There should be other functions to do conversions between the assetTokens or deploying
    /// the funds to a productive yield source
    /// @param _amount The amount to deposit (unused in this implementation)
    function _deposit(uint256 _amount) internal view virtual override {}

    /// @notice Deposits assets into the farm (used for airdrops)
    /// @dev Note that in airdrops we do not know the amount of assets before the deposit,
    /// therefore we emit an event that contains twice the assets after the deposit
    function deposit() external virtual override(Farm, IFarm) onlyCoreRole(CoreRoles.FARM_MANAGER) whenNotPaused {
        uint256 currentAssets = assets();
        if (currentAssets > cap) {
            revert CapExceeded(currentAssets, cap);
        }

        _deposit(0);

        /// @dev note that in airdrops we do not know the amount of assets before the deposit,
        /// therefore we emit an event that contains twice the assets after the deposit.
        emit AssetsUpdated(block.timestamp, currentAssets, currentAssets);
    }

    function _withdraw(uint256 _amount, address _to) internal virtual override {
        IERC20(assetToken).safeTransfer(_to, _amount);
    }
}
