"""Full on-chain bet lifecycle, on Base Sepolia or a local chain.

Fixture: mock "Madrid vs Barcelona" as a back-only 1X2 — three binary markets
(MADRID / DRAW / BARCA) plus a market on a separate ABANDONED match (-> void/refund).

Per market: USER backs YES with 4 USDC at 50c (odds 2.00, fee 0); LP backs the
complementary NO at 50c, also fee 0. The operator matches both BUYs -> MINT
settlement (zero token inventory needed).

NOTE: every order signs feeRateBps = 0. Fill-time fees are not in use: the
TreasuryVault does not implement the ERC-1155 receiver hooks, and a BUY order's
fee is charged in outcome tokens, so a fee-bearing fill would revert.
Step 3 asserts the vault stays flat through every fill.

Result: Madrid wins. USER redeems the Madrid market at 2x, loses DRAW/BARCA;
LP collects the other side; the ABANDONED market refunds both via a
[1,1] vector (exact only because every demo bet is at 50c).

Step 7 rehearses the exact-stake void by unwinding (see ../INTERFACE.md ->
Voiding a market): a separate UNWOUND market takes two
fills at DIFFERENT prices (50c and 80c) — the case no payout vector can ever
refund exactly — then each fill is unwound at cost through the Exchange
(user SELL-YES vs house BUY-YES at bit-for-bit the fill price, fee 0 both sides),
and only then [0,1] is reported so the house's bought-back inventory redeems.
Asserts the user is refunded to the base unit and the leg is zero-sum.

Stage 2 (after deploy_loop.py) exercises the house as maker: a fifth market (HOUSE)
where the maker side is the BettingBankroll — an ERC-1271 order (signatureType 3,
maker = signer = bankroll) signed by the MAKER role key, paid straight out of the
bankroll's USDC balance. The house wins, anyone redeems, and principal + profit are
simply back in the balance: no budget to re-arm, no accounting to reconcile, and no
timelocked call anywhere in the loop. Skipped automatically when the bankroll is not
wired or is not funded. Every balance change is exact.
"""

import os
import secrets
import time

import config
import orders as O
from config import EXPLORER, fmt_usdc, send, wait_assert

STAKE = 4_000_000        # 4 USDC per bet
PRICE_CENTS = 50         # 50c => decimal odds 2.00
TOKENS = STAKE * 100 // PRICE_CENTS  # 8_000_000 outcome tokens per bet
LP_FEE_BPS = 0           # fill-time fees are not in use (header note)
# CalculatorHelper (BUY): fee = bps * min(p,1-p) * tokens / (p * 10_000) = 160_000 at 50c
LP_FEE_TOKENS = LP_FEE_BPS * TOKENS // 10_000   # 0 — kept so the fee math stays visible

# MADRID/DRAW/BARCA = the 1X2 fixture; ABANDONED = a separate match whose event is
# called off -> resolved as void (a resolution state, not a bettable outcome).
# ABANDONED demonstrates a vector void:
# [1,1] == exact stake refund ONLY because all demo bets are at 50c (per-token payout).
# The exact-stake unwind is rehearsed in step 7.
# HOUSE (stage 3 only) = a market made by the BettingBankroll itself; NO wins -> the house
# collects, proving the whole cycle fund -> fill -> redeem with no governance action in it.
MARKETS = ["MADRID", "DRAW", "BARCA", "ABANDONED"]
PAYOUTS = {"MADRID": [1, 0], "DRAW": [0, 1], "BARCA": [0, 1], "ABANDONED": [1, 1], "HOUSE": [0, 1]}

# Step 7 (UNWOUND market): the exact-stake void unwind at two DIFFERENT prices.
# 50c -> 8 tokens need vector 0.5; 80c -> 5 tokens need 0.8 — no single per-token
# vector refunds both, which is the entire point of the unwind path. NO-side
# prices stay <= 50c, so the LP fee is exactly bps * tokens / 10_000.
def _unwind_fill(price_cents: int) -> tuple:
    tokens = STAKE * 100 // price_cents
    return price_cents, tokens, tokens - STAKE, LP_FEE_BPS * tokens // 10_000

