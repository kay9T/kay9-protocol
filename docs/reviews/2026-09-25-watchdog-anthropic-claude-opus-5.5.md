# Watchdog-stack model review — Anthropic Claude Opus 5.5, 2026-09-25

| | |
|---|---|
| Model | Claude Opus 5.5 (Anthropic), as a fresh Claude Code subagent with no project context |
| Date | 2026-09-25 |
| Commit | `c38dd247c44b6e76d87b438f15364181b63f4945` of `kay9T/kay9-protocol`, tag `watchdog-review-1` |
| Scope | `KAY9AuditorRegistry`, `KAY9AuditHub`, `KAY9Registry`, `KAY9ScanRegistry` and `DeployWatchdog.s.sol` |
| Prompt | [`WATCHDOG_REVIEW_PROMPT.md`](WATCHDOG_REVIEW_PROMPT.md), verbatim |

This is a model review, not a professional audit. The owner decided on 2026-09-23 that the second
family may be Anthropic. Claude Fable 5.1 was asked first and had reached its usage limit, so the
review ran on Claude Opus 5.5. The reviewer cloned the public repository at the tag and wrote
throwaway tests to prove its findings; none of them is in the repository.

## Dispositions

Each finding was checked against the source before it was decided. The fixes are at
`watchdog-review-2`.

| Finding | Held? | Disposition |
|---|---|---|
| F1 — one auditor or scanner key can set any asset's `latestScan`, and revoking it takes 48 hours | Yes | **Fixed in part, the rest accepted.** Auditors are no longer scanners by default, so one auditor key cannot move a headline score. A guardian, the owner's address, can revoke a scanner at once and can do nothing else. Scores above 100 are refused. A scanner's value is still its own claim, documented as such. Making `latestScan` move only forward in `scannedAtBlock` was not adopted: `scannedAtBlock` cannot be checked on-chain, so one bad batch with a far-future block would freeze an asset's value for good. The newest batch wins instead, so an honest batch replaces a bad one |
| F2 — any auditor can make an older, never-published signed report `latest` | Yes | **Fixed.** A watchdog report must be newer, by `analyzedAt`, than the asset's latest record, and no result may be analysed in the future. `KAY9Registry.latestAnalyzedAt` is the new read the rule uses. `latestSummary` still returns `committedAt`, not `analyzedAt`; its interface is unchanged for existing readers. Regression: `test_aStaleWatchdogReportCannotBecomeLatest` |
| F3 — the deploying key owns the scan registry until `acceptOwnership` lands | Yes | **Fixed.** The constructor takes the timelock as owner and the initial scanners, so the deploying key never owns it, and the script refuses the deployer as a scanner or auditor |
| F4 — removals lower the quorum down to one signature | Yes | **Fixed.** A removal that leaves fewer auditors than the threshold halts the registry; only `setThreshold` can name a smaller quorum. Regression: `test_aRemovalBelowTheThresholdHaltsInsteadOfLoweringIt` |
| F5 — nothing bounds a batch's size | Yes | **Fixed.** `count` above `MAX_BATCH` is refused |
| F6 — `verifyScan` accepts the root and internal nodes as leaves | Yes, for a raw hash | **Accepted and documented.** A leaf built with `scanLeaf` is double hashed and cannot collide with a node; a raw hash with no fields behind it says nothing about any scan. The function's documentation now says to pass a `scanLeaf` output. Changing its signature would break every verifier already written against it |
| F7 — threshold zero with an auditor present | Yes | **Accepted.** It is the halted state and fails safe; see the OpenAI review's F-08 |
| F8 — no emergency path | Yes | **Fixed for scanners, accepted for auditors.** The guardian revokes a scanner at once. Removing an auditor still takes the 48-hour timelock: an instant remover would let one key halt the quorum at will, and a compromised auditor still needs a second key to publish |
| F9 — minor hub issues | Mixed | Scores are now bounded at 100, the "permissionless" wording is gone, and `renounceOwnership` is disabled on the hub, the scan registry and the auditor registry. Front-running an `attest` with a peer's signature records the same position, so nothing is lost, and is accepted. A dispute is final even if the threshold later falls; the requester already has the quota unit back, and is accepted. `setAccessVault` does not check the vault's hub; the token deployment sets the vault's hub itself in `Deploy.s.sol`, and this is accepted |

## Verification at `watchdog-review-2`

Same reviewer, on `dc56681878eaae5f1a9b35ac7e14041b0706a654`. Local file paths in the reviewer's notes are replaced, and marked where they were. Nothing else is changed.

The round-two findings are fixed at `watchdog-review-3`:

| Finding | Disposition |
|---|---|
| A job record landing between two watchdog reports reopens the freshness window | **Fixed.** `KAY9Registry.latestAnalyzedAt` is now the largest `analyzedAt` ever recorded for the asset, by either path, not the last record's. Regression: `test_aJobRecordDoesNotReopenTheWatchdogFreshnessWindow` |
| The guardian is immutable, so a retired guardian keeps its power | **Fixed.** The owner, behind the timelock, can replace it with `setGuardian`, which emits `GuardianUpdated`. Regression: `test_theOwnerReplacesTheGuardian` |
| After a lowered threshold, the submitter chooses between two contradictory positions that both meet it | **Fixed.** If another position also meets the quorum, the job is disputed instead, on both `attest` and `finalizeAgreed`. Regression: `test_contestedPositionsAfterALoweredThresholdDispute` |
| A removal alone can make agreement impossible with no vote left to trigger the dispute | **Fixed.** New permissionless `checkDispute(jobId)` applies the same membership-aware rule. Regression: `test_checkDisputeSettlesAMembershipOnlyImpossibility` |
| The auditor cap does not bound votes across rotations, so the uint8 counters can still overflow | **Fixed.** `attestations`, `digestVotes` and `bestAgreement` are uint16 |
| Removal now halts in cases that used to keep running (informational) | **Accepted.** Governance schedules removal, addition and threshold in one timelock batch; `docs/DEPLOYMENT.md` says so |

