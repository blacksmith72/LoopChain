"""Deploy the $LOOP stack to Base Sepolia: Timelock, emissions distributor
(URD fork), LOOP token, StakingRewards, TreasuryVault, BettingBankroll — then REDEPLOY the
Exchange with the vault as its immutable feeRecipient.

Prereqs:
  - `forge build` in ../loop AND ../ctf-exchange (artifacts are read from out/)
  - deployments.json from deploy.py (the existing CTF address is kept; the exchange is replaced)
  - OPERATOR funded with Base Sepolia ETH; GUARDIAN gets gas dust automatically

Roles (testnet-only EOAs, appended to .env on first run):
  GUARDIAN    — distributor root updater (holds the veto; the distributor's OWNER is the
                timelock), timelock proposer/executor, bankroll risk-off (cancel house
                orders, move the bankroll back to the treasury)
  ROOT_POSTER — the dedicated epoch-root updater key (never an admin)
  FOUNDERS    — receives the 300M genesis allocation
  MAKER       — the bankroll's ERC-1271 maker key: signs house orders; replaceable through
                a timelocked setMakerSigner

Knobs (env-overridable; the defaults are short values meant for testing):
  CHALLENGE_WINDOW  root challenge window, default 600s
  OPS_TIMELOCK      ops timelock min delay, default 60s
  STAKER_SHARE_BPS  staker split, default 5000 = 50%
  DISTRIBUTION_EPOCH vault distribute() rate limit, default 3600s
  REWARDS_DURATION  staking drip length, default 86400s

The bankroll deploys EMPTY and has no intake function: funding it is a plain USDC transfer,
normally a timelocked TreasuryVault.opsWithdraw(bankroll, amount) once revenue has accrued.
Winnings return to it directly and compound, so that call only ever RESIZES the bankroll.
"""

import os
import time

from eth_account import Account

import config
from config import EXPLORER, USDC_ADDRESS, retry_read, send, wait_for_code

ZERO = "0x" + "0" * 40
ZERO32 = b"\x00" * 32

CHALLENGE_WINDOW = int(os.getenv("CHALLENGE_WINDOW", "600"))
OPS_TIMELOCK = int(os.getenv("OPS_TIMELOCK", "60"))
STAKER_SHARE_BPS = int(os.getenv("STAKER_SHARE_BPS", "5000"))
DISTRIBUTION_EPOCH = int(os.getenv("DISTRIBUTION_EPOCH", "3600"))
REWARDS_DURATION = int(os.getenv("REWARDS_DURATION", "86400"))
GUARDIAN_GAS_WEI = int(os.getenv("GUARDIAN_GAS_WEI", str(10**14)))  # anvil needs more (higher base fee)

ENV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")


def ensure_role_keys(*roles: str) -> dict:
    """Read role keys from .env, generating and appending any that are missing."""
    created = []
    for role in roles:
        if not os.getenv(f"{role}_KEY"):
            acct = Account.create()
            with open(ENV_PATH, "a") as f:
                f.write(f"{role}_KEY={acct.key.hex()}\n")
            os.environ[f"{role}_KEY"] = acct.key.hex()
            created.append((role, acct.address))
    for role, address in created:
        print(f"generated testnet-only {role}: {address}")
    return {role: Account.from_key(os.environ[f"{role}_KEY"]) for role in roles}


def wait_chain_time(w3, seconds: int) -> None:
    """Let `seconds` of chain time pass. Anvil only advances timestamps when blocks are
    mined, so the local rehearsal fast-forwards explicitly; live chains just wait."""
    if config.CHAIN_ID == 31337:
        w3.provider.make_request("evm_increaseTime", [seconds + 1])
        w3.provider.make_request("evm_mine", [])
    else:
        time.sleep(seconds + 2)


def deploy(w3, acct, artifact_name, *args):
    abi, bytecode = config.loop_artifact(artifact_name)
    contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    receipt = send(w3, acct, contract.constructor(*args))
    address = receipt["contractAddress"]
    wait_for_code(w3, address)
    print(f"{artifact_name}: {EXPLORER}/address/{address}")
    return w3.eth.contract(address=address, abi=abi)


