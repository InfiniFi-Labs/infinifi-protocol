// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Farm} from "@integrations/Farm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {CoreRoles} from "@libraries/CoreRoles.sol";
import {IAaveV3Pool} from "@interfaces/aave/IAaveV3Pool.sol";
import {IAddressProvider} from "@interfaces/aave/IAddressProvider.sol";
import {IAaveDataProvider} from "@interfaces/aave/IAaveDataProvider.sol";

/// @title Aave V3 Farm
/// @notice This contract is used to deploy assets to aave v3
contract AaveV3Farm is Farm {
    using SafeERC20 for IERC20;

    error RewardsZeroAssets();

    event LendingPoolUpdated(uint256 indexed timestamp, address lendingPool);

    address public immutable aToken;

    /// @notice the aave v3 lending pool
    address public lendingPool;

    constructor(address _aToken, address _aaveV3Pool, address _core, address _assetToken) Farm(_core, _assetToken) {
        aToken = _aToken;
        lendingPool = _aaveV3Pool;
    }

    function setLendingPool(address _lendingPool) external onlyCoreRole(CoreRoles.GOVERNOR) {
        require(_lendingPool != address(0), ZeroAddress(_lendingPool));
        lendingPool = _lendingPool;
        emit LendingPoolUpdated(block.timestamp, _lendingPool);
    }

    /// @notice Returns the rebasing balance of the aToken
    function assets() public view override returns (uint256) {
        return ERC20(aToken).balanceOf(address(this));
    }

    /// @notice Returns the liquidity available on aave for the assetToken
    /// @dev This is the amount of assetToken that is available to withdraw from aave for asset Token
    /// @dev note that naked assetTokens not deposited to aave are ignored from assets() and from liquidity()
    /// because these cannot be pulled with the withdraw function, so always call deposit() after moving
    /// assetTokens to this farm in order to keep accounting consistent.
    function liquidity() public view override returns (uint256) {
        uint256 totalAssets = assets();

        // if aave is paused, cannot withdraw from aave
        address dataProvider = IAddressProvider(IAaveV3Pool(lendingPool).ADDRESSES_PROVIDER()).getPoolDataProvider();
        bool isAavePaused = IAaveDataProvider(dataProvider).getPaused(assetToken);
        if (isAavePaused) return 0;

        // find the amount of assetToken held by the aToken contract
        // this is the liquidity available on aave for the assetToken
        uint256 availableLiquidity = ERC20(assetToken).balanceOf(aToken);

        // if there is less liquidity on aave than the total assets held by the farm,
        // then the liquidity is the amount of USDC held by the aToken contract that is available to withdraw
        return availableLiquidity < totalAssets ? availableLiquidity : totalAssets;
    }

    /// @notice Deposit the assetToken to the aave v3 lending pool
    /// @dev this function deposit all the available assetToken held by the farm to the aavev3 lending pool
    function _deposit(uint256 availableBalance) internal override {
        // approve the lending pool to spend the asset tokens
        IERC20(assetToken).forceApprove(address(lendingPool), availableBalance);
        // trigger the deposit the asset tokens to the lending pool
        IAaveV3Pool(lendingPool).supply(assetToken, availableBalance, address(this), 0);
    }

    /// @notice Withdraw from the aave v3 lending pool
    /// @dev this function withdraw the amount of assetToken from the aave v3 lending pool
    /// @dev this function assumes that the amount of assetToken to withdraw is available on aave
    /// @dev if amount is uint256.max, it will withdraw all that is available on aave
    function _withdraw(uint256 _amount, address _to) internal override {
        IAaveV3Pool(lendingPool).withdraw(assetToken, _amount, _to);
    }

    // some farms have merkl rewards in the same aToken as the deposit receipt,
    // which can earn additional APR distributed as assets() spike.
    // This is the case for USDe, RLUSD, PYUSD, USDtb, USDS, ...
    // For rewards claiming in other tokens, see the MerklRewardsClaimer contract.
    /// @dev _rewardToken does not necessarily match aToken address because Merkl deploys
    /// wrapper contracts that allows campaigns to not be prefunded.
    function claimMerklRewards(uint256 _amount, address _rewardToken, bytes32[] calldata _proof)
        external
        whenNotPaused
        onlyCoreRole(CoreRoles.FARM_SWAP_CALLER)
    {
        address _rewardContract = rewardContract;
        require(_rewardContract != address(0), RewardsNotEnabled());

        uint256 assetsBefore = assets();

        {
            address[] memory users = new address[](1);
            users[0] = address(this);
            address[] memory tokens = new address[](1);
            tokens[0] = _rewardToken;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = _amount;
            bytes32[][] memory proofs = new bytes32[][](1);
            proofs[0] = _proof;
            (bool success,) = _rewardContract.call(
                abi.encodeWithSignature(
                    "claim(address[],address[],uint256[],bytes32[][])", users, tokens, amounts, proofs
                )
            );
            require(success, RewardsClaimFailed());
        }

        uint256 assetsAfter = assets();
        require(assetsAfter > assetsBefore, RewardsZeroAssets());

        emit Claimed(block.timestamp, assetsAfter - assetsBefore);
    }
}
