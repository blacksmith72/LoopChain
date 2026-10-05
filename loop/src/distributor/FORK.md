# LoopBet fork of the Morpho Universal Rewards Distributor

| | |
|---|---|
| Upstream | [morpho-org/universal-rewards-distributor](https://github.com/morpho-org/universal-rewards-distributor) |
| Pinned commit | `3de504b130835a12482e00e1c83dcf369448c80b` (2025-01-14) |
| Licence | GPL-2.0-or-later (see LICENSE in this directory). This fork remains GPL. |
| Upstream audits | Cantina managed review (2023-11-14), OpenZeppelin (2023-11-16), Cantina competition (2024-01-05). The reports are in the upstream repository's `audits/` folder and were conducted against the same OpenZeppelin `4.9.2` pin vendored in `lib/openzeppelin-contracts`. They cover upstream, not the addition below. |
| OZ dependency | pinned to upstream's audited submodule commit `e50c24f5839db17f46991478384bfda14acfb830` (v4.9.2) |

Role here: the `$LOOP` emissions distributor. The full 700M community supply is deposited
at genesis and can only leave through Merkle claims. The contract cannot mint, so it can
never pay out more than it was given.

## The delta, in one line

**The logic of every function is upstream's, unmodified.** The one functional change is
additive: two constants that no logic reads. Separately, one revert message and two
comments are worded differently from upstream; they are listed under *Wording differences*
below.

## Additive change

**The emissions commitment is etched into the contract**: `EMISSIONS_CAP` (700M, 18
decimals) and `roundTable()` (seven rounds of cumulative-supply thresholds and
multipliers). These are pure constants. The chain cannot compute what a bet earned, so
the table's job is to be a public reference nobody can change, against which any
published epoch root and its dataset can be checked.

## Deliberately not added

- No pause and no fund-recovery function. Upstream has none either: the 700M can only
  leave through claims.
- No changes to `claim`. It keeps upstream's cumulative, permissionless semantics and
  always pays the earning account.
- `UrdFactory` is not vendored. There is one deployment and no need for a factory.

## Who can change a root

Unchanged from upstream, and wired at deployment as follows:

- A root updater proposes a root with `submitRoot`. It becomes claimable only after the
  challenge window (`timelock`) has passed and someone calls the permissionless
  `acceptRoot`.
- `revokePendingRoot` is available to any updater. The guardian is registered as an
  updater so that it can veto a pending root immediately.
- `setRoot`, `setTimelock`, `setRootUpdater` and `setOwner` belong to the owner. The owner
  is the `TimelockController`, so replacing a root directly or shortening the challenge
  window is scheduled on-chain and waits out a public delay first.

An earlier version of this fork removed `setRoot` and added an immutable minimum for the
challenge window. Both were reverted to stay on the audited upstream code path.

## Mechanical changes

- Import paths: the two OpenZeppelin imports gained one `../` because this directory sits
  one level deeper than upstream's `src/`. A fork notice was added to the contract header.
- The constructor signature is identical to upstream
  (`initialOwner, initialTimelock, initialRoot, initialIpfsHash`).

## Wording differences

Found by comparing this directory line by line against the pinned upstream commit. None of
them is an intended change, and none alters logic:

- `libraries/ErrorsLib.sol`: the constant `UNAUTHORIZED_ROOT_CHANGE` reads
  `"unauthorized root change"`, where upstream has `"unauthorized to change the root"`, and
  its comment is reworded to match. The `require` in `setRoot` that uses it is identical to
  upstream's, so the same call reverts under the same condition; only the text of the
  revert reason differs.
- `UniversalRewardsDistributor.sol`: the `@notice` comment on `setRoot` is worded
  differently.

They are left as they are because the deployed contract was built from this source.

## Conventions (no code change)

- `ipfsHash` stores the raw sha2-256 digest of the epoch dataset. Datasets are published
  as CIDv1/sha2-256, so digest and CID map one to one. It is committed in the same
  transaction as the root it backs.
- The leaf format is upstream's
  `keccak256(bytes.concat(keccak256(abi.encode(account, reward, claimable))))`, with
  `reward` always the LOOP token address and `claimable` the *cumulative* amount earned.

## Tests

`test/distributor/UniversalRewardsDistributorTest.sol` is based on upstream's suite, not a
verbatim copy of it: the import paths are adjusted, the `setRoot` tests are rewritten
(owner, updater and other callers, with and without a timelock), a few lines are
reformatted, and one fork test, `testRoundTableCommitment`, pins the added constants.

Diff size against upstream, excluding this file: the constants block, the fork notice and
the two import paths in the main contract; two added getter lines in the interface
(`EMISSIONS_CAP`, `roundTable`); and the wording differences listed above. `EventsLib.sol`
and the LICENSE are byte-identical to upstream. No line of logic differs.
