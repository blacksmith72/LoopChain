"""Deploy ConditionalTokens (unmodified Gnosis CTF) + LoopBet Exchange to Base Sepolia.

Prereqs: `forge build` in ../ctf-exchange (exchange ABI comes from out/), and the
OPERATOR address funded with Base Sepolia ETH (see README.md for faucets).
"""

import config
from config import EXPLORER, USDC_ADDRESS, fmt_usdc, retry_read, send, wait_for_code


def main():
    w3 = config.w3_connect()
    acct = config.accounts()["OPERATOR"]
    lp = config.accounts()["LP"]
    user = config.accounts()["USER"]

    eth = w3.eth.get_balance(acct.address)
    print(f"deployer (operator/admin): {acct.address}  balance: {eth / 1e18:.6f} ETH")
    if eth < 3 * 10**14:  # 0.0003 ETH ~= 3 CDP faucet claims
        print("\nInsufficient gas. Fund the deployer with Base Sepolia ETH first:")
        print("  https://portal.cdp.coinbase.com/products/faucet  (0.0001 ETH/claim - claim 3+ times)")
        print(f"  address: {acct.address}")
        return

    # 1. Gnosis ConditionalTokens — deployed byte-for-byte unmodified
    ctf_abi, ctf_bytecode = config.ctf_artifact()
    ctf_contract = w3.eth.contract(abi=ctf_abi, bytecode=ctf_bytecode)
    receipt = send(w3, acct, ctf_contract.constructor())
    ctf_address = receipt["contractAddress"]
    print(f"ConditionalTokens: {EXPLORER}/address/{ctf_address}")

    # 2. LoopBet Exchange — fork of CTF Exchange v1
    #    proxy/safe factories = zero address (signature types 1/2 unused, see INTERFACE.md)
    #    feeRecipient = operator for this stage-1 deploy (upstream v1 behavior); deploy_loop.py
    #    later redeploys the exchange with the treasury vault as the immutable fee sink.
    exch_abi, exch_bytecode = config.exchange_artifact()
    zero = "0x" + "0" * 40
    exch_contract = w3.eth.contract(abi=exch_abi, bytecode=exch_bytecode)
    receipt = send(w3, acct, exch_contract.constructor(USDC_ADDRESS, ctf_address, zero, zero, acct.address))
    exch_address = receipt["contractAddress"]
    print(f"LoopBet Exchange:  {EXPLORER}/address/{exch_address}")

    # 3. Sanity checks against INTERFACE.md expectations
    #    (reads retried: the public RPC may serve replicas lagging behind the deploy)
    wait_for_code(w3, exch_address)
    exchange = w3.eth.contract(address=exch_address, abi=exch_abi)
    assert retry_read(exchange.functions.getCollateral().call) == USDC_ADDRESS
    assert retry_read(exchange.functions.getCtf().call) == ctf_address
    assert retry_read(exchange.functions.isAdmin(acct.address).call)
    assert retry_read(exchange.functions.isOperator(acct.address).call)
    assert retry_read(exchange.functions.getMaxFeeRate().call) == 500, "MAX_FEE_RATE_BIPS must be 500"
    print("sanity checks passed (collateral, ctf, roles, 5% fee cap)")

    # 4. Gas dust for LP + user (their few txs cost ~0.00001 ETH at Base Sepolia prices)
    for who, name in ((lp, "LP"), (user, "USER")):
        if w3.eth.get_balance(who.address) < 2 * 10**13:
            send(w3, acct, {"to": who.address, "gas": 21000}, value=5 * 10**13)  # 0.00005 ETH
            print(f"sent 0.00005 ETH gas to {name} {who.address}")

    config.save_deployments(
        {"chainId": config.CHAIN_ID, "usdc": USDC_ADDRESS, "ctf": ctf_address, "exchange": exch_address}
    )
    print("\nwrote deployments.json")

    usdc = w3.eth.contract(address=USDC_ADDRESS, abi=config.ERC20_ABI)
    for who, name in ((lp, "LP"), (user, "USER")):
        bal = usdc.functions.balanceOf(who.address).call()
        print(f"{name} USDC: {fmt_usdc(bal)}" + ("  <- needs >= 16 USDC from https://faucet.circle.com" if bal < 16 * 10**6 else ""))


if __name__ == "__main__":
    main()
