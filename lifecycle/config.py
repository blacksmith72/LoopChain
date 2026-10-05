"""Shared config: chain constants, accounts, contract artifact loaders."""

import json
import os
import time

from dotenv import load_dotenv
from eth_account import Account
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware

HERE = os.path.dirname(os.path.abspath(__file__))
FORK = os.path.join(HERE, "..", "ctf-exchange")
LOOP_PROJ = os.path.join(HERE, "..", "loop")

load_dotenv(os.path.join(HERE, ".env"))  # does not override already-set env vars

# Defaults target Base Sepolia; rehearse_local.py overrides via env to hit a local anvil.
DEPLOYMENTS_PATH = os.getenv("DEPLOYMENTS_PATH", os.path.join(HERE, "deployments.json"))
CHAIN_ID = int(os.getenv("CHAIN_ID", "84532"))
USDC_ADDRESS = Web3.to_checksum_address(os.getenv("USDC_ADDRESS", "0x036CbD53842c5426634e7929541eC2318f3dCF7e"))
EXPLORER = "https://sepolia.basescan.org"

ERC20_ABI = json.loads(
    """[
    {"name":"balanceOf","type":"function","stateMutability":"view","inputs":[{"name":"a","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},
    {"name":"approve","type":"function","stateMutability":"nonpayable","inputs":[{"name":"s","type":"address"},{"name":"v","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]},
    {"name":"allowance","type":"function","stateMutability":"view","inputs":[{"name":"o","type":"address"},{"name":"s","type":"address"}],"outputs":[{"name":"","type":"uint256"}]},
    {"name":"transfer","type":"function","stateMutability":"nonpayable","inputs":[{"name":"t","type":"address"},{"name":"v","type":"uint256"}],"outputs":[{"name":"","type":"bool"}]}
]"""
)


def w3_connect() -> Web3:
    w3 = Web3(Web3.HTTPProvider(os.environ["RPC_URL"]))
    w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    assert w3.is_connected(), "RPC connection failed"
    assert w3.eth.chain_id == CHAIN_ID, f"wrong chain: {w3.eth.chain_id}"
    return w3


def accounts() -> dict:
    return {role: Account.from_key(os.environ[f"{role}_KEY"]) for role in ("OPERATOR", "LP", "USER")}


def load_artifact(path: str) -> tuple[list, str]:
    with open(path) as f:
        art = json.load(f)
    return art["abi"], art["bytecode"]["object"]


def exchange_artifact() -> tuple[list, str]:
    return load_artifact(os.path.join(FORK, "out", "CTFExchange.sol", "CTFExchange.json"))


def ctf_artifact() -> tuple[list, str]:
    return load_artifact(os.path.join(FORK, "artifacts", "ConditionalTokens.json"))


def loop_artifact(contract: str) -> tuple[list, str]:
    """Artifact from the ../loop Foundry project (requires `forge build` there)."""
    return load_artifact(os.path.join(LOOP_PROJ, "out", f"{contract}.sol", f"{contract}.json"))


def load_deployments() -> dict:
    with open(DEPLOYMENTS_PATH) as f:
        return json.load(f)


def save_deployments(d: dict) -> None:
    with open(DEPLOYMENTS_PATH, "w") as f:
        json.dump(d, f, indent=2)


_NONCES: dict = {}


def _next_nonce(w3: Web3, address: str) -> int:
    """Local monotonic nonce per account: the public load-balanced RPC can serve a
    stale transaction count from a lagging replica right after a tx mines."""
    if address not in _NONCES:
        _NONCES[address] = w3.eth.get_transaction_count(address, "pending")
    nonce = _NONCES[address]
    _NONCES[address] = nonce + 1
    return nonce


def send(w3: Web3, acct, fn_or_tx, value: int = 0) -> dict:
    """Build, sign, send a tx from `acct`; wait for receipt; assert success.

    Fees are set explicitly and modestly (Base Sepolia base fee is ~0.006 gwei):
    web3's defaults would demand a large upfront balance buffer on big deploy txs.
    """
    base_fee = w3.eth.get_block("latest")["baseFeePerGas"]
    try:
        tip = min(w3.eth.max_priority_fee, base_fee)
    except Exception:
        tip = base_fee
    base = {
        "from": acct.address,
        "nonce": _next_nonce(w3, acct.address),
        "value": value,
        "chainId": CHAIN_ID,
        "maxFeePerGas": 2 * base_fee + tip,
        "maxPriorityFeePerGas": tip,
    }
    if hasattr(fn_or_tx, "build_transaction"):
        # build_transaction estimates gas internally; retried for lagging replicas
        tx = retry_read(lambda: fn_or_tx.build_transaction(base))
    else:
        tx = {**fn_or_tx, **base}
        if "gas" not in tx:
            tx["gas"] = retry_read(lambda: w3.eth.estimate_gas(tx))
    signed = acct.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    assert receipt["status"] == 1, f"tx reverted: {EXPLORER}/tx/{tx_hash.hex()}"
    return receipt


def fmt_usdc(amount: int) -> str:
    return f"{amount / 1e6:.2f} USDC"


def wait_for_code(w3: Web3, address: str, timeout: int = 60) -> None:
    """Wait until the (possibly lagging) RPC replica serves the contract's code."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if w3.eth.get_code(address):
            return
        time.sleep(2)
    raise TimeoutError(f"no code at {address} after {timeout}s")


def find_deploy_block(w3: Web3, address: str) -> int:
    """Binary-search the first block where `address` has code (verifier-style derivation)."""
    lo, hi = 0, w3.eth.block_number
    while lo < hi:
        mid = (lo + hi) // 2
        if w3.eth.get_code(address, block_identifier=mid):
            hi = mid
        else:
            lo = mid + 1
    return lo


def retry_read(fn, attempts: int = 5, delay: float = 2.0):
    """Retry a contract read that RAISES (e.g. replica missing a fresh block).

    Does NOT protect against staleness on its own: a lagging replica answers a
    "latest" read *successfully* with pre-tx state, so there is no exception to
    retry and the stale value is returned as if correct (for example a balance
    delta of 0 reported for a transfer that did move funds).

    For a read that must reflect a specific tx, pin it:

        retry_read(lambda: fn(block_identifier=receipt["blockNumber"]))

    Pinning turns silent staleness into a "block not found" raise, which this
    function then retries correctly. For a condition rather than a value, use
    ``wait_assert``, which polls until the condition holds.
    """
    for i in range(attempts):
        try:
            return fn()
        except Exception:
            if i == attempts - 1:
                raise
            time.sleep(delay)


def wait_assert(cond, msg: str, timeout: int = 45, delay: float = 2.0) -> None:
    """Poll `cond` until true: state reads right after a tx may hit lagging replicas."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if cond():
                return
        except Exception:
            pass
        time.sleep(delay)
    raise AssertionError(msg)
