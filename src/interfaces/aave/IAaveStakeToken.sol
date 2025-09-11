// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAaveStakeToken {
    /**
     * @dev Allows staking a specified amount of STAKED_TOKEN
     * @param to The address to receiving the shares
     * @param amount The amount of assets to be staked
     */
    function stake(address to, uint256 amount) external;

    /**
     * @dev Redeems shares, and stop earning rewards
     * @param to Address to redeem to
     * @param amount Amount of shares to redeem
     */
    function redeem(address to, uint256 amount) external;

    /**
     * @dev Activates the cooldown period to unstake
     * - It can't be called if the user is not staking
     */
    function cooldown() external;

    /**
     * @dev Claims an `amount` of `REWARD_TOKEN` to the address `to`
     * @param to Address to send the claimed rewards
     * @param amount Amount to stake
     */
    function claimRewards(address to, uint256 amount) external;

    /**
     * @dev Return the total rewards pending to claim by an staker
     * @param staker The staker address
     * @return The rewards
     */
    function getTotalRewardsBalance(address staker) external view returns (uint256);

    /**
     * @dev Returns the current exchange rate
     * @return exchangeRate as 18 decimal precision uint216
     */
    function getExchangeRate() external view returns (uint216);

    /**
     * @dev Getter of the cooldown seconds
     * @return cooldownSeconds the amount of seconds between starting the cooldown and being able to redeem
     */
    function getCooldownSeconds() external view returns (uint256);

    /**
     * @dev returns the exact amount of shares that would be received for the provided number of assets
     * @param assets the number of assets to stake
     * @return uint256 shares the number of shares that would be received
     */
    function previewStake(uint256 assets) external view returns (uint256);

    /**
     * @dev returns the exact amount of assets that would be redeemed for the provided number of shares
     * @param shares the number of shares to redeem
     * @return uint256 assets the number of assets that would be redeemed
     */
    function previewRedeem(uint256 shares) external view returns (uint256);
}
