# $LOOP contracts

The contracts around the exchange: the token, the emissions distributor, staking, the
treasury vault and the betting bankroll. The exchange itself is in
[`../ctf-exchange`](../ctf-exchange/).

**Money lives in two contracts, deliberately.** `TreasuryVault` holds revenue and splits
it; `BettingBankroll` holds the house's betting capital and nothing else. Keeping betting
money on its own removes a whole layer of accounting: spend is the balance going down, a
win lands straight back, a loss is a smaller balance, and funding is a plain transfer. It
also means the key that signs the house's bets cannot reach staker or operations money at
all.

## Contracts

| Contract | Source | What it is |
|---|---|---|
| `LOOP.sol` | this project | OpenZeppelin ERC-20 with Permit. A fixed supply of 1B is minted once at genesis: 700M to the distributor, 300M to founders. No admin functions. |
| `distributor/UniversalRewardsDistributor.sol` | **fork** of the Morpho URD | Cumulative-Merkle claims for the 700M community supply. The exact delta is in [`src/distributor/FORK.md`](src/distributor/FORK.md). |
| `staking/StakingRewards.sol` | **fork** of Synthetix | Stake LOOP, earn USDC, streamed over a fixed period after each `notifyRewardAmount`. One change: the reward accumulator's precision is raised from 1e18 to 1e33, because 6-decimal USDC rewards would otherwise round to zero between frequent checkpoints. See [`src/staking/FORK.md`](src/staking/FORK.md). |
| `TreasuryVault.sol` | this project | The revenue splitter. It has no arbitrary-transfer function. `distribute()` is permissionless and rate-limited; it splits USDC that has arrived since the last call between stakers and an operations bucket, and pushes the staker share to `StakingRewards` immediately. The operations bucket leaves only through `opsWithdraw`, which only the owner (the Timelock) can call, to an address the owner chooses. Revenue arrives as a **plain USDC transfer**: `distribute()` works out what accrued from `balanceOf`, so there is no deposit function. The vault knows nothing about betting, never touches the CTF, and does not accept ERC-1155 transfers. |
| `BettingBankroll.sol` | this project | The house's betting capital. It keeps **no accounting**: `usdc.balanceOf(this)` is the whole story. It is an ERC-1271 maker whose `isValidSignature` answers only the exchange, it can only BUY (the exchange is never given a CTF approval, so a SELL reverts when the tokens are pulled), anyone can call `redeem`, and its single exit, `withdrawToTreasury`, pays only its configured treasury address, which is the vault. Its allowance to the exchange is unlimited. The treasury address, the exchange, the signing key and the guardian can each be changed, but only by the owner (the Timelock). |

The header comment of each contract explains its design and its safety properties in
full.

## Vendored code and exact pins

| Path | Upstream | Pin | Licence |
|---|---|---|---|
| `src/distributor/` | [morpho-org/universal-rewards-distributor](https://github.com/morpho-org/universal-rewards-distributor) | `3de504b130835a12482e00e1c83dcf369448c80b` | GPL-2.0-or-later (LICENSE in the directory) |
| `src/staking/` | `synthetix@2.102.1`, the npm registry artifact (the v2 GitHub repository has been taken down) | npm 2.102.1 | MIT (LICENSE in the directory) |
| `lib/openzeppelin-contracts/` | OpenZeppelin v4.9.2 | `e50c24f5839db17f46991478384bfda14acfb830`, the submodule pin the URD was audited against | MIT |
| `lib/openzeppelin-2.3/` | OpenZeppelin v2.3.0, only the files StakingRewards imports | tag `v2.3.0` | MIT |
| `lib/forge-std/` | foundry-rs/forge-std | `97810ebcbede585b7966ec982e5d3e3403a68c7a` (the URD's pin) | MIT / Apache-2.0 |
| `lib/murky/` | dmfxyz/murky, test-only (Merkle tree generation) | `1d9566b908b9702c45d354a1caabe8ef5a69938d` (the URD's pin) | MIT (SPDX headers; upstream ships no LICENSE file) |

Audit provenance: the URD was audited by Cantina (managed review and competition) and by
OpenZeppelin, against the OpenZeppelin 4.9.2 pin above, which is why this project uses
4.9.2 throughout rather than v5. The reports are in the upstream repository. Those audits
cover upstream. They do not cover the changes documented in the two `FORK.md` files, nor
`TreasuryVault` and `BettingBankroll`, which have not been audited.

Synthetix StakingRewards targets solc 0.5.16. Foundry compiles it with a second compiler
automatically.

## Build and test

```bash
forge build
forge test
```

`foundry.toml` sets `bytecode_hash = "none"`, so a build is reproducible from the source
alone and comments do not affect the bytecode.