### The verification, verbatim

# KAY9 watchdog stack: fix verification

**Tree read:** `https://github.com/kay9T/kay9-protocol` at commit `dc56681878eaae5f1a9b35ac7e14041b0706a654` (tag `watchdog-review-2`, subject "fix(watchdog): close the watchdog-stack review findings before mainnet"). I fetched it into the same temp clone used for the first review and read only that tree. I reviewed the diff against `c38dd247` for `src/` and `script/DeployWatchdog.s.sol` line by line, and read the disposition file `docs/reviews/2026-09-25-watchdog-anthropic-claude-opus-5.5.md`.

First two lines of `src/KAY9ScanRegistry.sol` at `dc566818`:

```
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
```

**Tests.** I rewrote the throwaway PoCs for the new tree as `test/review/WatchdogVerify.t.sol`, which exists only in the temp checkout. It extends the repo's own `KAY9AuditHubTest`, so it has a real vault and real jobs. All 10 new tests pass, and every test inherited from the parent suite passes with them (22 in the filtered run I kept). Every `test/unit/*` suite passes on this tree. I did not complete the invariant or fork suites.

---

## 1. Status of each original finding

| # | Status | Reason and evidence |
|---|---|---|
| F1: one key sets any `latestScan` | **Narrowed** | Auditors are no longer implicit scanners: `commitScanBatch` checks only `isScanner`. Scores above 100 are refused. The immutable `guardian` can `revokeScanner` at once. All three are proven in `test_F1_auditorIsNotAScannerAndScoreBounded`: an auditor reverts `NotAScanner`, a score of 101 reverts `ScoreOutOfRange`, and the guardian revokes. The same test proves the remainder: one authorised scanner can still write any in-range value for any asset with a garbage root, and the value **survives the scanner's revocation** until some honest batch indexes that asset again. The contract has no marker saying a batch came from a scanner that was later revoked. |
| F2: stale watchdog report becomes `latest` | **Narrowed, not closed** | The original scenario now reverts `StaleWatchdogReport` (`test_F2_originalScenarioNowReverts`). But the freshness bar is the `analyzedAt` of the **latest record**, and job records are exempt from the rule. A job report pinned to an earlier `analyzedAt` that lands after a newer watchdog report lowers the bar, and the stale report gets in. Proven in `test_F2_bypassThroughAJobRecord`; see N1 below. Before the token, when no jobs exist, the fix is complete. |
| F3: deployer owns the scan registry until `acceptOwnership` | **Closed** | The constructor takes `owner_` (the timelock), `guardian_` and `initialScanners`. The script passes the timelock, `ownerSafe` and `cfg.scanners`, and refuses the deployer as an auditor or scanner. `owner() == timelock` from construction is asserted in `test_F1_...`. `renounceOwnership` is disabled on all three `Ownable2Step` contracts. |
| F4: removal lowers quorum to one | **Closed** | `removeAuditor` now sets `threshold = 0` and emits `QuorumHalted` whenever `threshold > remaining`. Proven in `test_F4_removalHalts`: 2-of-3 minus two auditors is halted, not 1-of-1. |
| F5: batch size unbounded | **Closed** | `count > MAX_BATCH` reverts `BatchTooLarge`. Proven in `test_F5_countBounded` (count 501). |
| F6: `verifyScan` accepts root and nodes | **Still open, accepted and documented** | Unchanged in code; the NatSpec now requires a `scanLeaf` output. `test_F6_stillAcceptsRoot` still passes. |
| F7: threshold 0 with an auditor present | **Still present, accepted** | Unchanged. `test_F7_zeroWithAuditor` still passes (count 1, threshold 0). `_disputeIfUnreachable` now returns early while halted, which makes the intended behaviour explicit. |
| F8: no emergency path | **Narrowed** | Scanners: closed by `revokeScanner`. Auditors: removal still takes the 48-hour timelock (accepted), and `setRequestsPaused` is still timelocked. |
| F9: minor hub issues | **Mostly closed** | Scores are bounded at 100 on the report path (`_checkResult`); the "permissionless" wording is gone; renounce is disabled. The "lowered threshold does not finalise" part is closed by `finalizeAgreed` (repo test `test_aLoweredThresholdIsSettledByFinalizeAgreed`). Front-running, disputes being final when auditors are later added, and `setAccessVault` not checking the vault's hub are accepted (see section 3). |

---

## 2. Defects in the changed code

### N1. The watchdog freshness rule can be bypassed through a job record (F2 remainder)

