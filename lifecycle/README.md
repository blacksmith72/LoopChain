# Lifecycle: deploy and rehearse a full bet

Python scripts that deploy the contracts and then run the whole story of a bet (**bet,
match, resolve, redeem**, including both ways of voiding a market) on a mock three-way
fixture, asserting every balance exactly. They run against a local chain or against Base
Sepolia.

| Script | What it does |
|---|---|
| `gen_keys.py` | Generates throwaway testnet keys into `.env` |
| `deploy.py` | Deploys the ConditionalTokens contract and the exchange |
| `deploy_loop.py` | Deploys the Timelock, distributor, LOOP, staking, vault and bankroll, then redeploys the exchange with the vault as its `feeRecipient` |
| `lifecycle.py` | Runs the bet story and asserts the result |
| `fund_bankroll.py` | Moves revenue from the vault's operations bucket into the bankroll, through the timelock |
| `redeem_bankroll_position.py` | Redeems one resolved bankroll position (permissionless) |
| `rehearse_local.py` | Runs all of the above against a local anvil chain |
| `orders.py` | Minimal EIP-712 order construction and signing |
| `config.py` | Shared helpers: connection, accounts, artifacts, transaction sending |

## Setup

```bash
cd lifecycle
python -m venv .venv
.venv/bin/pip install -r requirements.txt        # Windows: .venv\Scripts\pip
```

The scripts read contract ABIs and bytecode from the Foundry build output, so run
`forge build` in both `../ctf-exchange` and `../loop` first.

## Local rehearsal (no testnet, no funding)

```bash
anvil                                   # in a separate terminal
.venv/bin/python rehearse_local.py      # Windows: .venv\Scripts\python
```

This uses anvil's well-known development keys and a mintable mock USDC, and exercises the
same code paths as a testnet run. It has three stages: deploy and run the lifecycle
against the first exchange; deploy the `$LOOP` contracts, redeploy the exchange and run
the lifecycle again; then fund the bankroll and run it a third time with the bankroll as
the maker of one market.

`deploy_loop.py` needs four more role keys: `GUARDIAN_KEY`, `ROOT_POSTER_KEY`,
`FOUNDERS_KEY` and `MAKER_KEY`. Any that are missing from the environment are generated
and appended to `.env`. The local rehearsal supplies `MAKER_KEY` itself.

## Testnet run (Base Sepolia)

```bash
.venv/bin/python gen_keys.py
```

writes three throwaway keys (`OPERATOR`, `LP`, `USER`) to `.env` and prints their
addresses. **`.env` holds private keys. It is gitignored; keep it that way, and never
reuse these keys anywhere that holds real funds.**

1. Fund the accounts:
   - `OPERATOR` needs a little Base Sepolia ETH, for example from
     https://portal.cdp.coinbase.com/products/faucet. The deploy script forwards gas dust
     to the other accounts.
   - `LP` and `USER` need about 20 test USDC each from https://faucet.circle.com
     (network: Base Sepolia).
2. Deploy and run:
   ```bash
   .venv/bin/python deploy.py          # CTF + exchange, writes deployments.json
   .venv/bin/python lifecycle.py       # the bet story, asserted
   .venv/bin/python deploy_loop.py     # the $LOOP contracts + exchange redeploy
   .venv/bin/python lifecycle.py       # same story against the new exchange
   ```

`deploy_loop.py` takes its parameters (challenge window, timelock delay, staker share,
distribution epoch, reward duration) from the environment. The defaults, listed in the
script's header, are short values meant for testing. Addresses are written to
`deployments.json`, which is per-machine state and is gitignored.

The public Base Sepolia RPC is load-balanced and a replica can lag a few seconds behind
your latest transaction. `config.py` retries reads and tracks nonces locally for that
reason; see the docstring of `retry_read` before trusting a read made right after a
transaction.

## Funding the bankroll and redeeming its positions

```bash
.venv/bin/python fund_bankroll.py
.venv/bin/python redeem_bankroll_position.py <conditionId>
```

`fund_bankroll.py` calls the permissionless `distribute()` and then schedules and executes
a timelocked `opsWithdraw(bankroll, amount)`. The delay applies because this call sets the
*size* of the house's capital. It is not part of routine operation: winnings return to the
bankroll by themselves.

`redeem_bankroll_position.py` calls the bankroll's own `redeem(conditionId)`. The CTF's
`redeemPositions` pays whoever calls it for the tokens *they* hold, so only the bankroll
can redeem the bankroll's tokens, and `redeem` lets anyone trigger that. The proceeds are
spendable as soon as they land.

## What the lifecycle asserts

Stake 4 USDC, odds 2.00, fee 0 on every order:

| Party | Outcome | P&L |
|---|---|---|
| USER | wins MADRID at 2x, loses DRAW and BARCA, is refunded on the voided market | **-4.00 USDC** |
| LP | collects the two lost stakes, is refunded on the voided market | **+4.00 USDC** |
| VAULT | untouched: no fee is charged at fill time | **0.00 USDC** |

The totals are asserted to be zero-sum.

Once the bankroll is funded (stage 3) a fifth market, HOUSE, is added with the bankroll as
its maker. The user loses that bet too, so the result becomes USER **-8.00**, LP
**+4.00**, HOUSE **+4.00**. This leg asserts the point of keeping the bankroll separate:
`balanceOf(bankroll)` ends at exactly its starting balance plus the profit, with no
timelocked call anywhere in the loop.

The ABANDONED market is voided with a `[1,1]` payout vector. That refunds the stake
exactly only because every bet in the demo is at 50c: CTF redemption pays per *token*, not
per stake.

### Step 7: exact-stake void by unwinding

A separate UNWOUND market rehearses refunding stakes exactly when fills happened at
**different** prices (50c and 80c), which no payout vector can do. Each fill is unwound at
cost through the exchange (the user sells YES and the counterparty buys it back at exactly
the fill price, fee 0 on both sides), and `[0,1]` is reported only once no bettor holds
tokens. The script asserts that the user is refunded to the base unit and that every
party's P&L on the leg is exactly zero. See *Voiding a market* in
[`../INTERFACE.md`](../INTERFACE.md).
