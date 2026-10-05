# LoopBet fork of Synthetix StakingRewards

| | |
|---|---|
| Upstream | `synthetix@2.102.1`, the official npm registry artifact (`https://registry.npmjs.org/synthetix/-/synthetix-2.102.1.tgz`). The `Synthetixio/synthetix` GitHub repository was taken down after the v3 migration; the npm artifact is immutable and publisher-signed, so it is the authoritative surviving source. |
| Files | `StakingRewards.sol` (forked, see below), `RewardsDistributionRecipient.sol`, `Owned.sol`, `Pausable.sol`, `interfaces/IStakingRewards.sol`. All but the first are byte for byte from `package/contracts/`. |
| Licence | MIT (LICENSE in this directory) |
| Compiler | `^0.5.16` (Foundry compiles it with a second solc automatically) |
| Dependencies | An OpenZeppelin 2.3.0 subset vendored in `lib/openzeppelin-2.3/`, resolved through the `openzeppelin-solidity-2.3.0/` remapping, which keeps the import paths the file ships with |

## Semantic change

**`REWARD_PRECISION = 1e33` replaces the inline `1e18` accumulator scale** in
`rewardPerToken()` and `earned()`, one line each.

**Why.** The accumulator tracks "reward units earned per staked token so far" as an
integer, and it is floored at *every* checkpoint. Any `stake`, `withdraw` or `getReward`
by *anyone* is a checkpoint. Upstream's 1e18 scale was designed for 18-decimal reward
tokens. With 6-decimal USDC rewards against 18-decimal LOOP stakes, the increments are
about 15 orders of magnitude smaller. For example, with 10M LOOP staked and 5,000 USDC a
month going to stakers, each LOOP earns about 0.7 micro-USDC per hour, so any interval
between checkpoints shorter than roughly 1.5 hours would contribute zero. Ordinary
activity would lose a meaningful share of the stream to rounding, and frequent
checkpoints would lose nearly all of it. At 1e33 the dead zone is below a microsecond
even with all 700M LOOP staked against a dust-level reward rate, and the truncation per
checkpoint is at most `supply / 1e33`, about 1e-6 micro-USDC.

**Why 1e33 cannot overflow** (it matters because SafeMath reverts, which would lock the
contract):

- `rewardPerToken()`: `dt * rewardRate * 1e33` with `dt <= rewardsDuration` and
  `rewardRate <= balance / rewardsDuration` (enforced by `notifyRewardAmount`), so the
  product is at most `balance * 1e33`. Even the entire USDC supply, about 6e16 base units,
  gives 6e49, far below 2^256 (about 1.16e77).
- `earned()`: while an account is staked, `_totalSupply >= _balances[account]` and the
  account's own checkpoints pin `userRewardPerTokenPaid`, so
  `balance * (rpt - paid) <= (rewards streamed while staked) * 1e33`. Same bound.
- `rewardPerTokenStored`, worst case of 1 wei staked alone and all rewards ever streamed:
  about 1e17 * 1e33 = 1e50, far below 2^256.

**Residual dust.** `rewardRate = reward / rewardsDuration` still floors, so each
`notifyRewardAmount` leaves fewer than `rewardsDuration` base units undistributed. That
dust stays in the contract balance and the owner can recover it with `recoverERC20`.

**View scale.** The public `rewardPerToken()` view now returns a 1e33-scaled value where
upstream returns 1e18. Do not compare it against upstream-scaled numbers.

Regression tests: `test/StakingRewardsPrecision.t.sol`. Hourly zero-stake checkpoints
across a full reward period must not erase rewards (this fails on the upstream scale), and
pro-rata splits stay exact under the same pattern.

## Deployment wiring

- `rewardsToken` is USDC and `stakingToken` is LOOP.
- `rewardsDistribution` is the `TreasuryVault`. Only it may call `notifyRewardAmount`. It
  is set with `setRewardsDistribution` once the vault exists.
- `setRewardsDuration` is called before the first notify (the constructor default is seven
  days). The duration is a deploy-time parameter, not a constant: read the live
  `rewardsDuration()` rather than assuming a value.
- **The owner is the `TimelockController`.** `recoverERC20` blocks only the staking token,
  so the owner can recover USDC that has not been distributed. That power therefore sits
  behind the public delay. The owner also controls `setPaused`, which pauses `stake` only.
  Withdrawals and reward claims can never be paused.

The 0.8 interface the vault uses is `src/interfaces/IStakingRewardsMinimal.sol`. Tests
deploy the real 0.5.16 artifact with `deployCode`.

## Upstream behaviour to be aware of (unchanged)

While nobody is staked, the per-second stream is credited to nobody. That portion neither
returns to the vault nor extends the period: it stays in the contract balance until the
owner recovers it with `recoverERC20`. The vault holds back the staker share when nobody
is staked at the moment `distribute()` is called, but it cannot prevent this if every
staker leaves in the middle of a period.
