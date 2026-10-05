// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

import {IStakingRewardsMinimal} from "./interfaces/IStakingRewardsMinimal.sol";

/// @title TreasuryVault
/// @notice The LoopBet revenue splitter. It has no arbitrary-transfer function: revenue
/// arrives, `distribute()` splits it, and it leaves only through the enumerated paths below.
/// The discretionary ones belong to the owner, a Timelock, so they are announced on-chain
/// before they execute — the owner's reach is public and delayed, not absent:
///
///  1. Intake: a plain USDC transfer. No intake function is needed because `distribute()`
///     derives accrued revenue from `balanceOf`, so a raw ERC-20 transfer IS the intake.
///     Two sources, both public and both just transfers:
///       * the LP commission — a USDC transfer from the LP wallet, computed off-chain
///         from turnover;
///       * betting profit — `BettingBankroll.withdrawToTreasury`, whenever management moves
///         house winnings back for splitting.
///  2. `distribute` — permissionless but rate-limited to once per `distributionEpoch`: splits
///     USDC accrued since the last call by `stakerShareBps`; the staker share is pushed to
///     `StakingRewards` (`notifyRewardAmount`) immediately, in the same call, and the
///     remainder accrues to the ops bucket. The rate limit prevents spamming tiny notify calls
///     that would perpetually reset the reward stream. Revenue accrued while nobody is staked
///     rolls forward (`stakerBucket`) instead of leaking to ops.
///  3. `opsWithdraw` — the ops bucket exits only to the owner-designated target, and the owner
///     is a Timelock (ops multisig as proposer): discretionary spend is bounded and public.
///     This is also how the betting bankroll is funded and resized.
///
/// **This contract knows nothing about betting.** House betting capital lives in
/// `BettingBankroll`, a separate contract, so that betting spend can never touch USDC backing
/// the ops and staker buckets and a compromised maker key cannot reach staker money at all.
/// Betting profit re-enters here as an ordinary transfer and is split like any other revenue.
///
/// **The vault does not touch the CTF.** The Exchange's original fill-time fee path (fees paid
/// straight here as its immutable `feeRecipient`) is retired: every order signs
/// `feeRateBps = 0`, and this contract no longer implements the ERC-1155 receiver hooks.
/// The Exchange charges the fee in the asset the taker receives, which for a BUY order — the
/// only fee-bearing shape LoopBet ever signed — is an outcome token, so such a fill now
/// reverts at the token transfer instead of stranding tokens in a contract that cannot redeem
/// them. Re-enabling an on-chain fee would be a redeploy: the honest cost, rather than
/// plumbing carried indefinitely.
///
/// All parameters are settable only by the owner (= the Timelock), so ownership can migrate to
/// an on-chain Governor later without redeploying.
contract TreasuryVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* IMMUTABLES */

    /// @notice The collateral all revenue arrives in.
    IERC20 public immutable usdc;

    /* STORAGE */

    /// @notice Receives the staker share of every distribution (Synthetix StakingRewards).
    IStakingRewardsMinimal public stakingRewards;

    /// @notice Basis points of each distribution that go to stakers (the rest accrues to ops).
    uint256 public stakerShareBps;

    /// @notice Minimum seconds between `distribute` calls (= the reward epoch).
    uint256 public distributionEpoch;

    /// @notice Timestamp of the last successful `distribute`.
    uint256 public lastDistributionAt;

    /// @notice USDC earmarked for ops. Exits only via `opsWithdraw` (owner = Timelock).
    uint256 public opsBucket;

    /// @notice USDC earmarked for stakers but not yet pushed (accrues while nobody is staked).
    uint256 public stakerBucket;

    /* EVENTS */

    event Distributed(uint256 accrued, uint256 stakerShare, uint256 opsShare, uint256 pushedToStaking);
    event OpsWithdrawal(address indexed to, uint256 amount);
    event StakerShareBpsSet(uint256 stakerShareBps);
    event DistributionEpochSet(uint256 distributionEpoch);
    event StakingRewardsSet(address stakingRewards);

    /* CONSTRUCTOR */

    /// @param usdc_ The collateral token.
    /// @param stakingRewards_ The StakingRewards contract receiving staker payouts.
    /// @param initialOwner The Timelock that administers parameters and the ops bucket.
    /// @param stakerShareBps_ Initial staker split in basis points.
    /// @param distributionEpoch_ Initial reward epoch in seconds.
    constructor(
        IERC20 usdc_,
        IStakingRewardsMinimal stakingRewards_,
        address initialOwner,
        uint256 stakerShareBps_,
        uint256 distributionEpoch_
    ) {
        require(address(usdc_) != address(0), "TreasuryVault: usdc is zero");
        require(initialOwner != address(0), "TreasuryVault: owner is zero");

        usdc = usdc_;

        _setStakingRewards(stakingRewards_);
        _setStakerShareBps(stakerShareBps_);
        _setDistributionEpoch(distributionEpoch_);
        _transferOwnership(initialOwner);

        // The first distribution epoch is measured from deployment.
        lastDistributionAt = block.timestamp;
    }

    /* PERMISSIONLESS */

    /// @notice Splits USDC accrued since the last distribution: `stakerShareBps` to stakers
    /// (pushed to StakingRewards immediately), the rest to the ops bucket.
    /// @dev Permissionless, once per `distributionEpoch`. If nobody is staked, the staker share
    /// stays in `stakerBucket` and is pushed by a later call instead of leaking anywhere else.
    /// Accrued is simply "USDC held that isn't already earmarked" — the subtraction cannot
    /// underflow because every outflow decrements the bucket it was booked to.
    function distribute() external nonReentrant {
        require(block.timestamp >= lastDistributionAt + distributionEpoch, "TreasuryVault: epoch not elapsed");

        uint256 accrued = usdc.balanceOf(address(this)) - opsBucket - stakerBucket;
        uint256 stakerShare = (accrued * stakerShareBps) / 10_000;
        uint256 opsShare = accrued - stakerShare;

        lastDistributionAt = block.timestamp;
        opsBucket += opsShare;
        stakerBucket += stakerShare;

        uint256 pushed;
        if (stakerBucket > 0 && stakingRewards.totalSupply() > 0) {
            pushed = stakerBucket;
            stakerBucket = 0;

            usdc.safeTransfer(address(stakingRewards), pushed);
            stakingRewards.notifyRewardAmount(pushed);
        }

        require(accrued > 0 || pushed > 0, "TreasuryVault: nothing to distribute");

        emit Distributed(accrued, stakerShare, opsShare, pushed);
    }

    /* OWNER (= TIMELOCK) */

    /// @notice Withdraws from the ops bucket. The staker bucket is unreachable by construction.
    /// @dev Also the funding path for `BettingBankroll` — pass the bankroll as `to`. Timelocked
    /// at the ops delay, which is the correct cadence: this only *resizes* the bankroll, since
    /// winnings return to it directly and compound there.
    function opsWithdraw(address to, uint256 amount) external onlyOwner nonReentrant {
        require(to != address(0), "TreasuryVault: to is zero");
        require(amount <= opsBucket, "TreasuryVault: exceeds ops bucket");

        opsBucket -= amount;
        usdc.safeTransfer(to, amount);

        emit OpsWithdrawal(to, amount);
    }

    function setStakerShareBps(uint256 stakerShareBps_) external onlyOwner {
        _setStakerShareBps(stakerShareBps_);
    }

    function setDistributionEpoch(uint256 distributionEpoch_) external onlyOwner {
        _setDistributionEpoch(distributionEpoch_);
    }

    function setStakingRewards(IStakingRewardsMinimal stakingRewards_) external onlyOwner {
        _setStakingRewards(stakingRewards_);
    }

    /* INTERNAL */

    function _setStakerShareBps(uint256 stakerShareBps_) internal {
        require(stakerShareBps_ <= 10_000, "TreasuryVault: bps above 10000");

        stakerShareBps = stakerShareBps_;

        emit StakerShareBpsSet(stakerShareBps_);
    }

    function _setDistributionEpoch(uint256 distributionEpoch_) internal {
        require(distributionEpoch_ > 0, "TreasuryVault: epoch is zero");

        distributionEpoch = distributionEpoch_;

        emit DistributionEpochSet(distributionEpoch_);
    }

    function _setStakingRewards(IStakingRewardsMinimal stakingRewards_) internal {
        require(address(stakingRewards_) != address(0), "TreasuryVault: staking is zero");

        stakingRewards = stakingRewards_;

        emit StakingRewardsSet(address(stakingRewards_));
    }
}