UNWIND_FILLS = [_unwind_fill(p) for p in (50, 80)]  # (price, tokens, LP NO collateral, LP fee tokens)
UNWIND_USER_NEED = len(UNWIND_FILLS) * STAKE  # returned in full by the unwind
UNWIND_LP_NEED = sum(no for _, _, no, _ in UNWIND_FILLS) + len(UNWIND_FILLS) * STAKE

ZERO32 = b"\x00" * 32


def main():
    w3 = config.w3_connect()
    acc = config.accounts()
    operator, lp, user = acc["OPERATOR"], acc["LP"], acc["USER"]
    d = config.load_deployments()

    usdc = w3.eth.contract(address=d["usdc"], abi=config.ERC20_ABI)
    ctf_abi, _ = config.ctf_artifact()
    ctf = w3.eth.contract(address=d["ctf"], abi=ctf_abi)
    exch_abi, _ = config.exchange_artifact()
    exchange = w3.eth.contract(address=d["exchange"], abi=exch_abi)

    # Stage detection: post-deploy_loop the $LOOP stack exists (TreasuryVault +
    # BettingBankroll). The vault is the exchange's immutable feeRecipient, but every
    # order signs fee 0, so it must stay FLAT through every fill — that is the retired
    # fee-token path, asserted rather than assumed.
    vault = d.get("vault") or ""
    bankroll = None
    if d.get("bankroll"):
        bankroll_abi, _ = config.loop_artifact("BettingBankroll")
        bankroll = w3.eth.contract(address=d["bankroll"], abi=bankroll_abi)
    print("stage:", "$LOOP stack deployed" if vault else "pre-$LOOP (operator-fee exchange)")

    # House leg: the bankroll as maker, spending its own USDC balance. Nothing to arm and
    # nothing to book — the stake is sized to whatever the bankroll has actually been given.
    maker_key = os.getenv("MAKER_KEY")
    bankroll_before = usdc.functions.balanceOf(d["bankroll"]).call() if bankroll else 0
    house = bool(bankroll and maker_key and bankroll_before > 0)
    markets = MARKETS + ["HOUSE"] if house else MARKETS
    if house:
        maker_acct = config.Account.from_key(maker_key)
        house_stake = min(STAKE, bankroll_before)
        house_tokens = house_stake * 100 // PRICE_CENTS
        print(f"house-maker leg (HOUSE): on — bankroll {fmt_usdc(bankroll_before)}, "
              f"house stake {fmt_usdc(house_stake)}")
    else:
        house_stake = house_tokens = 0
        print("house-maker leg (HOUSE): off (bankroll not wired or unfunded — "
              "run fund_bankroll.py after revenue accrues)")

    def usdc_of(a):
        return usdc.functions.balanceOf(a.address if hasattr(a, "address") else a).call()

    tracked = [("USER", user), ("LP", lp), ("OP", operator)]
    if vault:
        tracked.append(("VAULT", vault))
    if house:
        tracked.append(("HOUSE", d["bankroll"]))
    start = {who: usdc_of(a) for who, a in tracked}
    print("starting USDC:", {k: fmt_usdc(v) for k, v in start.items()})
    for who, a, need in (("USER", user, 4 * STAKE + house_stake + UNWIND_USER_NEED),
                         ("LP", lp, 4 * STAKE + UNWIND_LP_NEED)):
        if start[who] < need:
            print(f"\n{who} needs {fmt_usdc(need)} - get testnet USDC at https://faucet.circle.com")
            print(f"  (Base Sepolia, address: {a.address})")
            return

    # ---- 1. Fixture: 4 binary markets (prepareCondition + registerToken) ----
    print("\n[1] creating fixture markets")
    fixture = {}
    for name in markets:
        question_id = secrets.token_bytes(32)
        send(w3, operator, ctf.functions.prepareCondition(operator.address, question_id, 2))
        condition_id = ctf.functions.getConditionId(operator.address, question_id, 2).call()
        pos = {}
        for outcome, index_set in (("YES", 1), ("NO", 2)):
            coll = ctf.functions.getCollectionId(ZERO32, condition_id, index_set).call()
            pos[outcome] = ctf.functions.getPositionId(d["usdc"], coll).call()
        send(w3, operator, exchange.functions.registerToken(pos["YES"], pos["NO"], condition_id))
        fixture[name] = {"questionId": question_id, "conditionId": condition_id, **pos}
        print(f"  {name}: registered (YES={pos['YES'] % 10**8}..., NO={pos['NO'] % 10**8}...)")

    # ---- 2. Approvals: both parties allow the exchange to pull USDC ----
    print("\n[2] USDC approvals")
    for a in (user, lp):
        if usdc.functions.allowance(a.address, d["exchange"]).call() < 100 * STAKE:
            send(w3, a, usdc.functions.approve(d["exchange"], 2**256 - 1))
    print("  approved")

    # ---- 3. Bets: sign orders off-chain, operator matches on-chain (MINT) ----
    print("\n[3] placing bets (user backs YES, LP/bankroll backs NO, operator relays)")
    expiration = int(time.time()) + 3600
    for name in markets:
        stake = house_stake if name == "HOUSE" else STAKE
        taker = O.sign_order(
            O.buy_order(user, operator.address, fixture[name]["YES"], stake, PRICE_CENTS, expiration),
            user, config.CHAIN_ID, d["exchange"],
        )
        if name == "HOUSE":
            # The bankroll is the maker: maker = signer = bankroll, ERC-1271
            # (signatureType 3), signed by the MAKER role key. feeRateBps 0 — house
            # orders never carried a commission.
            maker = O.sign_order(
                O.Order(
                    maker=d["bankroll"], signer=d["bankroll"], taker=operator.address,
                    tokenId=fixture[name]["NO"], makerAmount=house_stake, takerAmount=house_tokens,
                    expiration=expiration, signatureType=O.SIG_POLY_1271,
                ),
                maker_acct, config.CHAIN_ID, d["exchange"],
            )
        else:
            maker = O.sign_order(
                O.buy_order(lp, operator.address, fixture[name]["NO"], STAKE, PRICE_CENTS, expiration,
                            fee_rate_bps=LP_FEE_BPS),
                lp, config.CHAIN_ID, d["exchange"],
            )
        receipt = send(w3, operator,
                       exchange.functions.matchOrders(taker.as_tuple(), [maker.as_tuple()], stake, [stake]))
        print(f"  {name}: matched  {EXPLORER}/tx/0x{receipt['transactionHash'].hex().removeprefix('0x')}")

    # on-chain position checks (polled: public RPC replicas may lag the latest tx)
    for name in markets:
        f = fixture[name]
        expected_yes = house_tokens if name == "HOUSE" else TOKENS
        wait_assert(lambda f=f, t=expected_yes: ctf.functions.balanceOf(user.address, f["YES"]).call() == t,
                    f"{name}: user YES position")
        if name == "HOUSE":
            wait_assert(lambda f=f: ctf.functions.balanceOf(d["bankroll"], f["NO"]).call() == house_tokens,
                        "HOUSE: bankroll NO position")
        else:
            wait_assert(lambda f=f: ctf.functions.balanceOf(lp.address, f["NO"]).call() == TOKENS,
                        f"{name}: LP NO position")
            if vault:
                # The retired fee-token path: fee 0 means the feeRecipient is skipped
                # entirely. (It could not receive tokens now even if a fee were signed.)
                wait_assert(lambda f=f: ctf.functions.balanceOf(vault, f["NO"]).call() == 0,
                            f"{name}: vault holds no fee position (path retired)")
    wait_assert(lambda: usdc_of(user) == start["USER"] - 4 * STAKE - house_stake, "user USDC spent")
    wait_assert(lambda: usdc_of(lp) == start["LP"] - 4 * STAKE, "LP USDC spent")
    if house:
        # Spend is the balance going down. There is no allowance to sample and no
        # odometer to sync — that is the entire point of the separate contract.
        wait_assert(
            lambda: usdc.functions.balanceOf(d["bankroll"]).call() == bankroll_before - house_stake,
            "HOUSE: bankroll balance drawn down by the fill",
        )
    print(f"  positions verified: user {TOKENS / 1e6:.0f} YES/market, "
          f"LP {TOKENS / 1e6:.2f} NO/market, no fee positions anywhere")

    # ---- 4. Resolution: operator (as oracle) reports payout vectors ----
    print("\n[4] resolving: Madrid wins; ABANDONED match voids (vector [1,1])"
          + ("; HOUSE market: NO wins (the house collects)" if house else ""))
    for name in markets:
        send(w3, operator, ctf.functions.reportPayouts(fixture[name]["questionId"], PAYOUTS[name]))
        print(f"  {name}: {PAYOUTS[name]}")

    # ---- 5. Redemption ----
    print("\n[5] redeeming")

    def redeem(a, market, index_sets):
        send(w3, a, ctf.functions.redeemPositions(d["usdc"], ZERO32, fixture[market]["conditionId"], index_sets))

    redeem(user, "MADRID", [1])      # won: 8 tokens -> 8 USDC
    redeem(user, "ABANDONED", [1])   # void refund: 8 tokens * 0.5 -> 4 USDC (stake back)
    for market in ("DRAW", "BARCA", "ABANDONED"):
        redeem(lp, market, [2])
    if house:
        # The bankroll's winning maker position. Permissionless, and there is no
        # accounting behind it: principal and profit simply land in the balance.
        send(w3, operator, bankroll.functions.redeem(fixture["HOUSE"]["conditionId"]))

    # ---- 6. P&L assertions (exact, zero-sum) ----
    print("\n[6] final accounting")
    half = TOKENS // 2
    # HOUSE leg: the bankroll stakes house_stake and redeems the full payout.
    house_pnl = house_tokens - house_stake
    expected = {
        # stakes on every market, + Madrid win (2x), + VOID refund (HOUSE is a loss)
        "USER": -4 * STAKE - house_stake + TOKENS + half,
        # -4 stakes, + DRAW + BARCA wins + half VOID. No commission is skimmed at fill.
        "LP": -4 * STAKE + 2 * TOKENS + half,
        # every order signs fee 0, so nothing reaches the operator either
        "OP": 0,
        # the feeRecipient is untouched — the fill-time fee path is retired
        "VAULT": 0,
        # the house's own book: the whole win, straight back into the bankroll
        "HOUSE": house_pnl,
    }
    parties = {"USER": user, "LP": lp, "OP": operator}
    if vault:
        parties["VAULT"] = vault
    if house:
        parties["HOUSE"] = d["bankroll"]
    for who, a in parties.items():
        wait_assert(lambda w=who, a=a: usdc_of(a) - start[w] == expected[w],
                    f"{who} P&L: expected {fmt_usdc(expected[who])}, got {fmt_usdc(usdc_of(a) - start[who])}")
        print(f"  {who:4} P&L: {(usdc_of(a) - start[who]) / 1e6:+.2f} USDC  OK")
    assert sum(usdc_of(a) - start[w] for w, a in parties.items()) == 0, "not zero-sum"

    if house:
        # The whole post-bet accounting check, in one line: the bankroll is exactly what
        # it started with plus the profit. Nothing to write off, nothing to re-arm.
        wait_assert(
            lambda: usdc.functions.balanceOf(d["bankroll"]).call()
            == bankroll_before + house_pnl,
            "HOUSE: principal + profit back in the bankroll",
        )
        # And the Exchange approval was never touched by any of it.
        wait_assert(
            lambda: usdc.functions.allowance(d["bankroll"], d["exchange"]).call()
            >= bankroll_before + house_pnl,
            "HOUSE: standing allowance still covers the bankroll (never re-armed)",
        )
        print(f"  house-maker leg verified: bankroll {fmt_usdc(bankroll_before)} -> "
              f"{fmt_usdc(bankroll_before + house_pnl)}, profit +{fmt_usdc(house_pnl)}, "
              "no governance action needed")

    # ---- 7. Exact-stake void unwind ----
    # A fresh UNWOUND market takes two fills at different prices, then is voided
    # by unwinding: nothing reported on-chain, each fill unwound at cost (user
    # SELL-YES vs house BUY-YES at bit-for-bit the fill price, fee 0), and [0,1]
    # reported only once no bettor holds tokens.
    print("\n[7] exact-stake void unwind: fills at "
          + " + ".join(f"{p}c" for p, *_ in UNWIND_FILLS)
          + " (no payout vector could refund both), then unwind + finalize [0,1]")
    leg_start = {who: usdc_of(a) for who, a in parties.items()}

    question_id = secrets.token_bytes(32)
    send(w3, operator, ctf.functions.prepareCondition(operator.address, question_id, 2))
    condition_id = ctf.functions.getConditionId(operator.address, question_id, 2).call()
    pos = {}
    for outcome, index_set in (("YES", 1), ("NO", 2)):
        coll = ctf.functions.getCollectionId(ZERO32, condition_id, index_set).call()
        pos[outcome] = ctf.functions.getPositionId(d["usdc"], coll).call()
    send(w3, operator, exchange.functions.registerToken(pos["YES"], pos["NO"], condition_id))

    expiration = int(time.time()) + 3600
    for price, tokens, lp_no, _fee in UNWIND_FILLS:
        taker = O.sign_order(
            O.buy_order(user, operator.address, pos["YES"], STAKE, price, expiration),
            user, config.CHAIN_ID, d["exchange"],
        )
        maker = O.sign_order(
            O.buy_order(lp, operator.address, pos["NO"], lp_no, 100 - price, expiration,
                        fee_rate_bps=LP_FEE_BPS),
            lp, config.CHAIN_ID, d["exchange"],
        )
        send(w3, operator,
             exchange.functions.matchOrders(taker.as_tuple(), [maker.as_tuple()], STAKE, [lp_no]))
        print(f"  fill at {price}c: {fmt_usdc(STAKE)} -> {tokens / 1e6:.0f} YES tokens")
    total_tokens = sum(t for _, t, _, _ in UNWIND_FILLS)
    wait_assert(lambda: ctf.functions.balanceOf(user.address, pos["YES"]).call() == total_tokens,
                "UNWOUND: user YES position")

    # Void moment: the market stops trading, NOTHING is reported on-chain. The
    # user's one-time ERC-1155 approval,
    # then each fill unwinds COMPLEMENTARY at exactly its original price.
    if not ctf.functions.isApprovedForAll(user.address, d["exchange"]).call():
        send(w3, user, ctf.functions.setApprovalForAll(d["exchange"], True))
    for price, tokens, _lp_no, _fee in UNWIND_FILLS:
        sell = O.sign_order(
            O.Order(maker=user.address, signer=user.address, taker=operator.address,
                    tokenId=pos["YES"], makerAmount=tokens, takerAmount=STAKE,
                    expiration=expiration, side=O.SIDE_SELL),
            user, config.CHAIN_ID, d["exchange"],
        )
        buyback = O.sign_order(
            O.buy_order(lp, operator.address, pos["YES"], STAKE, price, expiration),
            lp, config.CHAIN_ID, d["exchange"],
        )
        send(w3, operator,
             exchange.functions.matchOrders(sell.as_tuple(), [buyback.as_tuple()], tokens, [STAKE]))
        print(f"  unwound the {price}c fill: {tokens / 1e6:.0f} tokens -> {fmt_usdc(STAKE)} back")
    wait_assert(lambda: ctf.functions.balanceOf(user.address, pos["YES"]).call() == 0,
                "UNWOUND: no bettor tokens left (finalize precondition)")
    wait_assert(lambda: usdc_of(user) == leg_start["USER"],
                "UNWOUND: user refunded to the base unit")

    # Finalize: only house wallets hold tokens now, so [0,1] is pure
    # internal bookkeeping — the house's NO redeems 1:1, its bought-back YES
    # redeems 0 by construction.
    send(w3, operator, ctf.functions.reportPayouts(question_id, [0, 1]))
    send(w3, lp, ctf.functions.redeemPositions(d["usdc"], ZERO32, condition_id, [1, 2]))

    # Zero-sum to the base unit, and now zero on every line: at fee 0 the unwind
    # costs the house nothing — the LP recovers exactly what it laid out.
    expected_leg = {"USER": 0, "LP": 0, "OP": 0, "VAULT": 0, "HOUSE": 0}
    for who, a in parties.items():
        wait_assert(lambda w=who, a=a: usdc_of(a) - leg_start[w] == expected_leg[w],
                    f"UNWOUND {who} P&L: expected {fmt_usdc(expected_leg[who])}, "
                    f"got {fmt_usdc(usdc_of(a) - leg_start[who])}")
        print(f"  {who:4} leg P&L: {(usdc_of(a) - leg_start[who]) / 1e6:+.2f} USDC  OK")
    assert sum(usdc_of(a) - leg_start[w] for w, a in parties.items()) == 0, "unwind leg not zero-sum"

    print("\nlifecycle complete: bet -> match -> resolve -> redeem (incl. vector void"
          + (" + house-maker leg" if house else "")
          + " + exact-stake unwind void) all verified")


if __name__ == "__main__":
    main()
