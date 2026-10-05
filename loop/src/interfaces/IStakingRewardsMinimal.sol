// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @notice The slice of Synthetix `StakingRewards` (solc 0.5.16, `src/staking/`) that the
/// TreasuryVault calls. Declared separately because the vendored contract predates 0.8.
interface IStakingRewardsMinimal {
    /// @dev Callable only by the configured `rewardsDistribution` (= the TreasuryVault).
    function notifyRewardAmount(uint256 reward) external;

    /// @notice Total LOOP currently staked.
    function totalSupply() external view returns (uint256);
}
