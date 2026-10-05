"""Redeem one resolved condition into the betting bankroll (permissionless).

The CTF's `redeemPositions` burns msg.sender's tokens, so no other account can
redeem on the bankroll's behalf. This drives the bankroll's own
`redeem(conditionId)`, which anyone may call.

    python redeem_bankroll_position.py <conditionId>

That is the whole command. There is no timelock step and no GUARDIAN_KEY: the
Exchange allowance is unlimited and set once at `setExchange`, so redeem proceeds
are spendable the moment they land.

Prints the balance before and after, pinned to the transaction's own block.
"""

import sys

from eth_utils import to_hex
from web3.logs import DISCARD

import config
from config import fmt_usdc, retry_read, send


def main():
    args = sys.argv[1:]
    if len(args) != 1:
        raise SystemExit("usage: redeem_bankroll_position.py <conditionId>")
    condition_id = args[0]
    if not condition_id.startswith("0x") or len(condition_id) != 66:
        raise SystemExit(f"conditionId must be 0x + 64 hex chars, got {condition_id!r}")

    w3 = config.w3_connect()
    operator = config.accounts()["OPERATOR"]
    d = config.load_deployments()
    bankroll_abi, _ = config.loop_artifact("BettingBankroll")
    bankroll = w3.eth.contract(address=d["bankroll"], abi=bankroll_abi)
    usdc = w3.eth.contract(address=config.USDC_ADDRESS, abi=config.ERC20_ABI)

    def balance(block="latest"):
        # Pin the AFTER read to the tx's own block. At "latest" a lagging replica
        # returns PRE-tx values *successfully*, so retry_read (which only retries
        # on exception) passes the stale number straight through, reporting a
        # delta of 0 on a redeem that did move funds. Pinning converts
        # silent staleness into a "block not found" raise, which retry_read then
        # correctly retries until the replica catches up.
        return retry_read(
            lambda: usdc.functions.balanceOf(d["bankroll"]).call(block_identifier=block)
        )

    before = balance()
    print(f"=== BEFORE ===\n  bankroll {before:>12}  {fmt_usdc(before)}")

    receipt = send(w3, operator, bankroll.functions.redeem(condition_id))
    print(f"\nredeem({condition_id[:14]}…) tx={receipt['transactionHash'].hex()} "
          f"block={receipt['blockNumber']} gas={receipt['gasUsed']}")

    # Decoded by event name, from the build artifact's ABI.
    print("\n=== EVENTS ===")
    found = False
    for log in bankroll.events.Redeemed().process_receipt(receipt, errors=DISCARD):
        found = True
        amount = log["args"]["usdcRedeemed"]
        print(f"  Redeemed: condition={to_hex(log['args']['conditionId'])} "
              f"usdcRedeemed={amount} -> {fmt_usdc(amount)}")
    if not found:
        print("  (no Redeemed event in this receipt)")

    # Delta across the tx's OWN block boundary, not against the pre-flight read.
    # The pre-flight snapshot is taken at "latest" before broadcasting, so it can
    # be stale AND can miss anything that landed in between (for example bets
    # confirming between the two reads). Pinning both ends isolates this tx.
    blk = receipt["blockNumber"]
    pre, after = balance(blk - 1), balance(blk)
    drift = pre - before
    note = f"   [pre-flight read was off by {drift:+d}]" if drift else ""
    sign = "+" if after > pre else ""
    print(f"\n=== AFTER (delta across block {blk}) ===")
    print(f"  bankroll {after:>12}  {fmt_usdc(after):>12}   "
          f"delta {sign}{after - pre}{note}")
    print("\nProceeds are spendable immediately — no timelock.")


if __name__ == "__main__":
    main()
