"""One-shot: generate testnet-only keypairs into .env (idempotent — refuses to overwrite)."""

import os
import sys

from eth_account import Account

ENV_PATH = os.path.join(os.path.dirname(__file__), ".env")

if os.path.exists(ENV_PATH):
    sys.exit(".env already exists - refusing to overwrite (delete it to regenerate)")

lines = [
    "# Base Sepolia TESTNET-ONLY keys - never fund or reuse on mainnet",
    "RPC_URL=https://sepolia.base.org",
]
for role in ("OPERATOR", "LP", "USER"):
    acct = Account.create()
    lines.append(f"{role}_KEY={acct.key.hex()}")
    print(f"{role}: {acct.address}")

with open(ENV_PATH, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"written to {ENV_PATH}")
