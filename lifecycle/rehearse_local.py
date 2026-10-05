"""Dress rehearsal of deploy.py + deploy_loop.py + lifecycle.py against a local anvil chain.

Run `anvil` first, then this script. Uses anvil's pre-funded dev accounts and the
fork's mintable mock USDC, but exercises the exact same code paths (EIP-712 signing,
matchOrders, resolution, redemption, $LOOP stack deploy, vault fee routing) that will
run on Base Sepolia. The lifecycle runs three times: against the stage-1 exchange, after
deploy_loop (the $LOOP stack + the redeployed exchange), and after fund_bankroll (the
BettingBankroll bets its funded capital as an ERC-1271 maker — the HOUSE leg).

Stage 3 first gives the vault some revenue: a plain LP -> vault USDC transfer. That IS how
revenue arrives — `distribute()` derives accrued revenue from `balanceOf`, so a raw transfer
needs no intake function — and without it the vault has nothing to fund a bankroll with
(every order signs fee 0, so nothing arrives at fill).
"""

import json
import os

# Environment overrides MUST precede config import (load_dotenv won't clobber these).
HERE = os.path.dirname(os.path.abspath(__file__))
ANVIL_KEYS = {  # anvil's well-known dev keys 0..3
    "OPERATOR": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "LP": "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "USER": "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "MAKER": "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
}
os.environ.update(
    RPC_URL="http://127.0.0.1:8545",
    CHAIN_ID="31337",
    DEPLOYMENTS_PATH=os.path.join(HERE, "deployments.local.json"),
    # Fast $LOOP knobs for the rehearsal (defaults documented in deploy_loop.py).
    OPS_TIMELOCK="2",
    CHALLENGE_WINDOW="5",
    DISTRIBUTION_EPOCH="60",
    REWARDS_DURATION="3600",
    GUARDIAN_GAS_WEI=str(5 * 10**15),  # anvil's base fee is far above Base Sepolia's
    **{f"{k}_KEY": v for k, v in ANVIL_KEYS.items()},
)

import config  # noqa: E402
from config import send  # noqa: E402


COMMISSION = 8 * 10**6  # stands in for LP commission; 50/50 split -> 4 USDC to ops


def sweep_commission() -> None:
    """A plain LP -> vault USDC transfer: revenue arriving at the vault."""
    w3 = config.w3_connect()
    lp = config.accounts()["LP"]
    d = config.load_deployments()
    usdc = w3.eth.contract(address=config.USDC_ADDRESS, abi=config.ERC20_ABI)
    send(w3, lp, usdc.functions.transfer(d["vault"], COMMISSION))
    print(f"commission sweep: LP -> vault {COMMISSION / 1e6:.2f} USDC (plain transfer)")


def deploy_mock_usdc() -> str:
    w3 = config.w3_connect()
    operator = config.accounts()["OPERATOR"]
    abi, bytecode = config.load_artifact(os.path.join(config.FORK, "out", "USDC.sol", "USDC.json"))
    receipt = send(w3, operator, w3.eth.contract(abi=abi, bytecode=bytecode).constructor())
    usdc_address = receipt["contractAddress"]
    usdc = w3.eth.contract(address=usdc_address, abi=abi)
    for role in ("LP", "USER"):
        send(w3, operator, usdc.functions.mint(config.accounts()[role].address, 100 * 10**6))
    print(f"mock USDC at {usdc_address}, minted 100 to LP and USER")
    return usdc_address


if __name__ == "__main__":
    mock_usdc = deploy_mock_usdc()
    os.environ["USDC_ADDRESS"] = mock_usdc
    # re-evaluate config constants that captured the default USDC
    config.USDC_ADDRESS = config.Web3.to_checksum_address(mock_usdc)

    import deploy  # noqa: E402

    deploy.main()

    with open(os.environ["DEPLOYMENTS_PATH"]) as f:
        print("deployments:", json.load(f))

    import lifecycle  # noqa: E402

    print("\n=== stage 1: lifecycle against the operator-fee exchange ===")
    lifecycle.main()

    import deploy_loop  # noqa: E402

    print("\n=== stage 2: $LOOP stack + exchange redeploy (vault + bankroll) ===")
    deploy_loop.main()

    with open(os.environ["DEPLOYMENTS_PATH"]) as f:
        print("deployments:", json.load(f))

    print("\n=== stage 2: lifecycle against the redeployed exchange ===")
    lifecycle.main()

    import fund_bankroll  # noqa: E402

    print("\n=== stage 3: fund the bankroll (commission -> distribute -> opsWithdraw) ===")
    sweep_commission()
    fund_bankroll.main()

    print("\n=== stage 3: lifecycle with the bankroll as maker (HOUSE leg) ===")
    lifecycle.main()
    print("\nLOCAL REHEARSAL PASSED")
