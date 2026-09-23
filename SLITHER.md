# Slither results

Static analysis of the nine KAY9 contracts and their libraries, re-run on **2026-09-22** against
the current tree — after the September re-review's remediation: the hub's hard deadline, the
team-vesting launch gate, `KAY9Registry.latestSnapshot` with `declaredRequesterKind`,
`KAY9AccessVault.upgrade`, `KAY9AuditorRegistry.isHalted()` and the two-step beneficiary transfer.
Dependencies, tests and scripts are excluded.

The previous run was 2026-09-11, after the lock was redenominated in KAY9, which removed
`KAY9Pricing` and with it every finding it carried — the one High, `weak-prng`, among them. No run
since has reported anything above Medium.

Every earlier revision of this file described contracts that no longer exist (the payment split,
`submitResult`, `TreasuryUpdated`). Nothing below is carried over unread.

## How to reproduce

`crytic-compile` still cannot read the `out/build-info` layout Foundry writes, so slither's
Foundry auto-detection fails before it reaches any detector. Forcing the plain solc platform works
and is what produced the results below. Slither 0.11.6, solc 0.8.26, `--via-ir`, Cancun.

```bash
export PATH="$HOME/.foundry/bin:$PATH"
solc-select install 0.8.26 && solc-select use 0.8.26
for f in KAY9Genesis KAY9AuditHub KAY9AccessVault KAY9ScanRegistry KAY9Registry \
         KAY9AuditorRegistry KAY9TeamVesting KAY9LiquidityLock KAY9Token; do
  slither "src/$f.sol" \
    --compile-force-framework solc \
    --solc "$HOME/.solc-select/artifacts/solc-0.8.26/solc-0.8.26" \
    --config-file slither.solc.json --json "slither-$f.json"
done
```

Every contract is its own entry point, so nothing depends on one file happening to import
another. The runs overlap on shared libraries; findings are counted once below.

## Summary

**55 distinct findings in 11 detector classes. None is a defect, and nothing is reported above
Medium.** The count was first written as 51 on 2026-09-22 and corrected to 55 on 2026-09-23, when
the run was repeated on the same tree and the per-detector counts were taken from the JSON output
rather than by hand: the two classes recorded below as having shrunk had not moved at all. Every finding is listed with its disposition. Per contract: Genesis 31, AuditHub 21,
AccessVault 9, LiquidityLock 6, Registry 4, ScanRegistry 3, TeamVesting 2, AuditorRegistry 0,
Token 0 (overlapping library hits counted once in the totals).

**What moved since 2026-09-11**, when the count was 52 in 10 classes:

| Change | Why |
|---|---|
| `missing-zero-check` 0 to 1, a new class | `KAY9TeamVesting.transferBeneficiary` is new code. False positive — see below |
| `timestamp` 16 to 17 | `KAY9AccessVault.upgrade` and `KAY9AuditHub.markExpired`, both September additions, compare times deliberately |
| `unused-return` 5 to 6 | one more destructured tuple in `KAY9Genesis.launch` |
| `incorrect-equality` 6, unchanged | the 2026-09-22 revision of this file said 3; the JSON says 6 |
| `divide-before-multiply` 4, unchanged | the 2026-09-22 revision said 3; the JSON says 4 |

52 plus the three additions is 55.

Nothing new is a defect, and no class that mattered appeared. The detectors that found nothing
still find nothing — the list is at the end of this file and is the part worth reading first.

| Severity | Detector | Count | Disposition |
|---|---|---|---|
| Medium | `reentrancy-no-eth` | 3 | Not exploitable: `nonReentrant`, status guards, immutable callees |
| Medium | `incorrect-equality` | 6 | False positives: comparisons against zero or a Merkle root |
| Medium | `divide-before-multiply` | 4 | Intentional snap-to-spacing arithmetic, identical to v4-core's |
| Medium | `uninitialized-local` | 1 | False positive: an accumulator that starts at the zero default |
| Medium | `unused-return` | 6 | Intentional tuple destructuring of `getSlot0`, `initialize`, `multicall` |
| Low | `reentrancy-benign` | 4 | Bookkeeping after guarded calls |
| Low | `reentrancy-events` | 2 | Event ordering only |
| Low | `calls-loop` | 9 | Loops bounded by the auditor set or the position list |
| Low | `timestamp` | 17 | Intentional: vesting, cooldowns, periods, service levels |
| Low | `missing-zero-check` | 1 | False positive: zero is the documented way to withdraw a proposal |
| Informational | `unindexed-event-address` | 2 | Event shapes fixed by `docs/CONTRACT_INTERFACES.md` |

