# LoopBet Exchange: integration interface

Contract-side reference for anything that builds, signs, validates or relays orders
against the exchange in [`ctf-exchange/`](ctf-exchange/), a fork of Polymarket CTF
Exchange v1 (changes: [`ctf-exchange/FORK.md`](ctf-exchange/FORK.md)). File paths below
are relative to `ctf-exchange/src/exchange/`. Where this document and the Solidity
disagree, the Solidity is right.

## Deployment shape

```solidity
CTFExchange(address collateral, address ctf, address proxyFactory, address safeFactory, address feeRecipient)
```

- `collateral` is USDC and `ctf` is the ConditionalTokens contract. Both are immutable.
  The constructor grants the CTF unlimited approval of collateral, needed for split and
  merge.
- `proxyFactory` and `safeFactory` are only dereferenced by signature types this project
  does not use (POLY_PROXY, POLY_GNOSIS_SAFE). They are deployed as `address(0)`.
- `feeRecipient` is immutable and cannot be the zero address.
- The deployer becomes the first **admin and operator** (`mixins/Auth.sol`).
- The EIP-712 domain is the literal `"LoopBet Exchange", "1"` in `CTFExchange.sol`. The
  domain separator also includes `chainId` and `verifyingContract`, so a signature is
  bound to one deployment.

## Roles and access

| Function | Access |
|---|---|
| `fillOrder`, `fillOrders`, `matchOrders` | **onlyOperator**, notPaused, nonReentrant |
| `registerToken`, `pauseTrading`, `unpauseTrading`, `set*Factory`, add/remove admin and operator | onlyAdmin |
| `cancelOrder(s)` | the order's maker only (`msg.sender == order.maker`) |
| `incrementNonce` | anyone, affecting only their own orders |

Every execution path is `onlyOperator`: an order executes only when an operator relays it.
Cancels and nonce bumps keep working while trading is paused, so a user can always
withdraw their orders.

## Order struct (EIP-712)

`libraries/OrderStructs.sol`. The typehash string, where field order matters:

```
Order(uint256 salt,address maker,address signer,address taker,uint256 tokenId,
uint256 makerAmount,uint256 takerAmount,uint256 expiration,uint256 nonce,
uint256 feeRateBps,uint8 side,uint8 signatureType)
```

| Field | Meaning | How LoopBet sets it |
|---|---|---|
| `salt` | entropy | random uint256 per order |
| `maker` | source of funds | a user wallet, a liquidity provider, or the `BettingBankroll` |
| `signer` | who signed | EOA: equals `maker`. POLY_1271: equals `maker` (the contract) |
| `taker` | executor pin; `0` means public | the operator address, so the order can only execute through the relay. It is checked against `msg.sender`, not against the counterparty |
| `tokenId` | CTF ERC-1155 position id: the asset **bought** (BUY) or **sold** (SELL) | from the market registry |
| `makerAmount` | the most the maker spends (BUY: collateral; SELL: outcome tokens). **Fills are denominated in this** | 6-decimal base units |
| `takerAmount` | the least the maker receives (BUY: outcome tokens; SELL: collateral) | sets the price |
| `expiration` | unix seconds; `0` means never; expired when `< block.timestamp` | a short lifetime |
| `nonce` | must equal `nonces[maker]` on-chain at execution | normally 0; bumping it cancels everything |
| `feeRateBps` | fee on proceeds, at most `MAX_FEE_RATE_BIPS` (constant **500**, i.e. 5%) | **0**, see *Fees* |
| `side` | 0 = BUY, 1 = SELL | |
| `signatureType` | 0 EOA / 1 POLY_PROXY / 2 POLY_GNOSIS_SAFE / 3 POLY_1271 | **0 or 3 only** |
| `signature` | bytes, not part of the typehash | |

**ERC-1271** (`mixins/Signatures.sol::verifyPoly1271Signature`, tested in
`test/ERC1271Signature.t.sol`): requires `signer == maker`, the maker to have code, and
validation through Solady's `SignatureCheckerLib.isValidSignatureNow`. Smart-contract
wallets work as makers with no adaptation.

