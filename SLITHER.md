# Slither results

Static analysis of the eight KAY9 contracts and their libraries. Dependencies, tests and scripts are
excluded.

## How to reproduce

`crytic-compile` 0.4.2 cannot read the `out/build-info` layout that Foundry 1.8.1 writes, so
slither's Foundry auto-detection fails with a `FileNotFoundError` before it reaches any detector.
Forcing the plain solc platform works and is what produced the results below.

```bash
export PATH="$HOME/.foundry/bin:$PATH"
solc-select install 0.8.26 && solc-select use 0.8.26

slither src/KAY9Genesis.sol \
  --compile-force-framework solc \
  --solc "$HOME/.solc-select/artifacts/solc-0.8.26/solc-0.8.26" \
  --config-file slither.solc.json

slither src/KAY9AuditHub.sol \
  --compile-force-framework solc \
  --solc "$HOME/.solc-select/artifacts/solc-0.8.26/solc-0.8.26" \
  --config-file slither.solc.json
```

Those two entry points pull in the whole source tree: `KAY9Genesis` reaches the token, the vesting
contract, the liquidity lock and the tick and price libraries; `KAY9AuditHub` reaches the auditor
registry, the pricing oracle and the report registry.

`slither.config.json` is kept for the Foundry platform, so that the plain `slither .` invocation in
the Makefile starts working again as soon as crytic-compile catches up with Foundry's build-info
format. `slither.solc.json` is the configuration the commands above use.

## Summary

52 findings across the two runs, in 11 detector classes. Slither reports 29 for the `KAY9Genesis`
entry point and 23 for `KAY9AuditHub`; the two runs overlap on the shared libraries.
**No high-severity finding at all, and no medium-severity finding is a real defect.** Every one is
listed below with its disposition.

| Severity | Detector | Count | Disposition |
|---|---|---|---|
| Medium | `reentrancy-no-eth` | 2 | Not exploitable, see below |
| Medium | `incorrect-equality` | 6 | False positives, all comparisons are against zero or the current block |
| Medium | `divide-before-multiply` | 5 | Deliberate flooring arithmetic |
| Medium | `weak-prng` | 1 | False positive, a modulo used for rounding, not randomness |
| Medium | `uninitialized-local` | 4 | False positives, accumulators relying on the zero default |
| Medium | `unused-return` | 10 | Deliberate tuple destructuring |
| Low | `reentrancy-benign` | 3 | Not exploitable, see below |
| Low | `reentrancy-events` | 2 | Event ordering only |
| Low | `calls-loop` | 7 | Bounded loops over protocol-controlled lists |
| Low | `timestamp` | 10 | Deliberate time-based logic |
| Informational | `unindexed-event-address` | 2 | Event shapes are fixed by the interface specification |

---

## Medium

### `reentrancy-no-eth` — `KAY9Genesis.launch`

Slither reports that `_sweepUnsoldTokens()` is an external call made before `_params`, `auction`,
`launchCount`, `earliestRelaunchTimestamp` and `settled` are written.

**Not exploitable.** Three independent reasons:

1. `launch` carries `nonReentrant`, so a re-entrant call into it reverts.
2. `launch` is `onlyOwner`, so even a re-entrant call would have to come from the owner Safe.
3. The callee is the previous launch's Continuous Clearing Auction, an immutable address deployed by
   the canonical Uniswap factory, whose `sweepUnsoldTokens` transfers an ERC20 the vault itself
   deployed and does not call back.

The sweep has to run before the balance check, because its whole purpose is to return the previous
auction's unsold supply so the relaunch has the full 910,000,000 to work with. Reordering it after
the state writes would not remove the finding, only move it.

**Action: documented, no change.**

### `reentrancy-no-eth` — `KAY9AuditHub.submitResult`

`job.reportId = reportId` is written after `registry.recordReport(...)`.

**Not exploitable.** `job.status` is set to `Fulfilled` *before* the registry call, so the
job-status guard at the top of `submitResult` and `cancelExpired` already rejects any re-entrant
attempt. `submitResult` also carries `nonReentrant`. The registry is an immutable address, is
deployed by the same script, makes no external calls of its own, and only appends to storage.

**Action: documented, no change.**

### `incorrect-equality`

Six reports, all in `KAY9Genesis` and `KAY9Pricing`:

- `balance == 0`, `liquidity == 0`, `ethAmount == 0`, `leftover == 0` in the settlement and recovery
  paths
- `_count != 0 && _observations[_index].blockNumber == uint64(block.number)` in `poke`

The detector fires on strict equality because comparing a *token balance* to an exact expected value
is fragile in the presence of fee-on-transfer tokens. None of these compare a balance to an expected
amount; they are all "is this zero" or "is this the current block" tests, where strict equality is
the correct operator.

**Action: false positives, no change.**

### `divide-before-multiply`

Five reports, in `TickRange.floorToSpacing`, `TickRange.ceilToSpacing`,
`TickRange.maxLiquidityPerTick` and `KAY9AuditHub._settle`.

