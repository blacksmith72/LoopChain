"""Move earned revenue from the TreasuryVault into the BettingBankroll.

Funding the bankroll is a plain USDC transfer, and `opsWithdraw(to, amount)`
already is one:

    distribute()                          permissionless, once per epoch
    opsWithdraw(bankroll, amount)         owner = the Timelock

The timelock delay is correct here precisely because this is RARE: winnings
return to the bankroll directly and compound there, so this call only ever RESIZES
the house's capital. It is a governance decision, not an operational chore.

Safely re-runnable — each run sweeps whatever the ops bucket currently holds.

Needs GUARDIAN_KEY in the environment: the guardian is the timelock's proposer/executor, so
it schedules and executes the `opsWithdraw` leg.

Knobs (env-overridable):
  BANKROLL_FUND  cap on how much of the ops bucket to move (default: all of it)
"""

import os

import config
from config import fmt_usdc, retry_read, send, wait_assert
from deploy_loop import ZERO32, wait_chain_time


def main():
    w3 = config.w3_connect()
    operator = config.accounts()["OPERATOR"]
    guardian = config.Account.from_key(os.environ["GUARDIAN_KEY"])
    d = config.load_deployments()

    vault_abi, _ = config.loop_artifact("TreasuryVault")
    vault = w3.eth.contract(address=d["vault"], abi=vault_abi)
    timelock_abi, _ = config.loop_artifact("TimelockController")
    timelock = w3.eth.contract(address=d["timelock"], abi=timelock_abi)
    usdc = w3.eth.contract(address=config.USDC_ADDRESS, abi=config.ERC20_ABI)

    # ---- 1. distribute accrued revenue (permissionless, once per epoch) ----
    balance = retry_read(usdc.functions.balanceOf(d["vault"]).call)
    ops = retry_read(vault.functions.opsBucket().call)
    staker = retry_read(vault.functions.stakerBucket().call)
    accrued = balance - ops - staker
    if accrued > 0:
        last = retry_read(vault.functions.lastDistributionAt().call)
        epoch = retry_read(vault.functions.distributionEpoch().call)
        now = w3.eth.get_block("latest")["timestamp"]
        if now < last + epoch:
            if config.CHAIN_ID == 31337:
                wait_chain_time(w3, last + epoch - now)
            else:
                print(f"distribution epoch not elapsed — re-run in {last + epoch - now}s")
                return
        send(w3, operator, vault.functions.distribute())
        # the load-balanced RPC can serve the pre-distribute state right after the tx;
        # sizing the transfer from that stale read would skip the ops bucket entirely
        wait_assert(
            lambda: retry_read(vault.functions.lastDistributionAt().call) > last,
            "distribute() not visible on the RPC yet",
        )
        ops = retry_read(vault.functions.opsBucket().call)
        print(f"distributed {fmt_usdc(accrued)} (staker split honored); "
              f"ops bucket now {fmt_usdc(ops)}")
    else:
        print(f"no undistributed revenue — using the existing ops bucket ({fmt_usdc(ops)})")

    # ---- 2. ops bucket -> bankroll (owner = the timelock) ----
    amount = min(ops, int(os.getenv("BANKROLL_FUND", str(ops))))
    if amount == 0:
        print("nothing to move: the ops bucket is empty — earn revenue first")
        return

    before = retry_read(usdc.functions.balanceOf(d["bankroll"]).call)
    call = vault.encode_abi("opsWithdraw", args=[d["bankroll"], amount])
    delay = retry_read(timelock.functions.getMinDelay().call)

    send(w3, guardian, timelock.functions.schedule(
        vault.address, 0, call, ZERO32, ZERO32, delay))
    print(f"timelock: opsWithdraw({fmt_usdc(amount)} -> bankroll) scheduled, "
          f"waiting {delay}s...")
    wait_chain_time(w3, delay)
    send(w3, guardian, timelock.functions.execute(
        vault.address, 0, call, ZERO32, ZERO32))

    # `>=`, not `==`: the bankroll is a live betting contract, so a redeem or a returning
    # win can credit it while we wait. Equality would spin forever on a run that actually
    # succeeded — and the credit is what we are confirming, not the absence of other activity.
    wait_assert(
        lambda: retry_read(usdc.functions.balanceOf(d["bankroll"]).call) >= before + amount,
        "bankroll credit not visible on the RPC yet",
    )
    after = retry_read(usdc.functions.balanceOf(d["bankroll"]).call)
    print(f"bankroll {fmt_usdc(before)} -> {fmt_usdc(after)} — spendable immediately "
          "(the Exchange approval was set once at setExchange and is never re-armed)")


if __name__ == "__main__":
    main()
