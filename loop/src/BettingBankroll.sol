// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {ERC1155Holder} from "../lib/openzeppelin-contracts/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1271} from "../lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {IConditionalTokens} from "./interfaces/IConditionalTokens.sol";
import {ICTFExchange} from "./interfaces/ICTFExchange.sol";

/// @title BettingBankroll
/// @notice The house's betting capital, and nothing else. LoopBet bets against its users
/// from here: the operator's maker key signs orders *as this contract* (ERC-1271) and the
/// Exchange pulls USDC to fill them.
///
/// **Why this is a separate contract from the TreasuryVault.** When betting capital and
/// revenue share one pot they can only be told apart by bookkeeping, and that bookkeeping has
/// to run off the Exchange allowance — which forces the allowance to be finite, consumed and
/// re-armed, which puts a *governance* action (the Timelock) inside the routine operating
/// loop. Holding only betting money removes the question: there is nothing to separate, so
/// there is nothing to book.
///
///  * Spend is the balance going down. Wins are the balance going back up.
///  * A loss is a smaller balance. There is no write-off call, because nothing needs writing.
///  * Funding is a plain USDC transfer in. There is no intake function.
///  * P&L is legible without any on-chain accounting: the bankroll was X, now it is Y.
///
/// **How money gets in and out:**
///
///  1. In — a plain USDC transfer. Normally `TreasuryVault.opsWithdraw(bankroll, amount)`,
///     a timelocked owner call, which is the right cadence now that it only *resizes* the
///     bankroll rather than re-arming it after every settlement.
///  2. In — winning positions: `redeem(conditionId)` is permissionless and the proceeds
///     simply land. Profit stays here and compounds until management moves it back.
///  3. Out — betting: the Exchange pulls USDC against maker orders (see the allowance note).
///  4. Out — `withdrawToTreasury(amount)`: the only withdrawal function, and it pays only
///     the configured `treasury` — the TreasuryVault, which only the owner can change, through
///     the Timelock — where `distribute()` splits it with stakers. Deliberately NOT
///     timelocked: it moves money into the *more* restricted pocket, so the worst a stolen
///     guardian key can do with this call is hand the bankroll to stakers.
///
/// **Safety properties. These are key-compromise defences, not trustlessness — the operator
/// controls the frontend and the maker key either way. Losing either one is a real
/// vulnerability:**
///
///  - `isValidSignature` answers ONLY the Exchange. USDC (`FiatTokenV2_2`) honors ERC-1271
///    signatures for `permit`/`transferWithAuthorization`, so an unscoped implementation
///    would let the maker key sign a USDC permit *as this contract* and drain it to any
///    address. Caller-scoping is what pins the maker key's power to "bet the bankroll"
///    instead of "transfer the bankroll" — and that matters MORE under the unlimited
///    Exchange allowance below, not less. (Mirroring the fill-time result off-chain means
///    making the Exchange the caller: an off-chain validator can call
///    `Exchange.validateOrderSignature`, which reaches this contract with
///    `msg.sender = exchange` by construction. Calling here directly instead requires an
///    explicit `from = exchange` — a default-`from` call always returns `0xffffffff`.)
///  - The Exchange is NEVER granted a CTF (ERC-1155) approval, which makes bankroll orders
///    **BUY-only by construction**: a SELL fill reverts at the token pull, so the maker key
///    cannot give open positions away at self-dealt prices. Costs nothing — simply never
///    approve.
///  - Rotating `makerSigner` invalidates every unfilled bankroll order at fill time (their
///    signatures recover to the old key); `cancelOrders`/`incrementNonce` give the maker key
///    and the guardian an immediate risk-off path with no delay, since cancelling only ever
///    reduces exposure.
///
/// **The accepted trade.** The Exchange allowance is unlimited and set once, so a compromised
/// maker key can lose the whole bankroll rather than a standing budget. That is deliberate:
/// this is house risk capital, the guardian's cancel/nonce passthroughs are the interrupt,
/// and — the point of the whole split — staker and ops money lives in another contract that
/// this key cannot reach at all.
contract BettingBankroll is Ownable, ReentrancyGuard, ERC1155Holder, IERC1271 {
    using SafeERC20 for IERC20;

    /* CONSTANTS */

    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant ERC1271_INVALID = 0xffffffff;

    /* IMMUTABLES */

    /// @notice The collateral every position resolves into.
    IERC20 public immutable usdc;

    /// @notice The Gnosis ConditionalTokens contract holding the bankroll's open positions.
    IConditionalTokens public immutable ctf;

    /* STORAGE */

    /// @notice The TreasuryVault — the sole destination `withdrawToTreasury` can pay.
    address public treasury;

    /// @notice The LoopBet Exchange: sole accepted `isValidSignature` caller and sole address
    /// ever granted a USDC allowance. Set after the Exchange deploys.
    ICTFExchange public exchange;

    /// @notice The operator's maker role key: the only key whose ECDSA signature validates
    /// bankroll orders. Rotating it invalidates all unfilled bankroll orders.
    address public makerSigner;

    /// @notice Risk-off role (the ops multisig on mainnet): may cancel bankroll orders, bump
    /// the Exchange nonce, and sweep the bankroll back to the treasury — all without the
    /// timelock delay, because none of them can move money anywhere discretionary.
    address public guardian;

    /* EVENTS */

    event Redeemed(bytes32 indexed conditionId, uint256 usdcRedeemed);
    event WithdrawnToTreasury(address indexed treasury, uint256 amount);
    event TreasurySet(address treasury);
    event ExchangeSet(address exchange);
    event MakerSignerSet(address makerSigner);
    event GuardianSet(address guardian);

    /* MODIFIERS */

    modifier onlyMakerOrGuardian() {
        require(msg.sender == makerSigner || msg.sender == guardian, "BettingBankroll: not maker or guardian");
        _;
    }

    modifier onlyGuardianOrOwner() {
        require(msg.sender == guardian || msg.sender == owner(), "BettingBankroll: not guardian or owner");
        _;
    }

    /* CONSTRUCTOR */

    /// @param usdc_ The collateral token.
    /// @param ctf_ The ConditionalTokens contract.
    /// @param treasury_ The TreasuryVault — the only address `withdrawToTreasury` can pay.
    /// @param initialOwner The Timelock that administers the wiring.
    constructor(IERC20 usdc_, IConditionalTokens ctf_, address treasury_, address initialOwner) {
        require(address(usdc_) != address(0), "BettingBankroll: usdc is zero");
        require(address(ctf_) != address(0), "BettingBankroll: ctf is zero");
        require(initialOwner != address(0), "BettingBankroll: owner is zero");

        usdc = usdc_;
        ctf = ctf_;

        _setTreasury(treasury_);
        _transferOwnership(initialOwner);
    }

    /* PERMISSIONLESS */

    /// @notice Converts the bankroll's resolved positions of `conditionId` into USDC.
    /// @dev Permissionless: anyone may trigger realization after a market resolves. Redeems
    /// both outcome slots — voided markets pay both sides, and redeeming an empty slot adds
    /// zero. There is deliberately NO accounting here: proceeds simply land in the balance,
    /// which IS the bankroll.
    /// @return usdcRedeemed The USDC received.
    function redeem(bytes32 conditionId) external nonReentrant returns (uint256 usdcRedeemed) {
        uint256 balanceBefore = usdc.balanceOf(address(this));

        uint256[] memory indexSets = new uint256[](2);
        indexSets[0] = 1;
        indexSets[1] = 2;
        ctf.redeemPositions(address(usdc), bytes32(0), conditionId, indexSets);

        usdcRedeemed = usdc.balanceOf(address(this)) - balanceBefore;

        emit Redeemed(conditionId, usdcRedeemed);
    }

    /* ERC-1271 */

    /// @notice Validates a bankroll maker-order signature for the Exchange
    /// (`signatureType = 3`, `maker = signer = this`): valid iff signed by `makerSigner`.
    /// @dev Scoped to the Exchange as caller — see the contract header for why (USDC itself
    /// accepts ERC-1271 signatures for `permit`, so an unscoped check would be a drain path).
    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        if (address(exchange) == address(0) || msg.sender != address(exchange)) return ERC1271_INVALID;

        (address recovered,) = ECDSA.tryRecover(hash, signature);
        if (recovered == address(0) || recovered != makerSigner) return ERC1271_INVALID;

        return ERC1271_MAGIC;
    }

    /* RISK-OFF */

    /// @notice Cancels bankroll maker orders on the Exchange (it requires `msg.sender == maker`).
    /// @dev Maker key or guardian, no timelock: cancellation only reduces exposure.
    function cancelOrders(ICTFExchange.Order[] calldata orders) external onlyMakerOrGuardian {
        exchange.cancelOrders(orders);
    }

    /// @notice Bumps the bankroll's Exchange nonce, mass-invalidating all its unfilled orders.
    function incrementNonce() external onlyMakerOrGuardian {
        exchange.incrementNonce();
    }

    /* MANAGEMENT */

    /// @notice Moves bankroll USDC to the TreasuryVault, where the next `distribute()` splits
    /// it with stakers. Management (the ops multisig = `guardian`) decides when and how much:
    /// betting profit compounds here until they do.
    /// @dev Guardian or owner, and deliberately NOT timelocked. The destination is the
    /// configured treasury, which only the owner can change (a timelocked `setTreasury`), so
    /// this is not a discretionary money exit — it moves funds into the pocket whose exits are
    /// `distribute()` (permissionless, staker-first) and `opsWithdraw` (timelocked). A stolen
    /// guardian key can grief with this call (the return trip is a timelocked `opsWithdraw`)
    /// but cannot steal with it.
    function withdrawToTreasury(uint256 amount) external onlyGuardianOrOwner nonReentrant {
        require(amount > 0, "BettingBankroll: amount is zero");

        usdc.safeTransfer(treasury, amount);

        emit WithdrawnToTreasury(treasury, amount);
    }

    /* OWNER (= TIMELOCK) */

    /// @notice Points the bankroll at a (re)deployed TreasuryVault.
    function setTreasury(address treasury_) external onlyOwner {
        _setTreasury(treasury_);
    }

    /// @notice Points the bankroll at a (re)deployed Exchange and grants it the unlimited USDC
    /// allowance that fills are pulled from. The old Exchange is revoked first.
    /// @dev Unlimited is the point: a finite allowance would have to be re-armed after spend,
    /// and re-arming is an owner call, which would drag the Timelock back into the operating
    /// loop. The cap on what the Exchange can pull is the bankroll balance itself.
    /// Note that USDC (`FiatTokenV2_2`) decrements even a `type(uint256).max` allowance on
    /// every `transferFrom`, so the live number is not literally constant — it is merely
    /// unreachable (2^256 base units). Nothing on- or off-chain should test it for equality
    /// with `max`; the bankroll's spendable capacity is its BALANCE, not its allowance.
    function setExchange(ICTFExchange exchange_) external onlyOwner {
        require(address(exchange_) != address(0), "BettingBankroll: exchange is zero");

        if (address(exchange) != address(0)) {
            usdc.forceApprove(address(exchange), 0);
        }
        exchange = exchange_;
        usdc.forceApprove(address(exchange_), type(uint256).max);

        emit ExchangeSet(address(exchange_));
    }

    /// @notice Sets the maker key. Zero disables bankroll signing (and any rotation
    /// invalidates all unfilled bankroll orders at fill time).
    function setMakerSigner(address makerSigner_) external onlyOwner {
        makerSigner = makerSigner_;

        emit MakerSignerSet(makerSigner_);
    }

    /// @notice Sets the risk-off guardian. Zero disables the guardian path.
    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;

        emit GuardianSet(guardian_);
    }

    /* INTERNAL */

    function _setTreasury(address treasury_) internal {
        require(treasury_ != address(0), "BettingBankroll: treasury is zero");

        treasury = treasury_;

        emit TreasurySet(treasury_);
    }
}