**`BettingBankroll` as maker.** The bankroll's `isValidSignature` accepts only the
exchange as caller. USDC honours ERC-1271 signatures for `permit`, so an unscoped check
would let the bankroll's maker key sign a permit *as the bankroll* and move its balance
anywhere. Scoping the caller is what limits that key to placing bets. An off-chain
validator that wants the same answer as a fill must therefore make the exchange the
caller, in one of two ways:

- call `Exchange.validateOrderSignature(orderHash, order)` (`public view`, reverts with
  `InvalidSignature`), which reaches the bankroll with `msg.sender = exchange`; or
- `eth_call` `isValidSignature` on the bankroll with an explicit `from = <exchange>`.

A call with a default `from` always returns `0xffffffff`.

Bankroll orders are also **BUY-only by construction**: the bankroll never grants the
exchange a CTF operator approval, so a SELL fill reverts when the exchange tries to pull
the tokens.

**Signing.** Standard EIP-712 typed data with domain
`{name, version, chainId, verifyingContract}` and the `Order` type above.
[`lifecycle/orders.py`](lifecycle/orders.py) is a small reference implementation.

## Price, amounts, crossing (`libraries/CalculatorHelper.sol`)

- The internal price is collateral per token, scaled by 1e18.
  BUY: `price = makerAmount * 1e18 / takerAmount`. SELL: `price = takerAmount * 1e18 / makerAmount`.
- **Decimal odds = 1 / price**, so a price of 0.50 is odds of 2.00.
- Partial fills convert with floor division: `taking = making * takerAmount / makerAmount`.
- Crossing must hold or the match reverts. BUY vs SELL: `priceBuy >= priceSell`.
  BUY vs BUY (MINT): `pA + pB >= 1e18`. SELL vs SELL (MERGE): `pA + pB <= 1e18`.

## Fees (`libraries/CalculatorHelper.sol::calculateFee`)

Fill-time fees are **not in use**: every order is signed with `feeRateBps = 0`. What
follows is what the contract implements.

- A fee is charged on **proceeds**: a BUY pays it in outcome tokens, a SELL in collateral.
- The formula is symmetric: `fee = feeRateBps * min(price, 1-price) * size / price` for a
  BUY, or `* size` for a SELL, divided by `10_000`. Each order pays its own signed rate
  when it fills.
- Fees go to the immutable `feeRecipient` at fill time. Upstream paid `msg.sender`, the
  operator, instead.
- That routing covers `matchOrders`. On `fillOrder` and `fillOrders` the operator is the
  counterparty and keeps upstream's implicit behaviour: it pays out proceeds minus the fee
  and retains the difference, so nothing is transferred to `feeRecipient`.
- The contract enforces only the cap (`feeRateBps <= 500`). The amount charged is fully
  determined by the signed order, so an operator cannot charge more than the maker signed.
- Because `feeRateBps` is part of the **signed** order, a specific fee policy is an
  off-chain rule: a relay that expects a given rate must reject orders that carry a
  different one before submitting them.
- In the current deployment `feeRecipient` is the `TreasuryVault`, which does not
  implement the ERC-1155 receiver hooks. A fill that charged a fee in outcome tokens would
  revert. Charging fill-time fees again would mean redeploying the exchange with a
  different recipient.

Note that Polymarket's current public documentation describes a newer fee model than this
v1 contract. The Solidity in this repository is the reference.

## Order lifecycle

- Status: `orderStatus[orderHash] = { isFilledOrCancelled, remaining }`. `remaining` is in
  **makerAmount units** and is initialised lazily on the first fill. Overfilling reverts
  (`MakingGtRemaining`). A complete fill sets `isFilledOrCancelled`.
- Validation at execution (`mixins/Trading.sol::_validateOrder`), in order: expiration,
  signature, fee cap, token registered, not filled or cancelled, nonce current.