`(tick / tickSpacing) * tickSpacing` is not a precision bug, it *is* the snap-to-spacing operation,
and the same expression appears in Uniswap v4's own `Pool.tickSpacingToMaxLiquidityPerTick`. In
`_settle`, `remainder = operatorShare - (each * signerCount)` is deliberately the exact integer
remainder so the split adds up to the payment to the wei; the test
`test_submitResultSplitsPaymentExactly` asserts precisely that.

**Action: intentional, no change.**

### `weak-prng` — `KAY9Pricing._twap`

`weighted < 0 && weighted % divisor != 0` is flagged as a weak pseudo-random number generator.

The modulo is there to round the mean tick toward negative infinity rather than toward zero, which
is how Uniswap's own tick averaging behaves. Nothing here is random and nothing depends on being
unpredictable.

**Action: false positive, no change.**

### `uninitialized-local`

`burned` in `KAY9Genesis._settleRemainder`, and `weighted`, `inWindow` and `covered` in
`KAY9Pricing._twap`.

All four are accumulators or flags that deliberately start at the Solidity zero default and are
either written before use or read as zero on purpose. Adding an explicit `= 0` would only add gas
and noise.

**Action: false positives, no change.**

### `unused-return`

Ten reports, all of the same shape: `getSlot0` returns four values and the caller destructures the
one or two it needs, `poolManager.initialize` returns the resulting tick which the vault does not
need, `launcher.multicall` returns the per-call return data which the vault does not need, and
`feed.latestRoundData` is destructured inside a `try`.

**Action: intentional, no change.**

---

## Low

### `reentrancy-benign`

Three reports, in `KAY9Genesis._settleRemainder`, `KAY9Genesis.launch` and `KAY9Genesis.recover`,
all about `settled` and `_migrationParams` being written after Uniswap calls.

Every public entry point that reaches these paths (`launch`, `settle`, `recover`) is `nonReentrant`,
and the external callees are the canonical PositionManager and PoolManager plus the project's own
token and liquidity lock. `settled` is a bookkeeping flag; setting it late cannot release value,
because the tokens have already moved into a position owned by the lock.

**Action: documented, no change.**

### `reentrancy-events`

`KAY9LiquidityLock.lock` emits `PositionLocked` after `registerBeneficiary`, and
`KAY9AuditHub.requestAuditWithPermit` emits `AuditRequested` after the permit call.

Event ordering only. No state depends on it.

**Action: documented, no change.**

### `calls-loop`

Seven reports. `KAY9LiquidityLock.lockAll` calls `ownerOf`, `registerBeneficiary` and `safeTransferFrom` inside a
loop, and `KAY9AuditHub._verify` calls `auditors.isAuditor` inside a loop.

Both loops are bounded by lists the protocol itself controls: the lock's position list grows only
when the protocol mints a position, which happens at most twice per launch, and the signature list
is bounded by the auditor set. `lockAll` also skips ids it no longer owns and ids already locked, so
one stuck position cannot block the rest. Every caller can fall back to the single-item
`lock(tokenId)`.

**Action: documented, no change.**

### `timestamp`

Ten reports across `KAY9Genesis`, `KAY9TeamVesting`, `KAY9AuditHub`, `KAY9Pricing` and
`KAY9Registry`.

Time-based logic is the point in all of them: the vesting schedule, the 48-hour relaunch cooldown,
the audit service level and the oracle window. Every tolerance is orders of magnitude larger than
any plausible validator clock drift, and Robinhood Chain is a single-sequencer Orbit chain where
drift is not a meaningful adversarial lever. The `KAY9Registry.getReports` hits are the detector
misclassifying ordinary array bounds arithmetic.

**Action: intentional, no change.**

---

## Informational

### `unindexed-event-address`

`KAY9AuditHub.TreasuryUpdated(address)` and `KAY9Pricing.FeedUpdated(address)` carry an address
parameter that is not indexed.

`TreasuryUpdated` is specified verbatim in `docs/CONTRACT_INTERFACES.md`, which the website and the
services build their ABIs from; changing its indexing would break that contract for a governance
event that fires at most a handful of times in the protocol's life. `FeedUpdated` is kept in the
same shape for consistency. Both are trivially discoverable by reading the contract's current
`treasury()` and `feed()` getters.

**Action: documented, no change.**

---

## Detectors that found nothing

Worth stating explicitly, because these are the ones that would matter:

`arbitrary-send-eth`, `arbitrary-send-erc20`, `controlled-delegatecall`, `delegatecall-loop`,
`suicidal`, `unprotected-upgrade`, `unchecked-transfer`, `unchecked-lowlevel`, `unchecked-send`,
`tx-origin`, `uninitialized-state`, `uninitialized-storage`, `shadowing-state`, `constant-function`,
`reused-constructor`, `msg-value-loop`, `storage-array`, `array-by-reference`, `enum-conversion`,
`incorrect-shift`, `multiple-constructors`, `public-mappings-nested`, `rtlo`, `unprotected-vault`.