---

## Medium

### `reentrancy-no-eth`

Three reports.

**`KAY9Genesis.launch`.** `_sweepUnsoldTokens()` is an external call made before `_params`,
`auction`, `launchCount`, `earliestRelaunchTimestamp`, `settled` and `recovered` are written.
Not exploitable: `launch` is `nonReentrant` and `onlyOwner`, and the callee is the previous
launch's Continuous Clearing Auction at an immutable address deployed by the canonical factory,
whose `sweepUnsoldTokens` transfers an ERC20 this vault itself deployed and which calls nobody
back. The sweep has to run before the balance check, because its purpose is to return the previous
auction's unsold supply so the relaunch has the full 910,000,000.

**`KAY9Genesis.recover`.** `recovered = true` is written after `poolManager.initialize`. Not
exploitable: `recover` is `nonReentrant`, the pool manager is the canonical immutable v4 core, and
`recovered` only decides which pool key `poolKey()` reports afterwards.

**`KAY9AuditHub._finalize`.** `job.reportId` is written after `registry.recordReport`. Not
exploitable: `job.status` is set to `Fulfilled` *before* the registry call, so the status guard at
the top of `attest` and `markExpired` already rejects a re-entrant attempt, and `attest` is
`nonReentrant`. The registry is an immutable address bound at deployment, makes no external calls
of its own, and only appends to storage.

**Action: documented, no change.**

### `incorrect-equality`

Six reports:

- `balance == 0`, `liquidity == 0`, `leftover == 0` in `KAY9Genesis._settleRemainder`, and
  `ethAmount == 0`, `liquidity == 0` in `KAY9Genesis.recover`
- `computed == _batches[batchId].root` in `KAY9ScanRegistry.verifyScan`

The detector fires on strict equality because comparing a *token balance* to an exact expected
value is fragile under fee-on-transfer tokens. None of these compare a balance to an expected
amount: they test for zero or for a Merkle root, where strict equality is the only correct
operator.

**Action: false positives, no change.**

### `divide-before-multiply`

Four reports, all in `TickRange`: `(tick / tickSpacing) * tickSpacing` in `floorToSpacing` and
`ceilToSpacing`, and the same shape twice in `maxLiquidityPerTick`. This is not a precision bug,
it *is* the snap-to-spacing operation, and the same expression appears in v4-core's
`Pool.tickSpacingToMaxLiquidityPerTick`.

**Action: intentional, no change.**

### `uninitialized-local`

`burned` in `KAY9Genesis._settleRemainder`: an accumulator that deliberately starts at the
Solidity zero default and is read as zero on purpose when nothing is burned.

**Action: false positive, no change.**

### `unused-return`

Six reports of one shape: `getSlot0` returns four values and the caller destructures the one or
two it needs (`KAY9Genesis.recover`, `_settleRemainder`, `_migrationOutcome`);
`poolManager.initialize` returns the tick, which the vault does not need; `launcher.multicall`
returns per-call return data, which the vault does not need.

**Action: intentional, no change.**

---

## Low

### `reentrancy-benign`

Four reports: `settled` and `_migrationParams` written after Uniswap calls in
`KAY9Genesis.launch`, `recover` and `_settleRemainder`; the job written after
`accessVault.consume` in `KAY9AuditHub.requestAudit`. Every entry point is `nonReentrant`, the
callees are the canonical PositionManager and PoolManager, the project's own token and liquidity
lock, and the project's own vault. `settled` is a bookkeeping flag; setting it late cannot release
value, because the tokens are already in a position owned by the lock. The vault's `consume` moves
a counter and cannot call back into the hub.

**Action: documented, no change.**

### `reentrancy-events`

