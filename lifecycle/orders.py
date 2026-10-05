"""EIP-712 order construction + signing for the LoopBet Exchange (CTF Exchange v1 fork).

A minimal reference implementation: the domain, types, and signing flow here are
what any signer or relay must reproduce (see ../INTERFACE.md).
"""

import secrets
from dataclasses import dataclass

from eth_account.messages import encode_typed_data

DOMAIN_NAME = "LoopBet Exchange"
DOMAIN_VERSION = "1"

SIDE_BUY = 0
SIDE_SELL = 1
SIG_EOA = 0
SIG_POLY_1271 = 3

ORDER_TYPES = {
    "Order": [
        {"name": "salt", "type": "uint256"},
        {"name": "maker", "type": "address"},
        {"name": "signer", "type": "address"},
        {"name": "taker", "type": "address"},
        {"name": "tokenId", "type": "uint256"},
        {"name": "makerAmount", "type": "uint256"},
        {"name": "takerAmount", "type": "uint256"},
        {"name": "expiration", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
        {"name": "feeRateBps", "type": "uint256"},
        {"name": "side", "type": "uint8"},
        {"name": "signatureType", "type": "uint8"},
    ]
}


@dataclass
class Order:
    maker: str
    signer: str
    taker: str  # pin to the operator address: order executable only through LoopBet
    tokenId: int
    makerAmount: int
    takerAmount: int
    expiration: int
    nonce: int = 0
    feeRateBps: int = 0
    side: int = SIDE_BUY
    signatureType: int = SIG_EOA
    salt: int = 0
    signature: bytes = b""

    def __post_init__(self):
        if not self.salt:
            self.salt = secrets.randbits(256)

    def message(self) -> dict:
        return {
            "salt": self.salt,
            "maker": self.maker,
            "signer": self.signer,
            "taker": self.taker,
            "tokenId": self.tokenId,
            "makerAmount": self.makerAmount,
            "takerAmount": self.takerAmount,
            "expiration": self.expiration,
            "nonce": self.nonce,
            "feeRateBps": self.feeRateBps,
            "side": self.side,
            "signatureType": self.signatureType,
        }

    def as_tuple(self) -> tuple:
        """ABI tuple for matchOrders/fillOrder calls (struct field order)."""
        m = self.message()
        return (
            m["salt"], m["maker"], m["signer"], m["taker"], m["tokenId"],
            m["makerAmount"], m["takerAmount"], m["expiration"], m["nonce"],
            m["feeRateBps"], m["side"], m["signatureType"], self.signature,
        )


def domain(chain_id: int, exchange_address: str) -> dict:
    return {
        "name": DOMAIN_NAME,
        "version": DOMAIN_VERSION,
        "chainId": chain_id,
        "verifyingContract": exchange_address,
    }


def sign_order(order: Order, account, chain_id: int, exchange_address: str) -> Order:
    """EOA signature (signatureType 0); signer must equal maker."""
    signable = encode_typed_data(
        domain_data=domain(chain_id, exchange_address),
        message_types=ORDER_TYPES,
        message_data=order.message(),
    )
    order.signature = account.sign_message(signable).signature
    return order


def buy_order(maker, operator_address: str, token_id: int, stake_usdc: int, price_cents: int,
              expiration: int, fee_rate_bps: int = 0) -> Order:
    """BUY `token_id` spending `stake_usdc` (6-dec units) at `price_cents` (USDC cents per token).

    makerAmount = collateral spent; takerAmount = outcome tokens received.
    Decimal odds = 100 / price_cents.
    """
    return Order(
        maker=maker.address,
        signer=maker.address,
        taker=operator_address,
        tokenId=token_id,
        makerAmount=stake_usdc,
        takerAmount=stake_usdc * 100 // price_cents,
        expiration=expiration,
        feeRateBps=fee_rate_bps,
        side=SIDE_BUY,
    )