def main():
    w3 = config.w3_connect()
    deployer = config.accounts()["OPERATOR"]
    roles = ensure_role_keys("GUARDIAN", "ROOT_POSTER", "FOUNDERS", "MAKER")
    guardian, root_poster, founders, maker = (
        roles["GUARDIAN"], roles["ROOT_POSTER"], roles["FOUNDERS"], roles["MAKER"]
    )

    eth = w3.eth.get_balance(deployer.address)
    print(f"deployer (operator/admin): {deployer.address}  balance: {eth / 1e18:.6f} ETH")
    if eth < 10**15:  # ~10 contract deployments + wiring txs
        print("\nInsufficient gas. Fund the deployer with Base Sepolia ETH first:")
        print("  https://portal.cdp.coinbase.com/products/faucet")
        print(f"  address: {deployer.address}")
        return

    deployments = config.load_deployments()
    ctf_address = deployments["ctf"]
    print(f"existing CTF (kept): {ctf_address}")

    # Gas dust for the guardian (distributor wiring + timelock schedule/execute).
    if w3.eth.get_balance(guardian.address) < GUARDIAN_GAS_WEI // 2:
        send(w3, deployer, {"to": guardian.address, "gas": 21000}, value=GUARDIAN_GAS_WEI)
        print(f"sent {GUARDIAN_GAS_WEI / 1e18:.6f} ETH gas to GUARDIAN {guardian.address}")

    # 1. Ops timelock — the guardian proposes and executes; no admin.
    timelock = deploy(
        w3, deployer, "TimelockController", OPS_TIMELOCK, [guardian.address], [guardian.address], ZERO
    )

    # 2. Emissions distributor (URD fork). The guardian deploys and wires it, then hands
    #    ownership to the TIMELOCK. Ownership is what carries `setRoot` (upstream's audited
    #    emergency fix for a root that already finalized) and `setTimelock` (the challenge
    #    window itself) — both discretionary enough that they belong behind the public delay,
    #    which is exactly what the docs promise. Putting `setTimelock` there also replaces
    #    what the deleted `MIN_TIMELOCK` floor used to guarantee: shrinking the window to 0
    #    (which would let any updater call `setRoot` instantly) is now an announced action.
    #
    #    The guardian is registered as an updater so it KEEPS the instant veto:
    #    `revokePendingRoot` is `onlyUpdaterRole`, so once the owner is the timelock, updater
    #    status is the only way to hold it — and a delayed veto is useless against a 600s
    #    testnet window. Net, the guardian loses `setRoot`/`setTimelock`/`setRootUpdater`/
    #    `setOwner` and keeps `submitRoot`/`revokePendingRoot`: strictly less power, and the
    #    common failure (catch a bad root DURING the window) still gets an instant response.
    distributor = deploy(
        w3, deployer, "UniversalRewardsDistributor",
        guardian.address, CHALLENGE_WINDOW, ZERO32, ZERO32,
    )
    send(w3, guardian, distributor.functions.setRootUpdater(root_poster.address, True))
    print(f"root poster registered: {root_poster.address}")
    # Order matters: setRootUpdater is onlyOwner, so both grants must land BEFORE setOwner.
    send(w3, guardian, distributor.functions.setRootUpdater(guardian.address, True))
    send(w3, guardian, distributor.functions.setOwner(timelock.address))
    print(f"distributor owner -> timelock {timelock.address} "
          f"(guardian keeps the veto as a root updater)")

    # 3. LOOP — genesis mint: 700M -> distributor, 300M -> founders. Zero admin from here on.
    loop = deploy(w3, deployer, "LOOP", distributor.address, founders.address)

    # 4. StakingRewards (vendored Synthetix + precision fork, see loop/src/staking/FORK.md):
    #    stake LOOP, earn USDC.
    #    Deployer holds ownership just long enough to wire it, then hands it to the timelock
    #    (the owner can sweep undistributed USDC via recoverERC20 — that power belongs behind
    #    the public delay).
    staking = deploy(
        w3, deployer, "StakingRewards", deployer.address, deployer.address, USDC_ADDRESS, loop.address
    )

    # 5. TreasuryVault — the revenue splitter; owner = the timelock from day one.
    #    It holds NO betting capital and never touches the CTF.
    vault = deploy(
        w3, deployer, "TreasuryVault",
        USDC_ADDRESS, staking.address, timelock.address, STAKER_SHARE_BPS, DISTRIBUTION_EPOCH,
    )

    # 6. Wire staking: reward duration, vault as the only notifier, ownership -> timelock.
    send(w3, deployer, staking.functions.setRewardsDuration(REWARDS_DURATION))
    send(w3, deployer, staking.functions.setRewardsDistribution(vault.address))
    send(w3, deployer, staking.functions.nominateNewOwner(timelock.address))
    accept_calldata = w3.keccak(text="acceptOwnership()")[:4]
    send(
        w3, guardian,
        timelock.functions.schedule(staking.address, 0, accept_calldata, ZERO32, ZERO32, OPS_TIMELOCK),
    )
    print(f"timelock: acceptOwnership scheduled, waiting {OPS_TIMELOCK}s delay...")
    wait_chain_time(w3, OPS_TIMELOCK)
    send(w3, guardian, timelock.functions.execute(staking.address, 0, accept_calldata, ZERO32, ZERO32))
    print("staking ownership accepted by timelock")

    # 7. Exchange REDEPLOY with the vault as immutable feeRecipient (fork modification #3).
    exch_abi, exch_bytecode = config.exchange_artifact()
    exch_contract = w3.eth.contract(abi=exch_abi, bytecode=exch_bytecode)
    receipt = send(
        w3, deployer, exch_contract.constructor(USDC_ADDRESS, ctf_address, ZERO, ZERO, vault.address)
    )
    exch_address = receipt["contractAddress"]
    wait_for_code(w3, exch_address)
    exchange = w3.eth.contract(address=exch_address, abi=exch_abi)
    print(f"LoopBet Exchange (new): {EXPLORER}/address/{exch_address}")

    # 8. BettingBankroll — the house's betting capital, in its own contract so betting can
    #    never reach staker or ops money. Deployed AFTER the exchange because it needs the
    #    address; owner = the timelock, so the wiring below is a timelocked batch.
    bankroll = deploy(
        w3, deployer, "BettingBankroll",
        USDC_ADDRESS, ctf_address, vault.address, timelock.address,
    )

    # 9. Bankroll wiring: point it at the exchange (which grants the standing unlimited USDC
    #    allowance) and register the maker/guardian keys. It deploys EMPTY — funding is a
    #    plain transfer, normally a timelocked opsWithdraw once revenue has accrued.
    calls = [
        bankroll.encode_abi("setExchange", args=[exch_address]),
        bankroll.encode_abi("setMakerSigner", args=[maker.address]),
        bankroll.encode_abi("setGuardian", args=[guardian.address]),
    ]
    targets, values = [bankroll.address] * len(calls), [0] * len(calls)
    send(
        w3, guardian,
        timelock.functions.scheduleBatch(targets, values, calls, ZERO32, ZERO32, OPS_TIMELOCK),
    )
    print(f"timelock: bankroll wiring batch scheduled, waiting {OPS_TIMELOCK}s delay...")
    wait_chain_time(w3, OPS_TIMELOCK)
    send(w3, guardian, timelock.functions.executeBatch(targets, values, calls, ZERO32, ZERO32))
    print(f"bankroll wired as maker: exchange={exch_address}, makerSigner={maker.address} "
          "(balance 0 — fund it with a timelocked opsWithdraw)")

    # 10. Sanity checks.
    usdc = w3.eth.contract(address=USDC_ADDRESS, abi=config.ERC20_ABI)
    ctf_abi, _ = config.ctf_artifact()
    ctf = w3.eth.contract(address=ctf_address, abi=ctf_abi)
    assert retry_read(loop.functions.balanceOf(distributor.address).call) == 700_000_000 * 10**18
    assert retry_read(loop.functions.balanceOf(founders.address).call) == 300_000_000 * 10**18
    # setRoot and setTimelock are owner powers, and the owner is the timelock — so both are
    # announced before they land. The guardian holds the veto through updater status instead.
    assert retry_read(distributor.functions.owner().call) == timelock.address
    assert retry_read(distributor.functions.isUpdater(root_poster.address).call)
    assert retry_read(distributor.functions.isUpdater(guardian.address).call)
    assert retry_read(distributor.functions.timelock().call) == CHALLENGE_WINDOW
    thresholds, multipliers = retry_read(distributor.functions.roundTable().call)
    assert thresholds[-1] == 700_000_000 * 10**18 and multipliers[0] == 400, "round table mismatch"
    assert retry_read(staking.functions.rewardsDistribution().call) == vault.address
    assert retry_read(staking.functions.owner().call) == timelock.address
    assert retry_read(vault.functions.owner().call) == timelock.address
    assert retry_read(vault.functions.stakerShareBps().call) == STAKER_SHARE_BPS
    assert retry_read(bankroll.functions.owner().call) == timelock.address
    assert retry_read(bankroll.functions.treasury().call) == vault.address
    assert retry_read(bankroll.functions.exchange().call) == exch_address
    assert retry_read(bankroll.functions.makerSigner().call) == maker.address
    assert retry_read(bankroll.functions.guardian().call) == guardian.address
    assert retry_read(usdc.functions.balanceOf(bankroll.address).call) == 0  # deploys empty
    # The standing approval: unlimited, set once. Nothing re-arms it, ever.
    # Equality with max is valid HERE and only here — the bankroll was deployed seconds ago
    # and nothing has spent from it yet. USDC decrements even a max allowance on every
    # transferFrom, so no runtime check may test it this way (see BettingBankroll.setExchange);
    # the spendable figure everywhere else is the BALANCE.
    assert retry_read(
        usdc.functions.allowance(bankroll.address, exch_address).call
    ) == 2**256 - 1
    # BUY-only by construction — the Exchange must NEVER be an operator for our tokens.
    assert not retry_read(
        ctf.functions.isApprovedForAll(bankroll.address, exch_address).call)
    assert retry_read(exchange.functions.feeRecipient().call) == vault.address
    assert retry_read(exchange.functions.getMaxFeeRate().call) == 500
    assert retry_read(exchange.functions.isAdmin(deployer.address).call)
    assert retry_read(exchange.functions.isOperator(deployer.address).call)
    print("sanity checks passed (genesis split, roles, round table, fee routing, "
          "bankroll wiring, unlimited USDC allowance, no CTF approval)")

    config.save_deployments(
        {
            **deployments,
            "exchange": exch_address,
            # where an indexer should start scanning this exchange's events
            "exchangeDeployBlock": receipt["blockNumber"],
            "timelock": timelock.address,
            "distributor": distributor.address,
            "loop": loop.address,
            "staking": staking.address,
            "vault": vault.address,
            "bankroll": bankroll.address,
            "guardian": guardian.address,
            "rootPoster": root_poster.address,
            "founders": founders.address,
            "maker": maker.address,
        }
    )
    print("\nwrote deployments — next steps:")
    print(f"  1. this is a NEW exchange ({exch_address}): markets must be registered on it")
    print("     again, and every maker and taker must approve USDC (and, to sell, the CTF) to it")
    print("  2. the bankroll deploys empty: once revenue has reached the vault, run")
    print("     fund_bankroll.py (distribute, then a timelocked opsWithdraw to the bankroll)")
    print(f"  3. bankroll orders are signed by the MAKER key ({maker.address}); a timelocked")
    print("     bankroll.setMakerSigner replaces it if another key should sign")


if __name__ == "__main__":
    main()