`KAY9LiquidityLock.lock` emits `PositionLocked` after `registerBeneficiary`, and
`KAY9AccessVault.lockWithPermit` emits `AccessLocked` (inside `lock`) after the tolerated
`permit` call. Event ordering only; no state depends on it.

**Action: documented, no change.**

### `calls-loop`

Nine reports. `KAY9AuditHub.attest`, `_activeHolders` and `_verifySorted` call
`auditors.isAuditor` inside loops bounded by the signature list, itself bounded by the auditor
set; `KAY9LiquidityLock.lock`, `lockAll` and `_beneficiaryOf` call `ownerOf`,
`registerBeneficiary` and `safeTransferFrom` inside a loop over the position list, which grows
only when the protocol mints a position, at most twice per launch. `lockAll` skips ids it no longer
owns and ids already locked, and every caller can fall back to the single-item `lock(tokenId)`.

**Action: documented, no change.**

### `timestamp`

Seventeen reports across `KAY9Genesis`, `KAY9TeamVesting`, `KAY9AccessVault`, `KAY9AuditHub`
and `KAY9Registry`. Time-based logic is the point in all of them: the vesting schedule, the
48-hour relaunch cooldown, the access period and its expiry, and the audit service level. Every tolerance is orders of magnitude larger than any plausible sequencer
clock drift, and Robinhood Chain is a single-sequencer Orbit chain where drift is not an adversarial
lever. The `KAY9Registry.getReports` and `history` hits are the detector misclassifying ordinary
array bounds arithmetic.

**Action: intentional, no change.**

---

## Informational

### `missing-zero-check`

`KAY9TeamVesting.transferBeneficiary(address newBeneficiary)` assigns `pendingBeneficiary` without
checking the argument against zero.

Zero is not an oversight here, it is the feature. The role is transferred in two steps and the
function's own documentation says so: *"or zero to withdraw a proposal"*. Naming zero is how the
current beneficiary cancels a proposal it no longer wants. Nothing changes on that call either way
— the role moves only when `acceptBeneficiary()` succeeds, and that requires
`msg.sender == pendingBeneficiary`, which `address(0)` can never satisfy because nobody holds its
key. Rejecting zero would remove the cancel path and protect nothing.

**Action: documented, no change.**

---

### `unindexed-event-address`

`KAY9AccessVault.AuditHubUpdated(address)` and `KAY9AccessVault.AuditHubRetired(address)` carry
an address parameter that is not indexed.

Both are governance events that fire a handful of times in the protocol's life, their shapes are
specified in `docs/CONTRACT_INTERFACES.md`, and the current value of each is a plain getter
(`auditHub()`, `isRetiredHub(address)`).

**Action: documented, no change.**

---

## Detectors that found nothing

Worth stating explicitly, because these are the ones that would matter:

`arbitrary-send-eth`, `arbitrary-send-erc20`, `controlled-delegatecall`, `delegatecall-loop`,
`suicidal`, `unprotected-upgrade`, `unchecked-transfer`, `unchecked-lowlevel`, `unchecked-send`,
`tx-origin`, `uninitialized-state`, `uninitialized-storage`, `shadowing-state`, `constant-function`,
`reused-constructor`, `msg-value-loop`, `storage-array`, `array-by-reference`, `enum-conversion`,
`incorrect-shift`, `multiple-constructors`, `public-mappings-nested`, `rtlo`, `unprotected-vault`,
`erc20-interface`, `erc721-interface`, `locked-ether`.

`locked-ether` deserves a word: `KAY9Genesis` has a `receive()` and no withdrawal path, which the
detector accepts because `recover()` spends the balance. That is the design — the ETH a failed
migration returns can only ever go into the pool — and the frozen dust a *successful* migration
leaves behind is documented in `docs/SECURITY.md` §6.

## What static analysis did not find, and a rehearsal did

None of the detectors above can see that `block.number` on an Arbitrum Orbit chain is the parent
chain's height while the auction it was compared against reads `ArbSys.arbBlockNumber()`. That
defect was found on 2026-09-11 by launching on testnet and watching the auction end before its
first bid; it is fixed by inheriting Uniswap's `BlockNumberish` in every contract that records or
compares a block number, and pinned by the fork suite. `docs/RESEARCH.md` has the measurements.