- **Severity:** Low. The impact is F2's, but it needs a job on the same asset, and jobs exist only after the token and vault.
- **Location:** `src/KAY9AuditHub.sol` `publishWatchdogReport` (the `registry.latestAnalyzedAt` comparison); `src/KAY9Registry.sol` `latestAnalyzedAt` (it reads the last record, not a high-water mark).
- **Scenario (proven, `test_F2_bypassThroughAJobRecord`):**
  1. At t0 a requester opens a job on asset T.
  2. At t0+1h, auditors A and B sign watchdog report W0 (score 90, `analyzedAt` t0+1h). It is never published.
  3. At t0+2h, W1 (score 10, `analyzedAt` t0+2h) is published.
  4. The job then lands through `attest` with `analyzedAt = t0` (the design pins a job's analysis to its request time) and becomes the latest record. The freshness bar drops to t0.
  5. Any single auditor now publishes W0: t0+1h > t0, so it passes. `latestSummary(T)` returns 90 even though a newer watchdog report (score 10) is on record.
- This happens without any collusion whenever a job's 6-hour SLA overlaps a watchdog update. A requester who has locked KAY9 can also create the condition on purpose.
- **Fix:** keep a per-asset `maxAnalyzedAt` high-water mark in `KAY9Registry`, updated on every `recordReport`, and compare watchdog reports against that rather than against the last record's `analyzedAt`.

### N2. After a threshold is lowered, whoever submits chooses between contradictory positions that both meet the quorum

- **Severity:** Low (governance-triggered; no averaging happens)
- **Location:** `KAY9AuditHub.finalizeAgreed`; the same applies to the finalise branch in `attest`.
- **Scenario (proven, `test_loweredThresholdSubmitterPicksBetweenContradictions`):**
  1. The SLA is 30 days and the threshold is 2 of 3. A attests X (score 90) and B attests Y (score 5). The job stays `Requested`, correctly, because C could still break the tie.
  2. Governance lowers the threshold to 1.
  3. Both positions now meet the quorum. Whichever auditor calls `finalizeAgreed` first decides whether X or Y is the permanent record. A holder of X can simply finalise X.
- Property 4 promises disputes when auditors disagree. Here there are two quorum-meeting contradictions, and the contract picks one by submission order instead of disputing.
- **Fix:** before finalising, when more than one position in `_jobDigests[jobId]` has at least `required` active holders, mark the job `Disputed` instead.

### N3. The scan-registry guardian is immutable

- **Severity:** Low
- **Location:** `KAY9ScanRegistry.guardian` (immutable), set to `cfg.ownerSafe` by the script.
- **Scenario:**
  1. The owner Safe is later replaced: its signers are rotated by migrating to a new Safe, or it is compromised and the timelock revokes its proposer and executor roles.
  2. The old address keeps `revokeScanner` power forever, and nothing can remove it.
  3. If that address is hostile, it can revoke every scanner instantly each time governance re-adds one 48 hours later. Basic scans are then permanently denied, and the only recovery is a new `KAY9ScanRegistry`, which splits the scan history.
- The guardian can only remove scanners, so the harm is denial of service, not false data.
- **Fix:** let the timelocked owner change the guardian (`setGuardian`, `onlyOwner`), or let the guardian renounce its own role.

### N4. Removal now halts in cases that used to keep running

- **Severity:** Informational (operational; fails safe)
- **Location:** `KAY9AuditorRegistry.removeAuditor`.
- Removing one compromised key from 3-of-3, or removing an auditor before the replacement is added during a rotation, now halts every report and every job finalisation until `setThreshold` executes.
- Governance should always put `removeAuditor` together with `addAuditor` and/or `setThreshold` in one `scheduleBatch`, so the halt never happens by accident. This deserves one line in the operations runbook.

### Checked and found correct

- **The new dispute rule** (active holders plus silent auditors, checked per position over `_jobDigests`) never disputes a job that some position could still finalise with the current set and threshold. A removed-then-re-added holder is counted correctly as active, and the loops are bounded by `MAX_AUDITORS = 32` times the number of positions.
- **`finalizeAgreed`** keeps the deadline, the requirement that the submitter be an auditor, the asset match and the active-holder filter. It skips `_checkResult`, which is safe, because the digest can only match a position that passed `_checkResult` when it was attested.
- **`renounceOwnership` overrides** declared `view` compile, and they revert for the owner.
- **`MAX_AUDITORS`** is enforced in both the constructor and `addAuditor`.
- **`AnalyzedInFuture`** is applied on both result paths.
- **The chain allowlist in the script** (4663, 46630, 31337) and the refusal of the deployer as auditor or scanner are both correct.

---

## 3. Do I accept each written disposition?

| Disposition | Accept? | Reason |
|---|---|---|
| F1 remainder: a scanner's value is its own claim; `scannedAtBlock` was not made monotonic | **Yes, with one addendum** | The argument is right: `scannedAtBlock` cannot be checked on-chain, and one far-future value would freeze the asset. "Newest batch wins" is the better rule. Addendum: because a revoked scanner's values stay in `latestScan`, integrators should be told to check `isScanner(getBatch(batchId).scanner)`. After any revocation, operators should re-index every asset the revoked scanner touched; the `AssetScanned` events identify them. |
| F2: `latestSummary` still returns `committedAt`, not `analyzedAt` | **Yes** | Keeping the interface stable is reasonable because `latestSnapshot` exists. However, F2 itself is only narrowed (N1). |
| F6: documented, signature unchanged | **Yes** | A `scanLeaf` output cannot collide with a node, and breaking existing verifiers is a real cost. The stated property 5 ("`verifyScan` accepts exactly the leaves") should be reworded to "accepts exactly the leaves when given a `scanLeaf` output". An additive `verifyScanFields` wrapper would cost nothing and break nothing. |
| F7: halted state accepted | **Yes** | It fails safe, and it is announced by `QuorumHalted` and `isHalted`. |
| F8: auditors still need the 48-hour timelock | **Yes** | An instant remover would let one key halt the quorum, and a lone compromised auditor still needs a second key to publish. The residual risk: during those 48 hours, a compromised auditor can still submit (and so choose `reportURI` for) finalisations it sits on, and can cast a contradicting vote. When the threshold equals the auditor count, one contradicting vote is enough to dispute a job, because unanimity is then impossible. That is a denial of service, not false data. |
| F9: front-running `attest` | **Yes** | The recorded position is identical; only the original transaction fails. |
| F9: a dispute is final even if the auditor set later grows | **Yes** | The requester is refunded, and it can simply request again. |
| F9: `setAccessVault` does not check the vault's hub | **Yes, provisionally** | The disposition relies on `Deploy.s.sol` setting the vault's hub, which is out of my scope and which I did not read. A mismatch makes requests revert, which fails safe. A one-line `require(accessVault_.auditHub() == address(this))` would still remove the dependency. |

---

## 4. Not covered

- **Unverified dispositions:** I did not read `Deploy.s.sol`, `KAY9AccessVault` beyond earlier signatures, or the OpenAI review. The F9 `setAccessVault` disposition therefore rests on a claim I did not check.
- **Unfinished suites:** I did not finish the invariant or fork suites on this tree. A full `forge test` run without the fork suite was still running at the 10-minute mark, and I stopped following it after the unit suites passed.
- **Deployed instances:** I did not examine any deployed instance.
- **Off-chain behaviour:** the scanner and signer services, and the batch document format, are out of scope. N1's practical frequency depends on how often jobs and watchdog updates overlap on the same asset, which I did not measure.

## Reviewer

Claude Opus 5.5 (model id `claude-opus-5-5[1m]`, 1M-context variant), by Anthropic, running as a Claude Code subagent. Verification date 2026-09-25.

## Final confirmation at `watchdog-review-3`

Same reviewer, on `c6cc435824c1b1da7c87920ecb248f7ba01ccdd3`. **N1 to N3 closed, N4 accepted, and the
commit confirmed for the watchdog deployment.** One new low finding, V3-1: the interface spec still
gave the widened counters as uint8. **Fixed** in `docs/CONTRACT_INTERFACES.md`, together with the
one-batch rotation guidance the reviewer could not find in the public tree. The only contract
change after this confirmation is the OpenAI reviewer's R3-01, at `watchdog-review-4`.

### The confirmation, verbatim

# KAY9 watchdog stack: final confirmation (round three)

**Tree read:** `https://github.com/kay9T/kay9-protocol` at commit `c6cc435824c1b1da7c87920ecb248f7ba01ccdd3` (tag `watchdog-review-3`, subject "fix(watchdog): close the round-two findings from both model reviews"). I fetched it into the same temp clone and read only that tree. I reviewed the diff against `dc566818` for `src/` and `script/` line by line (the script did not change).

First two lines of `src/KAY9AuditHub.sol` at `c6cc4358`:

```
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
```

**Tests.**
- All `test/unit/*` suites pass: 332 tests, 0 failures.
- My throwaway suite, `test/review/WatchdogVerify.t.sol`, exists only in the temp checkout and extends the repo's `KAY9AuditHubTest`. I updated it for this tree and added checks for N2 on the attest path, for `checkDispute`, and for N3. All of its tests pass, together with the inherited suite: 45 in total.
- I did not run the invariant or fork suites.

---

## 1. N1 to N4

| # | Status | Evidence |
|---|---|---|
| N1: watchdog freshness bypass through a job record | **Closed** | `KAY9Registry` keeps `_maxAnalyzedAt` per asset, raised on every `recordReport` from either path, and `latestAnalyzedAt` returns it. My PoC `test_F2_bypassThroughAJobRecord` now reverts `StaleWatchdogReport(t0+1h, t0+2h)`: the job landing at `analyzedAt = t0` no longer lowers the bar. The original F2 scenario still reverts (`test_F2_originalScenarioNowReverts`). |
| N2: a lowered threshold lets the submitter choose between contradictions | **Closed** | `_finalizeUnlessContested` disputes the job when any other position also has at least `required` active holders. It is used by both `attest` and `finalizeAgreed`. Proven both ways. `test_loweredThresholdSubmitterPicksBetweenContradictions` now ends `Disputed` with no report written. `test_N2_attestPathAlsoDisputes` covers the attest path: 4 auditors at threshold 3 split X 1 / Y 2, the threshold is lowered to 1, and a fourth auditor's vote for X disputes the job instead of finalising it. |
| N3: immutable guardian | **Closed** | The `guardian` storage variable has an `onlyOwner` `setGuardian` (timelocked) that refuses zero and emits `GuardianUpdated`. `test_N3_guardianReplaceable` shows three things: the guardian cannot replace itself, the timelock can replace it, the old guardian then gets `NotGuardian`, and the new one revokes. A compromised guardian can now do damage only until a `setGuardian` has passed its 48-hour delay. |
| N4: removal halts cases that used to keep running | **Accepted; I agree** | The disposition cites runbook guidance in `docs/DEPLOYMENT.md`. **That file is not in this public tree**, so I could not verify the guidance. The contract behaviour fails safe either way. |

The first-round findings I re-ran on this tree are unchanged from round two:
- F1 is narrowed (`test_F1_...` passes).
- F4 and F5 are closed.
- F6 and F7 are accepted (`test_F6_...` and `test_F7_...` still show the documented behaviour).

---

## 2. Review of the changed code

**New permissionless `checkDispute(jobId)`.**
- It reuses `_disputeIfUnreachable` with the current threshold.
- It returns without disputing while the registry is halted.
- It reverts after the deadline and on a non-`Requested` job, so a unit cannot be restored twice.
- It is `nonReentrant`.
- The membership-aware rule (best active holders plus silent active auditors, compared with the threshold) cannot dispute a job that some position could still settle under the current set. Shown in `test_checkDispute_membershipOnly`: it returns false with two silent auditors, false again after a 1–1 split while a third auditor is silent, and true after that third auditor is removed. A second call then reverts.
- Anyone can call it at the exact moment a timelock removal executes. That is correct behaviour under the current set. If governance splits a rotation into two separate operations, a pending job can be disputed in between. That is refund-only and is covered by the N4 batching guidance.

**`_finalizeUnlessContested`.**
- The comparison skips the position being finalised and checks every other recorded position through `_activeHolders`, so removed holders do not count.
- A contested job disputes and refunds exactly once, through the shared `_dispute`.
- Gas is bounded by (number of positions) × (holders), each with a registry call. With `MAX_AUDITORS = 32` this is fine.
- One harmless gap: `checkDispute` does not detect the contested state, because `best >= required` there. A contested job therefore stays `Requested` until an auditor calls `finalizeAgreed` or `attest` (which disputes it) or the job expires. The refund happens either way.

**`uint16` counters.** These are consistent across `Job.attestations`, `digestVotes`, `bestAgreement`, the local `votes` and the events. The narrowing cast `uint16(best)` in `_dispute` is safe because `best` is at most the number of holders.

**High-water mark.**
- The update is correct, and it is monotonic.
- A strict `>` means two different watchdog reports analysed in the same second cannot both land. That is acceptable.
- The name `latestAnalyzedAt` now returns a maximum rather than the last record's value. It is documented, but an integrator reading the name could misunderstand it (informational).
- Job records stay exempt from freshness and still become `latest` by commit order. That is the documented design, and a job result cannot be analysed in the future (`AnalyzedInFuture`).

**`setGuardian`.** It is `onlyOwner`, refuses zero, and emits an event. Correct.

### New finding

**V3-1. `docs/CONTRACT_INTERFACES.md` still specifies the old `uint8` types, and the event signatures changed.**
- **Severity:** Low (integration, not contract security)
- **Location:** `docs/CONTRACT_INTERFACES.md:540` (`uint8 attestations` in `Job`), `:549` (the `AuditDisputed(uint256,uint8,uint8,uint8)` event), `:646` (the paragraph saying the counters are `uint8`).
- **Why it matters:** the project calls this file the binding ABI spec for web and services. Changing to `uint16` changes the topic0 of `AuditAttested` and `AuditDisputed`, and the ABI of the `getJob` tuple. An indexer or website built from the spec would silently miss every attestation and dispute event, and would mis-decode `getJob`.
- **Fix:** update the spec (and any ABI copies in the web and services) to `uint16` before go-live.

I found no new contract-level defect in the round-three changes.

---

## 3. Confirmation for deploying the watchdog stack

**I confirm commit `c6cc4358` for deploying the watchdog stack (`KAY9AuditorRegistry`, `KAY9AuditHub` without a vault, `KAY9Registry`, `KAY9ScanRegistry`, `DeployWatchdog.s.sol`).** I found no security blocker in the contracts.

Conditions, not contract blockers:
1. **Fix V3-1 before go-live.** Bring `CONTRACT_INTERFACES.md` and every consumer ABI in line with the `uint16` counters and the new event signatures. Otherwise the website and indexer will silently miss attestation and dispute events. Jobs do not exist until the vault is bound, so strictly this must be done before `setAccessVault`, but the spec is wrong today.
2. **The N4 runbook guidance** is cited in `docs/DEPLOYMENT.md`, which is not in the public tree. Make sure it exists wherever the operators will actually read it.
3. **Standing residuals, accepted in earlier rounds:**
   - A single authorised scanner's `latestScan` value is its own unproven claim (F1). It is revocable at once, but the value persists until an honest batch re-indexes the asset.
   - `verifyScan` must be given a `scanLeaf` output (F6).
   - Removing an auditor takes 48 hours (F8).

## 4. Not covered

- **Suites not run:** the invariant and fork suites.
- **Deployments not examined:** any deployed instance, and the `deployments/*.json` files.
- **Out of scope, not read:** `Deploy.s.sol`, `KAY9AccessVault` internals, and the launch path.
- **Not visible in this tree:** the OpenAI reviewer's round-two findings, beyond the changes listed in the coordinator's message and visible in the diff; and `docs/DEPLOYMENT.md`.

## Reviewer

Claude Opus 5.5 (model id `claude-opus-5-5[1m]`, 1M-context variant), by Anthropic, running as a Claude Code subagent. Date 2026-09-25.

## The review, verbatim

One local file path in the reviewer's toolchain note is replaced, and marked where it was. Nothing
else is changed.

# KAY9 watchdog stack: security review

**Tree read:** `https://github.com/kay9T/kay9-protocol` at commit `c38dd247c44b6e76d87b438f15364181b63f4945` (HEAD subject: "docs(reviews): the watchdog-stack review prompt for gate 6"). I cloned it fresh into a temp directory and read only that checkout.

First two lines of `src/KAY9AuditHub.sol` at that commit:

```
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
```

Toolchain: forge from [a local path, removed before publication]. The existing `test/unit/*` suites all pass on this tree. Every finding marked "proven" below comes with a throwaway test, `test/review/WatchdogPoC.t.sol`, written only in the temp checkout. All 6 of its tests pass.

---

## Findings (most severe first)

### F1. One auditor key or one scanner key can set any asset's on-chain `latestScan` score, and revoking it takes at least 48 hours

- **Severity:** Medium
- **Location:** `src/KAY9ScanRegistry.sol:250-299` (`commitScanBatch`), mainly line 257 (the authorisation) and line 288 (the unconditional overwrite of `_latest`); revocation is `setScanner` at :362 and `KAY9AuditorRegistry.removeAuditor` at :118, both `onlyOwner`, meaning the 48-hour timelock.
- **Scenario (proven, `test_singleAuditorOverwritesLatestScan`):**
  1. One auditor key (below the quorum) or one authorised scanner key is compromised or misbehaves. Scanner keys are likely automated hot keys.
  2. It calls `commitScanBatch(root = anything, count = anything >= summaries, engineVersion, uri = "x", summaries = [{target asset, overallTrust: 100, ...}])`.
  3. `latestScan(chainKey, assetId)` now returns `(true, batchId, 100)` for any asset it names. That includes a rug it wants to whitewash, or a competitor it wants to mark 0. `latestScan` is the documented one-call read for "a badge or a token page".
  4. The contract does not check that the summaries match the root (this is documented at :238-243). It does not check that `scannedAtBlock` is newer than what is stored, and it does not bound `overallTrust` to 0-100. The root can be garbage.
  5. No path revokes the key faster than 48 hours. For that whole window the key can rewrite any number of assets, up to 500 per transaction, as often as it likes. Every new batch overwrites the last, so honest scanners cannot out-write it for long either.
- **Why this matters beyond "documented":** the report path needs `threshold` signatures, but this path needs only one of those same auditor keys (line 257). So one auditor key can publish, under the KAY9 name, an on-chain headline score for any asset, with no consensus behind it. Readers may not keep that distinction in mind.
- **Suggested fix (any of these):**
  - Make `_latest` monotonic in `scannedAtBlock` for each asset (refuse or skip an older scan).
  - Give a guardian key a removal-only role that works immediately: it can de-authorise a scanner, or pause `commitScanBatch`, but can never add anything.
  - Take auditors out of the implicit scanner set, so one auditor key has no single-signer write path at all.
  - At minimum, refuse `overallTrust > 100`, and have integrators treat `latestScan` as "claimed by `batch.scanner`".

### F2. Any single auditor can make an older, never-published quorum-signed watchdog report the asset's `latest`

- **Severity:** Medium
- **Location:** `src/KAY9AuditHub.sol:513-531` (`publishWatchdogReport`), `:732-750` (`_verifySorted`); `src/KAY9Registry.sol:238-283` (`latest` and `latestSummary` go by commit order).
- **Scenario (proven, `test_staleWatchdogReportBecomesLatest`):**
  1. Day 1: auditors A and B sign watchdog report R_old for token T (`overallTrust` 90, `analyzedAt` = day 1). It is never published. Maybe it was superseded, or the relay dropped it. The code's own comment says signatures "travel through a relay anybody can read", so the signature pair is available to others.
  2. Day 2: A and B sign R_new (`overallTrust` 10, a rug detected), and it is published.
  3. Later, any current auditor C (who needs no signature of its own) calls `publishWatchdogReport(R_old, sigs_old)`. The call passes: A and B are still auditors, and R_old's digest was never committed. The signed payload has no deadline, nonce or freshness bound.
  4. `latestSummary(T)` and `latestSummaryForToken(T)` now return 90. Neither function returns `analyzedAt`, and these are the reads a wallet or DEX is told to make. Only `latestSnapshot` exposes `analyzedAt`.
- **What this is not:** it cannot forge a result. Every published record still carries a real quorum. What it does is let one auditor choose which of several quorum-signed snapshots is headline "latest", including a stale one. That runs against "latest means most recent snapshot" as a reader understands it, even though it is literally the most recently committed record.
- **Suggested fix:** for the watchdog path (jobId 0), require `result.analyzedAt` to be strictly greater than the `analyzedAt` of the asset's current latest record. Alternatively, add a signed `deadline` (or `notAfter`) field to the EIP-712 type and refuse it after expiry. Also return `analyzedAt` from `latestSummary`, or deprecate it in favour of `latestSnapshot`.

### F3. Until the timelock executes `acceptOwnership`, the deploying key still fully owns `KAY9ScanRegistry`: it can add scanners, redirect the pending owner, or renounce

- **Severity:** Low (it depends on operator discipline and a key that is already trusted, but it contradicts property 1 during the window, and part of its effect persists after it)
- **Location:** `script/DeployWatchdog.s.sol:159-163`; `Ownable2Step.transferOwnership` / `Ownable.renounceOwnership`.
- **Scenario (proven, `test_deployerWindow`):**
  1. The script deploys the scan registry with `owner = deployer`, sets the scanners, and calls `transferOwnership(timelock)`. That only sets `pendingOwner`.
  2. `acceptOwnership` needs a timelock proposal, so the window lasts at least 48 hours.
  3. During the window the deploying key can:
     - call `setScanner(x, true)` for any x;
     - call `transferOwnership(y)`, which overwrites the pending owner so that the timelock's queued `acceptOwnership` reverts;
     - call `renounceOwnership()`, which freezes the scanner set forever.
  4. Scanners added during the window **survive** the handover. `isScanner` is not enumerable, so anyone checking go-live has to replay every `ScannerUpdated` event rather than read a list.
- **Suggested fix:**
  - Pass `owner_ = timelock` and the initial scanner list to the `KAY9ScanRegistry` constructor, the same way `KAY9AuditorRegistry` already takes its auditors. The deployer then never holds the registry.
  - Failing that, have the go-live checklist assert `pendingOwner == timelock`, `owner == timelock`, and the full `ScannerUpdated` event history.
  - Also refuse `cfg.scanners` entries equal to the deployer, rather than only logging a warning at :213.

### F4. Removing auditors silently lowers the quorum, down to a single signature

- **Severity:** Low
- **Location:** `src/KAY9AuditorRegistry.sol:133-140`.
- **Scenario (proven, `test_removalLowersQuorumToOne`):**
  1. The set is 3 auditors with threshold 2. Governance removes two keys, for example two operators rotating out, or two suspected compromises.
  2. The threshold drops automatically to 1, and the one remaining key can now `publishWatchdogReport` alone and finalise jobs alone.
  3. The same happens with 2-of-2 after removing one auditor, or with 3-of-3 after removing one (it becomes 2).
- The registry's own rationale (:113-116) says a single-signature quorum "is not something this contract should choose on the owner's behalf". `addAuditor` follows that rule; `removeAuditor` breaks it.
- The timelock makes the removal public 48 hours ahead, so this is visible. It is still a quorum change that no `setThreshold` proposal announced.
- **Suggested fix:** when a removal would push `threshold` above the remaining count, set `threshold = 0` (halted) and require an explicit `setThreshold`. Or refuse the removal unless the new threshold still meets a configured minimum quorum, keeping the special case for removing every auditor.

### F5. Nothing bounds a batch's size; `MAX_BATCH` only caps how many scans are indexed on-chain

- **Severity:** Low (a mismatch between the specification and the code; nothing is stolen)
- **Location:** `src/KAY9ScanRegistry.sol:124-128, 262-267`.
- **Scenario (proven, `test_singleAuditorOverwritesLatestScan` asserts `count == type(uint32).max`):** a scanner commits `count = 4,294,967,295` with any root. The only bound applies to `summaries.length`, which must be at most 500 and at most `count`. The contract's own NatSpec says this is intended ("Bounds the loop, not the batch"). Property 5 ("a batch holds at most 500 scans") is therefore false as written. `count` is a claim the contract cannot verify.
- **Suggested fix:** either change the stated property to "at most 500 scans indexed per transaction; `count` is unverified", or enforce `count <= MAX_BATCH` if the 500 limit is meant to be a real claim.

### F6. `verifyScan` accepts the root and internal nodes as "leaves"

- **Severity:** Low (it is safe if every caller builds `leaf` with `scanLeaf`; it is unsafe for any integrator that passes a raw hash from a document)
- **Location:** `src/KAY9ScanRegistry.sol:308-320`.
- **Scenario (proven, `test_verifyScanAcceptsNonLeaves`):** for a 4-leaf batch, `verifyScan(id, n12, [n34])` and `verifyScan(id, root, [])` both return `true`. Leaves are double-hashed (`keccak(keccak(abi.encode(...)))`, which hashes 32 bytes), while nodes are `keccak` over 64 bytes. So a leaf computed through `scanLeaf` cannot collide with a node, and scan fields still cannot be forged. But the function takes a caller-supplied `bytes32 leaf`, so the claim "`verifyScan` accepts exactly the leaves the batch was built from" does not hold. An integrator who reads a "leaf" value out of a batch document published by a malicious scanner, and passes it straight in, can be shown a node as if it were a scan.
- **Suggested fix:** make `verifyScan` take the eight scan fields and compute the leaf internally with `scanLeaf`, or add a `verifyScanFields` wrapper and document the raw form as unsafe.

### F7. The threshold can be 0 while auditors exist

- **Severity:** Informational (it fails in the safe direction and is documented)
- **Location:** `src/KAY9AuditorRegistry.sol:133-140, 95-97`.
- **Scenario (proven, `test_thresholdZeroWithAuditor`):** remove all auditors, then add one. `auditorCount() == 1` and `threshold() == 0`. The hub refuses everything while the threshold is 0 (`attest` :491, `_verifySorted` :739), so nothing can be published. This is intended, but it breaks the literal wording of property 8. Note one side effect: while halted, every pending job's `attest` call runs `_disputeIfUnreachable` with `required = 0`, and `best + silent >= 0` is always true, so no dispute is ever raised. Jobs can only expire.

### F8. There is no emergency path; every protective action takes at least 48 hours

- **Severity:** Informational (a design choice, but it amplifies F1)
- **Location:** `setRequestsPaused` (hub :578), `removeAuditor`, `setScanner`; `DeployWatchdog.s.sol:150` (the timelock's only proposer and executor is `ownerSafe`).
- The code comment on the auditor registry (:10-11) promises that a removal will "be scheduled immediately on a key compromise", but scheduling it does not make it take effect: a compromised key stays active for at least 48 hours. `requestsPaused` is also behind the timelock, so it cannot serve as an emergency brake.

### F9. Minor issues in the hub

- **Severity:** Informational
- **Front-run griefing in `attest`** (`KAY9AuditHub.sol:472-476`): auditor A sends `attest(job, R, [sigA, sigB])`. Any other auditor who sees `sigB` on the relay can land `attest(job, R, [sigB])` first. A's transaction then reverts with `AlreadyAttested(B)`, and A must resubmit with `[sigA]` alone. That costs time and gas; no position is lost. The same submitter picks the unsigned `reportURI` (documented at :179-187). The Arbitrum FCFS sequencer makes this less likely but does not rule it out.
- **Disputes are final against the current set** (`_disputeIfUnreachable`, :695-708): a job disputed while the set is small stays disputed even if an auditor is added a minute later. Separately, lowering `threshold` does not finalise a position that already meets the new threshold until another auditor happens to attest that same digest. Since every holder is blocked by `AlreadyAttested`, the job usually just expires. The requester is refunded either way.
- **Scores are not range-checked** (`AuditResult`, `ScanSummary`): `overallTrust` and the other scores are `uint8` and are never checked against 100. They are quorum-signed on the report path; on the scan path see F1.
- **Documentation is inconsistent:** the NatSpec at `KAY9AuditHub.sol:262` and the deploy script at `DeployWatchdog.s.sol:172` call `publishWatchdogReport` "permissionless", but it is gated by `_requireAuditorSubmitter` (:518).
- **`setAccessVault` does not check the vault's binding** (:539-547): it checks the tier constants only, not that `accessVault_.auditHub() == address(this)`. A mismatched vault would make every `requestAudit` revert, which is recoverable only through the vault's own timelocked `setAuditHub`, because the hub cannot be re-pointed. `renounceOwnership` (inherited, callable by the timelock) before `setAccessVault` would also close requests forever. Both are governance errors that the timelock makes visible.

---

## The ten properties

| # | Property | Verdict | Reason |
|---|---|---|---|
| 1 | Only the timelock governs; the deployer keeps no role | **Holds, conditionally** | `KAY9AuditorRegistry` and `KAY9AuditHub` are built with `owner_ = timelock` (script :152, :178). `KAY9Registry` has no owner. The timelock has `admin = address(0)`, so only the timelock itself holds `DEFAULT_ADMIN_ROLE`, and `ownerSafe` is its only proposer, canceller and executor. The deployer holds no timelock role. Every setter (`addAuditor`, `removeAuditor`, `setThreshold`, `setScanner`, `setSla`, `setRequestsPaused`, `setAccessVault`) is `onlyOwner`. The condition: the property holds only **after** `acceptOwnership` on the scan registry, **and** only if the deployer did not add itself or others as scanners (F3), because those authorisations persist. |
| 2 | Only the hub writes; quorum of distinct current auditors on one EIP-712 digest; no replay | **Holds** | `recordReport` checks `msg.sender == auditHub` (immutable). The watchdog path requires strictly ascending recovered signers (so they are distinct), each `isAuditor`, and `count >= threshold > 0`. The job path tracks one position per address and finalises only when `_activeHolders` (the holders still in the set) `>= threshold`. The EIP-712 domain binds the chain id and the hub address (OZ `EIP712` rebuilds the separator on a fork). The struct binds `jobId`, which is >=1 for jobs and 0 for watchdog reports. Watchdog digests are deduplicated. OZ 5.x `ECDSA.recover` rejects high-s signatures. `reportURI` is unsigned by design. |
| 3 | Append-only; `latest` is the most recent record, never a merge | **Holds** (literally) | No function modifies or deletes `_reports` or `_history`, and `latest*` returns the single last entry. See F2: "most recent record" means most recently *committed*, and one auditor can control which signed snapshot that is. |
| 4 | No averaging; disputes on-chain when agreement is impossible; one position per auditor per job | **Holds** | Votes are counted per digest; there is no arithmetic across digests. `attestationOf` blocks a second position from the same address, including after removal and re-add. The dispute test `best + silent(active, not yet voted) < threshold` never disputes early, because no position can exceed `best + silent`. Stale holders make it more conservative, not less (documented). Caveat: the dispute is judged against the current set, and a halted registry never disputes (F7, F9). |
| 5 | Scanner or auditor only; batches immutable; `verifyScan` exact; at most 500 scans | **Broken** | Authorisation and immutability hold: `_batches` is only ever pushed. **Broken:** `count` is unbounded, since `MAX_BATCH` limits only the indexed summaries (F5), and `verifyScan` accepts internal nodes and the root as leaves (F6). |
| 6 | Before the vault: request reverts and publish works; vault set once, by the owner, forever | **Holds** | `requestAudit` reverts with `AccessVaultNotSet` (:368). `publishWatchdogReport` never touches the vault. `setAccessVault` is `onlyOwner`, refuses zero, and refuses a second call (:540); nothing else writes `accessVault`. Note that `markExpired` and dispute can only reach `accessVault.restore` for a job, and no job can exist before the vault is set. |
| 7 | Nobody pays; no fee, no ETH or tokens held, nobody's funds moved | **Holds** for the four KAY9 contracts | None has a `payable` function or a `receive`/`fallback`, and none makes a token or ETH transfer. The hub calls the vault only through `consume` and `restore`, which are quota counters. Nuance: the deployed OZ `TimelockController` has `receive() payable` and can hold and move its own ETH or tokens through proposals. That is governance's own balance, not a user's. |
| 8 | Removal can halt but never lets fewer than `threshold` publish; threshold stays within [1, count] while any auditor exists | **First clause holds; second clause broken** | Publishing always checks the *current* threshold against current auditors. But (a) removal lowers the threshold itself, down to 1 (F4), so fewer signers than the configured quorum can publish without any `setThreshold`; and (b) after removing everyone and adding one auditor back, count is 1 and threshold is 0 (F7). This is intended and safe, but it contradicts the property as worded. |
| 9 | Requester declaration or payment cannot change a score | **Holds on-chain** | `declaredRequesterKind` is range-checked, stored in `Job` and `ReportMeta`, and emitted. It is never part of the signed digest and never read by any on-chain logic that decides anything. Nothing is paid. Whether the off-chain engine ignores it (the hub emits it in `AuditRequested`, so auditors can see it) cannot be checked from these contracts. |
| 10 | Every recorded block number is the chain's own height via ArbSys | **Holds** | `requestedBlock`, `committedBlock` (in both registries) all come from `BlockNumberish._getBlockNumberish()`. `block.number` is not used anywhere in scope. `BlockNumberish` enables ArbSys at construction when `extcodesize(0x64) > 0` and the call returns 32 bytes. I checked this live on chain 4663 (`rpc.mainnet.chain.robinhood.com`): the code at 0x64 is `0xfe`; `arbBlockNumber()` = 71,499,459; `eth_blockNumber` = 71,499,465; `Multicall3.getBlockNumber()` (`block.number`) = 26,048,392. So a contract deployed there uses ArbSys. `ScanSummary.scannedAtBlock` is a caller-supplied height on the *scanned* chain, which the contract only emits; it is not a recorded height. |

---

## What I did not cover or could not verify

- **Deployed bytecode:** I did not compare any deployed instance against this commit, and I did not check whether a watchdog deployment exists on-chain or what state it is in (owner, `pendingOwner`, scanner history).
- **Vault and launch path:** `KAY9AccessVault` I read only as far as the `consume` and `restore` signatures and the tier constants; I did not review whether its `consume` and `restore` are correct. The launch path contracts are out of scope and were not read.
- **Third-party libraries:** I did not audit OpenZeppelin 5.4 (`TimelockController`, `Ownable2Step`, `EIP712`, `ECDSA`, `ReentrancyGuard`) or Uniswap `BlockNumberish` themselves; I assumed they are correct and checked only how they are used. I did confirm that the vendored OZ under `lib/` is labelled v5.4.0 and is a partial, vendored copy rather than a git submodule. I did not verify that it is byte-identical to upstream.
- **Off-chain components:** the off-chain relay, scanner and auditor services, the Merkle tree builder, the batch document format and the website are out of scope. F1, F2 and F6 all depend on how off-chain readers behave, which I did not examine.
- **Signing side:** I did not check that off-chain signers build the EIP-712 type string exactly as `RESULT_TYPEHASH` defines it. On-chain I confirmed that the four-chunk `abi.encode` concatenation equals a single encoding, because all members are static.
- **Fuzzing and gas:** I did not run the invariant or fork suites, and I did not fuzz the dispute arithmetic across auditor rotations beyond reasoning about it. I did not measure gas limits for `_disputeIfUnreachable` or `_activeHolders` on large auditor sets (they iterate over the whole set, which is fine at 3 and grows linearly).
- **Timelock operation:** I did not examine the owner Safe's own configuration (signers, threshold, or whether `OWNER_SAFE` is a contract at all; the script does not check).
- **F3 in practice:** I am not certain the deploying key would ever misuse the window in F3. It is a trusted key in practice, and the script prints the handover instruction. I rank F3 Low for that reason.

## Reviewer

Claude Opus 5.5 (model id `claude-opus-5-5[1m]`, 1M-context variant), by Anthropic, running as a Claude Code subagent. Review date 2026-09-25.
