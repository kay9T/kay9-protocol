# Slither results

Static analysis of the ten KAY9 contracts and their libraries, run on 2026-09-11 against the
current tree — after the access-lock model, after `KAY9AccessVault` existed, and after the changes
made the same day (auditor-only `attest`/`publishWatchdogReport`, retired-hub `restore`,
`ZeroRequirement`, the `configurePool` fee and spacing check, and the `BlockNumberish` clock).
Dependencies, tests and scripts are excluded.

Every earlier revision of this file described contracts that no longer exist (the payment split,
`submitResult`, `TreasuryUpdated`). Nothing below is carried over unread.

## How to reproduce

`crytic-compile` still cannot read the `out/build-info` layout Foundry writes, so slither's
Foundry auto-detection fails before it reaches any detector. Forcing the plain solc platform works
and is what produced the results below. Slither 0.11.6, solc 0.8.26, `--via-ir`, Cancun.

```bash
export PATH="$HOME/.foundry/bin:$PATH"
solc-select install 0.8.26 && solc-select use 0.8.26
for f in KAY9Genesis KAY9AuditHub KAY9AccessVault KAY9ScanRegistry KAY9Pricing KAY9Registry \
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

**68 distinct findings in 11 detector classes. None is a defect.** One finding is reported as
High by this slither version (`weak-prng`) and is a false positive on a rounding modulo. Every
finding is listed with its disposition.

| Severity | Detector | Count | Disposition |
|---|---|---|---|
| High | `weak-prng` | 1 | False positive: a modulo used to round toward negative infinity |
| Medium | `reentrancy-no-eth` | 3 | Not exploitable: `nonReentrant`, status guards, immutable callees |
| Medium | `incorrect-equality` | 8 | False positives: comparisons against zero, the current block, or a Merkle root |
| Medium | `divide-before-multiply` | 4 | Intentional snap-to-spacing arithmetic, identical to v4-core's |
| Medium | `uninitialized-local` | 4 | False positives: accumulators that start at the zero default |
| Medium | `unused-return` | 9 | Intentional tuple destructuring of `getSlot0`, `initialize`, `multicall`, `latestRoundData` |
| Low | `reentrancy-benign` | 4 | Bookkeeping after guarded calls |
| Low | `reentrancy-events` | 2 | Event ordering only |
| Low | `calls-loop` | 9 | Loops bounded by the auditor set or the position list |
| Low | `timestamp` | 21 | Intentional: vesting, cooldowns, periods, service levels, oracle windows |
| Informational | `unindexed-event-address` | 3 | Event shapes fixed by `docs/CONTRACT_INTERFACES.md` |

---

## High

### `weak-prng` — `KAY9Pricing._twap`

`weighted < 0 && weighted % divisor != 0` is flagged as a weak pseudo-random number generator.

The modulo rounds the time-weighted mean tick toward negative infinity instead of toward zero,
which is how Uniswap's own tick averaging behaves. Nothing is random and nothing depends on being
unpredictable. The detector fires on the `%` operator alone.

**Action: false positive, no change.**

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

Eight reports:

- `balance == 0`, `liquidity == 0`, `leftover == 0` in `KAY9Genesis._settleRemainder`, and
  `ethAmount == 0`, `liquidity == 0` in `KAY9Genesis.recover`
- `latest.blockNumber == uint64(_getBlockNumberish())` in `KAY9Pricing.poke`
- `status.twapKay9PerEthE18 == 0 || status.spotKay9PerEthE18 == 0` in `KAY9Pricing.pricingStatus`
- `computed == _batches[batchId].root` in `KAY9ScanRegistry.verifyScan`

The detector fires on strict equality because comparing a *token balance* to an exact expected
value is fragile under fee-on-transfer tokens. None of these compare a balance to an expected
amount: they test for zero, for the current block, or for a Merkle root, where strict equality is
the only correct operator.

**Action: false positives, no change.**

### `divide-before-multiply`

Four reports, all in `TickRange`: `(tick / tickSpacing) * tickSpacing` in `floorToSpacing` and
`ceilToSpacing`, and the same shape twice in `maxLiquidityPerTick`. This is not a precision bug,
it *is* the snap-to-spacing operation, and the same expression appears in v4-core's
`Pool.tickSpacingToMaxLiquidityPerTick`.

**Action: intentional, no change.**

### `uninitialized-local`

`burned` in `KAY9Genesis._settleRemainder`, and `weighted`, `inWindow` and `covered` in
`KAY9Pricing._twap`. All four are accumulators or flags that deliberately start at the Solidity
zero default and are either written before use or read as zero on purpose.

**Action: false positives, no change.**

### `unused-return`

Nine reports of one shape: `getSlot0` returns four values and the caller destructures the one or
two it needs (`KAY9Genesis.recover`, `_settleRemainder`, `_migrationOutcome`; `KAY9Pricing.poke`,
`pricingStatus`, `configurePool`); `poolManager.initialize` returns the tick, which the vault does
not need; `launcher.multicall` returns per-call return data, which the vault does not need;
`feed.latestRoundData` is destructured inside a `try`.

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

Twenty-one reports across `KAY9Genesis`, `KAY9TeamVesting`, `KAY9AccessVault`, `KAY9AuditHub`,
`KAY9Pricing` and `KAY9Registry`. Time-based logic is the point in all of them: the vesting
schedule, the 48-hour relaunch cooldown, the access period and its expiry, the audit service level,
and the oracle window. Every tolerance is orders of magnitude larger than any plausible sequencer
clock drift, and Robinhood Chain is a single-sequencer Orbit chain where drift is not an adversarial
lever. The `KAY9Registry.getReports` and `history` hits are the detector misclassifying ordinary
array bounds arithmetic.

**Action: intentional, no change.**

---

## Informational

### `unindexed-event-address`

`KAY9Pricing.FeedUpdated(address)`, `KAY9AccessVault.AuditHubUpdated(address)` and
`KAY9AccessVault.AuditHubRetired(address)` carry an address parameter that is not indexed.

All three are governance events that fire a handful of times in the protocol's life, their shapes
are specified in `docs/CONTRACT_INTERFACES.md`, and the current value of each is a plain getter
(`feed()`, `auditHub()`, `isRetiredHub(address)`).

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
