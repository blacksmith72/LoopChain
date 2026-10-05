# LoopChain

The smart contracts behind LoopBet, a non-custodial sportsbook where every bet is an
on-chain trade. A bet is an EIP-712 signed order; an operator relays matched orders to the
exchange, which settles them through the Gnosis Conditional Tokens Framework (CTF) on
**Base**, with USDC as collateral.

This repository holds the contracts, their tests, and the scripts that deploy them and
rehearse a full bet from placement to payout. It is public so that anyone can read exactly
what the deployed contracts do.

> **Status: testnet, not audited.** The contracts run on Base Sepolia. The code written for
> this project (the changes to the forked contracts, plus `TreasuryVault` and
> `BettingBankroll`) has **not** been independently audited. The upstream projects were
> audited (see [`ctf-exchange/FORK.md`](ctf-exchange/FORK.md) and
> [`loop/README.md`](loop/README.md)); those audits cover the code as its authors
> published it, not this repository.

## What is here

| Path | What it is |
|---|---|
| [`ctf-exchange/`](ctf-exchange/) | The exchange: a fork of Polymarket CTF Exchange v1. The exact changes are listed in [`ctf-exchange/FORK.md`](ctf-exchange/FORK.md). |
| [`loop/`](loop/) | The `$LOOP` token, the emissions distributor, staking, the `TreasuryVault` (revenue splitter) and the `BettingBankroll` (the house's betting capital). See [`loop/README.md`](loop/README.md). |
| [`lifecycle/`](lifecycle/) | Python scripts that deploy everything and run a complete bet story with exact balance assertions, on a local chain or on Base Sepolia. See [`lifecycle/README.md`](lifecycle/README.md). |
| [`INTERFACE.md`](INTERFACE.md) | Integration reference for the exchange: the order struct, signing, prices, fees, matching and events. |

## How a bet settles

1. A market is one CTF condition with two outcome tokens, YES and NO, registered on the
   exchange.
2. The bettor signs a BUY order for YES; the counterparty signs a BUY order for NO at the
   complementary price.
3. An operator submits both orders to `matchOrders`. The exchange pulls USDC from both
   sides, mints a full set of outcome tokens through the CTF, and hands each side its
   tokens. Nobody needs token inventory up front.
4. When the result is known, the market's oracle reports a payout vector to the CTF.
5. Holders of the winning token redeem it for USDC directly from the CTF.

While a bet is open, the stake sits in the CTF contract as the collateral behind the
outcome tokens, and the tokens sit in the bettor's own wallet.

## Who can do what

These contracts make the operator's actions public and bounded. They do not make the
operator unnecessary, and nothing here should be read as a claim of trustlessness.

- **Operator**: the only role that can execute orders (`fillOrder`, `matchOrders`). It can
  only execute what was signed: price, size, fee and expiry are fixed by the signer.
- **Exchange admin**: registers markets, can pause trading, and can add or remove
  operators and admins. None of this is delayed. Users can cancel their own orders at any
  time, including while trading is paused.
- **Oracle**: reports the result of a market. It is the address named when the market's
  condition is prepared.
- **Timelock** (OpenZeppelin `TimelockController`): owns the vault, the bankroll, staking
  and the distributor. Every parameter change and every withdrawal from the vault's
  operations bucket is scheduled on-chain and waits out a public delay before it executes.
  The delay makes these actions visible in advance; it does not narrow them. The owner
  chooses where an operations withdrawal goes, and it can change which staking contract
  the vault pays, which treasury and exchange the bankroll uses, and which keys act for
  the bankroll.
- **Guardian**: in the current deployment it is the Timelock's proposer and executor, so
  it is the party that schedules everything above. It is also a root updater on the
  distributor: it can submit
  an emissions root, which becomes claimable only after the challenge window, and it can
  veto a pending one. Without any delay it can move the bankroll's balance to the
  bankroll's treasury address (the vault) and cancel the bankroll's open orders.

The `$LOOP` token itself has no owner, no mint function and no upgrade path.

## Deployments

Base Sepolia (testnet):

| Contract | Address |
|---|---|
| ConditionalTokens (unmodified Gnosis CTF) | `0x6A77bf8599b44c8ac68633AEaAEe645e0f5D6844` |
| LoopBet Exchange | `0x9996b356d5d1b23D3f0601311AAB39Bb308100C7` |
| Collateral (Circle testnet USDC) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` |
| LOOP | `0x3E2269FBf9d818711440fC4edf824242CD945e59` |
| Emissions distributor | `0x5Fa66aca28EaA0777b2260DE5a1b8B9455Bca14B` |
| StakingRewards | `0xC40829dCCae60a9cf86712A77dAdce6D6701cbc0` |
| TreasuryVault | `0x38D90a9501E3026dAb896aFFEE709853e4d49f95` |
| BettingBankroll | `0x473E6D4ED60af639B45f383e5d78604636a8B51a` |
| TimelockController | `0xC6129596C94B70107Ba6d77D9280Ec8A1Cba6f05` |

## Build and test

You need [Foundry](https://book.getfoundry.sh/). Dependencies are vendored under each
project's `lib/`, so there is nothing to install and no submodules to fetch.

```bash
cd ctf-exchange && forge build && forge test
cd ../loop && forge build && forge test
```

The exchange test suite deploys the CTF through Foundry's FFI, which shells out to `bash`
and needs `cast`, `jq` and `xxd` on that shell's PATH.

**Windows note.** Forge resolves `bash` to `C:\Windows\System32\bash.exe`, which is WSL, so
those three tools must exist *inside WSL* rather than in Git Bash:

```bash
wsl -u root apt-get install -y jq xxd
wsl -u root bash -c 'curl -sL https://github.com/foundry-rs/foundry/releases/download/v1.7.1/foundry_v1.7.1_linux_amd64.tar.gz | tar xz -C /tmp cast && mv /tmp/cast /usr/local/bin/'
```

Install a native Linux `cast` as shown rather than linking the Windows binary: WSL's
Windows-binary interop can drop when the WSL VM restarts, which breaks the tests.

To run the whole bet story end to end on a local chain, see
[`lifecycle/README.md`](lifecycle/README.md).

## Licences

Code written for this project is released under the MIT licence ([`LICENSE`](LICENSE)).
The repository also contains code from other projects, each under its own licence. The
licence file in a directory, and the SPDX header in a file, always take precedence:

| Path | Origin | Licence |
|---|---|---|
| `ctf-exchange/` | Polymarket CTF Exchange v1 | MIT (`ctf-exchange/LICENSE.md`); a few files under `src/common/` carry `AGPL-3.0-only` headers |
| `loop/src/distributor/` | Morpho Universal Rewards Distributor | GPL-2.0-or-later (`LICENSE` in that directory) |
| `loop/src/staking/` | Synthetix StakingRewards | MIT (`LICENSE` in that directory) |
| `*/lib/` | forge-std, OpenZeppelin, Solady, Solmate, Murky | as stated in each library |

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private
vulnerability reporting on this repository (Security tab, "Report a vulnerability").
