# LoopBet fork of the Polymarket CTF Exchange v1

| | |
|---|---|
| Upstream | https://github.com/Polymarket/ctf-exchange (archived) |
| Pinned commit | `ed5c7708b7be3aa98bf5f0c6602b57cc498e2ef4` |
| Licence | MIT (`LICENSE.md` in this directory) |
| Upstream audit | ChainSecurity (`audit/`). It reviewed upstream and does **not** cover the changes below. |
| `lib/` | forge-std, openzeppelin-contracts, solady, solmate, vendored as plain source at upstream's submodule pins |

`README.md`, `docs/`, `broadcast/` and `deploy/` in this directory are upstream's files,
kept as published. They describe Polymarket's deployment, not this one. In particular
`deploy/scripts/deploy_exchange.sh` predates the `feeRecipient` argument; this project
deploys with the scripts in [`../lifecycle/`](../lifecycle/).

## See the delta yourself

The first commit of this repository is the upstream tree, unmodified. Everything this
project changed in the exchange is therefore one diff:

```bash
git diff $(git rev-list --max-parents=0 HEAD) HEAD -- ctf-exchange ':!ctf-exchange/FORK.md'
```

## Why v1 and not v2

v1 is MIT. v2 is BUSL-1.1, which does not permit production use before its change date
without a commercial licence. v1 also takes the ERC-20 collateral directly, with no
wrapper token. **Never copy code from the v2 repository into this fork.** Adaptations are
written fresh from specifications or from MIT sources.

## Changes

Two changed values and one functional change. ERC-1271 signature validation needed no
change: this upstream commit already implements and tests it.

| File | Change | Test |
|---|---|---|
| `src/exchange/CTFExchange.sol` | EIP-712 domain name `"Polymarket CTF Exchange"` becomes `"LoopBet Exchange"`. The version stays `"1"`. | `testHashOrder` golden hash recomputed |
| `src/exchange/mixins/Fees.sol` | `MAX_FEE_RATE_BIPS` lowered from `1000` to `500`: no order can carry a fee above 5%. | `testWithFees` lowered to the new cap |
| `src/exchange/mixins/Trading.sol`, `interfaces/ITrading.sol`, `CTFExchange.sol` constructor, `scripts/ExchangeDeployment.s.sol` | An immutable **`feeRecipient`** (constructor argument) replaces `msg.sender` as the destination at both `_chargeFee` call sites. Upstream paid fees to whichever operator relayed the fill; here they go to one fixed address that no admin can change. The constructor rejects the zero address with a new error, `InvalidFeeRecipient`, declared in `ITrading.sol`. The Foundry deployment script takes the extra argument. | `MatchOrders.t.sol` expectations moved from the caller to a separate `feeRecipient`; `testConstructorRevertsOnZeroFeeRecipient` |

Things worth knowing about the fee change:

- It covers `matchOrders`. On `fillOrder` and `fillOrders`, where the operator is itself
  the counterparty, upstream collects the fee implicitly (the caller pays out proceeds
  minus the fee and keeps the difference), so there is no transfer to redirect and that
  behaviour is unchanged.
- Fill-time fees are not in use: orders are signed with `feeRateBps = 0`. In the current
  deployment the `feeRecipient` is the `TreasuryVault`, which does not accept ERC-1155
  transfers, so an order that charged its fee in outcome tokens would revert rather than
  move tokens.

## Other differences from upstream

- `artifacts/CTFExchange.json` removed. It was upstream's prebuilt exchange artifact,
  which no longer matches the source; use the `forge build` output.
- `snapshots/GasSnapshots_Test.json` regenerated for the modified contract.
- `foundry.lock` removed. It pins submodule revisions, and the dependencies here are plain
  vendored source.