- **Cancelling:** `cancelOrder` cancels one order and must be called by its maker, so for
  an ERC-1271 wallet the *contract* makes the call. `incrementNonce()` invalidates **all**
  of the caller's outstanding orders at once.

## Execution paths

- `fillOrder(order, fillAmount)`: the operator is the direct counterparty.
- `matchOrders(takerOrder, makerOrders[], takerFillAmount, makerFillAmounts[])`: the main
  path, one taker against N makers. The match type is derived per maker:
  - **COMPLEMENTARY** (BUY vs SELL, same `tokenId`): a direct swap with no CTF call.
  - **MINT** (both BUY, complementary `tokenId`s): both sides post collateral, the exchange
    calls CTF `splitPosition`, and each side receives its outcome tokens. This is how two
    parties bet against each other with no token inventory.
  - **MERGE** (both SELL, complementary `tokenId`s): the exchange merges token pairs back
    into collateral with `mergePositions` and pays both sides.
- Any price improvement goes to the **taker**, and leftover maker asset is refunded to the
  taker.

## Market registry (`mixins/Registry.sol`)

Before a market can trade, an admin calls `registerToken(tokenId, complementId, conditionId)`.
Both directions are stored and re-registration reverts. Creating a binary market is: CTF
`prepareCondition(oracle, questionId, 2)`, compute the two position ids, register them. A
three-way fixture (home / draw / away) is three conditions and three `registerToken`
calls.

`tokenId = 0` is the internal sentinel for collateral. Real CTF position ids are
keccak-derived and never 0.

## What a relay should check before submitting

The contract reverts on an invalid order, so a relay that wants to avoid wasted
transactions checks the same things first: the signature is valid for its type; the order
has not expired, with a margin for relay latency; `feeRateBps` is within the cap and
matches the expected rate; the token is registered; the order is not filled or cancelled;
`nonces[maker]` matches; the maker has balance and allowance (USDC for a BUY, outcome
tokens for a SELL); the prices cross; the fill does not exceed `remaining`; and `taker` is
the operator address.

## Voiding a market: refunds by unwinding fills

CTF resolution cannot refund exact stakes in general. `reportPayouts` sets one payout
vector **per outcome token**, the same for every holder, while stakes differ from fill to
fill once the price moves. Two YES holders who bought at 60c and at 40c can never both get
their stake back from a single vector.

The exchange can refund exactly with no contract change, by unwinding each fill at cost
through the COMPLEMENTARY path:

1. The market stops trading. Nothing is reported on-chain yet.
2. For each fill, the bettor signs a **SELL** of the tokens received at exactly the
   original fill price (`makerAmount` = tokens received, `takerAmount` = the stake,
   fee 0), and the original counterparty signs the mirror **BUY**. The bettor needs a
   one-time `setApprovalForAll(exchange)` on the CTF. `matchOrders` executes the pair:
   equal prices cross, a complete fill has no rounding loss, and the bettor receives
   exactly the stake, atomically.
3. Once no bettor holds tokens, the oracle reports `[0, 1]` so the bought-back sets
   redeem.

[`lifecycle/lifecycle.py`](lifecycle/lifecycle.py) rehearses this on two fills at
different prices and asserts the refund to the base unit.

## Events

- `OrderFilled(orderHash, maker, taker, makerAssetId, takerAssetId, making, taking, fee)`:
  one per filled order side. This is the permanent record of every bet, and the ledger the
  `$LOOP` emissions are computed from.
- `OrdersMatched(takerOrderHash, takerOrderMaker, makerAssetId, takerAssetId, making, taking)`
- `OrderCancelled(orderHash)`, `FeeCharged(receiver, tokenId, fee)`
- `TokenRegistered(token0, token1, conditionId)`, emitted twice, once per direction
- `TradingPaused(pauser)`, `TradingUnpaused(pauser)`, `NewAdmin`, `NewOperator`,
  `RemovedAdmin`, `RemovedOperator`
