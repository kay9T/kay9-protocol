# Watchdog-stack model review — OpenAI GPT-5.6 Sol, 2026-09-25

| | |
|---|---|
| Model | GPT-5.6 Sol (OpenAI), as the model reported it |
| Interface | ChatGPT, one fresh thread with no prior project context |
| Date | 2026-09-25 |
| Commit | `c38dd247c44b6e76d87b438f15364181b63f4945` of `kay9T/kay9-protocol`, tag `watchdog-review-1` |
| Scope | `KAY9AuditorRegistry`, `KAY9AuditHub`, `KAY9Registry`, `KAY9ScanRegistry` and `DeployWatchdog.s.sol` |
| Prompt | [`WATCHDOG_REVIEW_PROMPT.md`](WATCHDOG_REVIEW_PROMPT.md), verbatim |

This is a model review, not a professional audit. It is one of the two model families gate 6
asks for on the watchdog stack, which goes to mainnet before the token.

## Dispositions

Each finding was checked against the source before it was decided. The fixes are at
`watchdog-review-2`.

| Finding | Held? | Disposition |
|---|---|---|
| F-01 — the deploying key can stay a scanner or an auditor | Yes. `_validate` refused the deployer only as owner, and the script warned about a deployer scanner instead of failing | **Fixed.** `DeployWatchdog.s.sol` refuses the deployer in `AUDITORS` and `SCANNERS`, and the scan registry is now owned by the timelock from its constructor, with the scanners named there, so the deploying key holds nothing at any point |
| F-02 — a lowered threshold can leave a met quorum with no way to finalise | Yes | **Fixed.** New `finalizeAgreed(jobId, result)` settles a recorded position that meets the current threshold, with the same auditor submitter, deadline and active-holder rules as `attest`. Regression: `test_aLoweredThresholdIsSettledByFinalizeAgreed` |
| F-03 — after rotation, the dispute check counts removed auditors' votes | Yes | **Fixed.** The check counts each position's **active** holders, over every position the job has seen. Regression: `test_rotationDisputesWhenOnlyRemovedAuditorsAgreed`, your exact scenario |
| F-04 — `latestScan` is not proven against the batch root | Yes | **Accepted and stated.** `latestScan` is documented as an index the scanner supplies. What changed around it: auditors are no longer scanners by default, the owner can revoke a scanner at once through a new guardian role, and a score above 100 is refused. A per-summary Merkle proof was not added, because it puts a proof per indexed scan in calldata, which this chain pays for on its parent chain; the root and the summaries are both on-chain, so a mismatch stays provable |
| F-05 — `publishWatchdogReport` is described as permissionless but is auditor-only | Yes | **Fixed in the documentation.** Auditor-only submission is intended, for the unsigned `reportURI` reason `attest` gives; every "permissionless" claim about it is gone |
| F-06 — the 500 bound applies to summaries, not to the batch | Yes | **Fixed.** `commitScanBatch` refuses a `count` above `MAX_BATCH`, which the worker's own batch limit already matched |
| F-07 — more than 255 auditors can overflow the uint8 counters | Yes, in a configuration nobody plans | **Fixed.** `KAY9AuditorRegistry.MAX_AUDITORS` is 32 |
| F-08 — a non-empty set can have threshold zero | Yes | **Accepted, and the property is restated.** Zero means halted, and nothing publishes while it holds. The state is now also reached when a removal would leave fewer auditors than the threshold, which Anthropic's review asked for (its F4). Property 8 reads: the threshold is zero, meaning halted, or within [1, auditor count] |
| F-09 — `scannedAtBlock` is not read on-chain | Yes | **Accepted, and property 10 is narrowed.** `scannedAtBlock` is the scanner's statement of the block it read, on the scanned asset's own chain, which may not be this one. The contract cannot check it, and the docs now say so. The block numbers the contracts record themselves come from ArbSys |
| F-10 — the script deploys to any chain | Yes | **Fixed.** `DeployWatchdog.s.sol` runs only on Robinhood Chain mainnet, its testnet and a local chain |

## Verification at `watchdog-review-2`

Same reviewer, on `dc56681878eaae5f1a9b35ac7e14041b0706a654`. The model identified itself this time as "GPT-6 Astra Pro"; the thread and its setting did not change between rounds, and the text is published as it came.

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

solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
KAY9 Watchdog — Verification Review

Repository: kay9T/kay9-protocol
Commit reviewed: dc56681878eaae5f1a9b35ac7e14041b0706a654
Baseline: c38dd247c44b6e76d87b438f15364181b63f4945

The quotation above is from src/KAY9ScanRegistry.sol:1–2 at the requested commit. The reviewed scan-registry blob is 8853d99e186efc24607811a30600b98f2f9358ec.

Assessment

Seven previous findings close against the implemented fixes or explicitly revised requirements. Three narrow rather than disappear: F-03, F-04 and F-07.

The verification also identifies an incomplete interaction in the new watchdog freshness protection and a recovery limitation introduced by the immutable guardian. These are distinguished below from pre-existing behavior.

This is a source-level verification with independently executed state-transition models, not an executed Solidity test report. Existing regression tests were inspected, not run.

1. Findings and remaining defects, ranked by severity
R2-01 — A late requested report can reset the new watchdog freshness comparison

Severity: Medium
Classification: Incomplete protection in the second review’s freshness fix; not a signature-verification bypass.

Locations:
src/KAY9AuditHub.sol:575–583 — watchdog freshness check.
src/KAY9AuditHub.sol:697–713 — requested-job finalisation.
src/KAY9Registry.sol:251–259 — latestAnalyzedAt.

The new watchdog check compares the submitted analysis time with the last committed record’s analysis time. Requested-job finalisation can append an older analysis without a corresponding freshness restriction. Consequently, the value against which watchdog freshness is checked can move backwards. The getter does not preserve the greatest analysis time previously recorded.

Concrete failure scenario

This scenario applies after the access vault is bound, when requested jobs exist. Every result carries a valid quorum, every signer remains current, and all submissions occur before the job’s deadline.

Order	Action	Last committed analysis time
1	A job is requested at 10:00. Auditors produce a quorum-signed result for that job, but its finalising submission is delayed.	—
2	Auditors sign watchdog report W_old, analysed at 10:30 with trust score 90. It is not published.	—
3	Watchdog report W_new, analysed at 11:00 with trust score 10, is published. Publishing W_old now correctly reverts.	11:00
4	At 11:05, a current auditor submits the valid signatures finalising the pending 10:00 job. _finalize appends it.	10:00
5	At 11:06, a current auditor submits W_old. Its digest is unused, and 10:30 is greater than the current comparison value of 10:00. It succeeds.	10:30

The final watchdog report is older than a watchdog report already published at 11:00, yet becomes the last committed report.

What this does and does not establish

The literal predicate “newer than the asset’s current last record” is implemented correctly. The broader security conclusion in the new comment—that a single auditor cannot make an older signed snapshot latest—does not follow once requested reports and watchdog reports share the log.

This does not affect the pre-token, zero-vault deployment in the same way: the intervening requested job cannot exist there. It also does not forge scores, violate quorum, modify old records, or replay an already-committed watchdog digest.

Suggested fix

Maintain a separate, monotonic per-asset maximum recorded analyzedAt, updated whenever either report path appends. Compare watchdog submissions against that maximum rather than against the commitment-order tail.

Preserve the ability to append historical requested-job results; simply rejecting them can interfere with job settlement. If consumers need the freshest analysis rather than the latest commitment, expose a separate freshest-analysis pointer without changing the append-only history.

The added regression test_aStaleWatchdogReportCannotBecomeLatest covers a newer watchdog followed directly by an older watchdog. It does not cover an intervening requested-job finalisation.

R2-02 — The immutable guardian retains revocation power after its Safe address is retired

Severity: Medium
Classification: New authority-recovery limitation introduced by the guardian fix.

Locations:
src/KAY9ScanRegistry.sol:144 — immutable guardian.
src/KAY9ScanRegistry.sol:180–190 — constructor assignment.
src/KAY9ScanRegistry.sol:390–394 — immediate revocation.
src/KAY9ScanRegistry.sol:407–411 — owner-controlled scanner authorization.

Deployment assigns the guardian to the initial OWNER_SAFE, while the contract owner is the timelock. The guardian is immutable; neither changing the timelock’s governance roles nor transferring contract ownership changes that address. There is no guardian replacement or retirement function.

Concrete failure scenario

The initial governance Safe is G1, which is also the scanner guardian. Governance later migrates to Safe G2 and removes G1’s timelock roles through properly scheduled operations.

G1 is subsequently compromised or becomes controlled by former signatories who are no longer trusted. Although it has no remaining timelock role, it is still the scan registry’s immutable guardian.

Whenever legitimate governance authorizes a scanner, G1 can immediately revoke it. The same applies to replacement scanners. Normal scanner operation can therefore be repeatedly disrupted by an address that governance has otherwise retired.

Impact and qualification

This is a scanner-availability and authority-retirement problem. The guardian cannot append reports, authorize scanners, change quorum, rewrite batches, or take funds.

Rotating signers within the same Safe address can preserve a trusted guardian and avoids this particular address-migration problem. The defect appears when the Safe address itself must be replaced or its control cannot safely be recovered.

Suggested fix

Make guardian replacement a timelocked onlyOwner operation, emitting the previous and replacement addresses. Preserve the guardian’s removal-only powers.

Governance can then migrate its timelock roles and guardian designation together. Immediate scanner revocation should remain available; the missing capability is retiring the address that holds that emergency power.

R2-03 — F-03’s arithmetic is repaired, but membership changes alone still cannot trigger a dispute

Severity: Low
Classification: Pre-existing residual behavior, not a regression introduced by this commit.

Locations:
src/KAY9AuditHub.sol:496–524 — dispute evaluation follows a successful new attestation.
src/KAY9AuditHub.sol:537–555 — finalizeAgreed only settles an existing quorum.
src/KAY9AuditHub.sol:755–786 — active-holder dispute calculation.

The new calculation correctly excludes removed auditors from both the agreement count and the silent-member count. However, it is still called only from a successful attest. Auditor-registry changes do not invoke it, and there is no separate dispute-rechecking entry point.

Concrete failure scenario

The current set is A, B, C, with threshold two.

A attests to X; B attests to a different result Y. The job correctly remains open because silent auditor C could agree with either.

Governance then removes C. Two auditors remain, so the new removal rule leaves the threshold at two rather than halting the registry.

Agreement is now impossible: both remaining auditors have already taken incompatible positions. Nevertheless:

Another attestation from A or B reverts with AlreadyAttested.

An attestation from removed auditor C is rejected.

finalizeAgreed(X) and finalizeAgreed(Y) revert because neither has quorum.

The private dispute calculation is never reached.

The job remains Requested until expiry instead of becoming Disputed.

Impact

The requester’s quota remains consumed until the SLA expiry path is used, and the on-chain status does not express the already-established impossibility of agreement. No contradictory report is published.

The existing test test_aJobNobodyCanStillFinaliseWaitsForTheSlaRatherThanDisputing explicitly codifies this behavior. Accordingly, I am not presenting it as a newly introduced bug or claiming that the original F-03 regression remains unfixed. It is a remaining mismatch with the broader “dispute as soon as agreement is impossible” requirement.

Suggested fix

Add a callable per-job dispute recheck that uses current membership, enforces the appropriate job status and deadline rules, and restores quota at most once. It need not accept signatures or a result.

Alternatively, explicitly narrow property 4: the contract detects unreachable agreement when a successful attestation evaluates it, while membership-only impossibility may wait for expiry.

R2-04 — F-07’s 32-member cap does not bound cumulative attestations across rotations

Severity: Low
Classification: Incomplete fix; the original 300-current-auditor example is prevented, but the counter failure remains reachable.

Locations:
src/KAY9AuditorRegistry.sol:182–188 — cap on the current set.
src/KAY9AuditHub.sol:493–507 — historical digest tracking and uint8 increments.
src/KAY9AuditHub.sol:328–334 — historical vote counters and position storage.

The cap limits concurrent members, not the number of different addresses that can attest during one job’s lifetime. Removed auditors’ positions and the job’s cumulative attestations count remain recorded. job.attestations still overflows when the 256th distinct historical signer is processed. The updated comment acknowledges that many rotations can reach this limit.

Concrete failure scenario

Use the permitted 30-day SLA, 32 current auditors, and threshold two.

Keep one auditor silent throughout. The other 31 each attest to different results. No result reaches quorum, but the job remains reachable because the silent auditor could agree with one position.

Governance replaces those 31 auditors with 31 fresh addresses, keeping the current set at or below 32. Repeat the voting and replacement process.

After eight groups of 31 votes and eight replacements, 248 historical attestations exist. Eight sequential 48-hour governance delays occupy 16 days, within the 30-day SLA.

Seven auditors in the next group take distinct positions, bringing the historical count to 255. An eighth then submits a valid signature agreeing with one of those seven. That signature would form a current two-auditor quorum, but:

solidity
job.attestations += 1;

overflows before finalisation is checked. The transaction reverts, including the new vote. finalizeAgreed cannot recover this case because the second agreeing vote was never recorded.

Impact and qualification

A valid, reachable quorum cannot be recorded without further governance intervention or expiry. This requires unusually extensive, authorized auditor rotation; it is not an attack available to an ordinary requester. That limits its severity, but does not make the counter invariant true.

The same distinction applies to _jobDigests: its length is not bounded by the current 32-member set.

Suggested fix

Widen the cumulative per-job counters and matching event/getter types. Alternatively, explicitly bound historical participation per job and define a safe terminal transition when that bound is reached, rather than allowing an arithmetic panic to block settlement.

Correction to my previous recommendation: suggesting a current-set cap as sufficient was incomplete. Such a cap prevents growth beyond 255 simultaneous members, but does not prevent more than 255 historical participants across rotations.

2. Disposition of the original ten findings

“Closed” below includes a specification mismatch resolved by an explicitly accepted replacement requirement. It does not mean the original stronger requirement has somehow become true.

Finding	Verdict	Verification
F-01 — Deploying key retains roles	Closed	_validate rejects the deployer in both AUDITORS and SCANNERS, as well as OWNER_SAFE. The scan registry now receives the timelock owner and initial scanners in its constructor. The timelock is constructed with no optional external admin. This closes the direct-role and temporary-owner paths identified previously. It does not establish who controls the configured Safe or other keys.
F-02 — Lowered threshold leaves an unfinalizable quorum	Closed	finalizeAgreed supplies the missing entry point. It checks the caller, job status, deadline, asset, nonzero current threshold, and current active holders of the supplied digest. It does not require an already-voted auditor to vote again.
F-03 — Removed votes suppress disputes	Narrowed	The original removed-vote calculation is fixed: every recorded position is evaluated using current active holders. The broader immediate-dispute guarantee still has the membership-only trigger gap described in R2-03.
F-04 — Latest scan score is not proven against the root	Narrowed	The index is now explicitly documented as scanner-supplied, auditors are no longer implicitly scanners, immediate revocation exists, and indexed trust scores above 100 are rejected. However, the exact root/summary mismatch remains possible. This is an accepted trust limitation, not a cryptographic repair.
F-05 — Permissionless publication claim is false	Closed	Auditor-only submission is now explicit in the function documentation and consistent with the retained caller check. I accept the revised requirement; no permissionless relaying guarantee remains in the reviewed function.
F-06 — Batch count exceeds 500	Closed for the reported check	count > MAX_BATCH now reverts, and summaries.length <= count also bounds the indexing loop. This enforces the declared count, not the actual cardinality of an independently supplied Merkle tree; the source now acknowledges that distinction.
F-07 — Attestation counters overflow	Narrowed	MAX_AUDITORS = 32 prevents the original oversized-current-set configuration. It does not prevent cumulative per-job overflow after rotations. R2-04 remains.
F-08 — Nonempty set with threshold zero	Closed against revised property 8	Zero is now an explicitly permitted halted state. A removal below the existing threshold sets zero rather than choosing a smaller quorum; recovery requires an explicit threshold decision. The report-publication paths reject zero.
F-09 — Scanner-supplied height is unchecked	Closed against revised property 10	The revised requirement distinguishes scanner assertions about the scanned asset’s chain from contract-generated local heights. The unchecked input is no longer represented as an on-chain-derived value. Actual ArbSys selection in a live deployment was not verified.
F-10 — Wrong-chain deployment is accepted	Closed	run now rejects unsupported chain IDs before deployment. The supported set is explicitly 4663, 46630 and local chain 31337. Mainnet still requires its confirmation phrase.
3. Accepted-in-writing dispositions
F-04 — Unverified scanner index

I accept the decision to expose an explicitly unverified scanner-supplied index. I do not treat it as elimination of the original data-integrity limitation.

The revised wording correctly separates a Merkle commitment from the convenience index. Separating scanner authorization from auditor membership and enabling emergency revocation reduce exposure, but neither makes a supplied summary a member of the committed tree. Revocation also does not correct a bad value already recorded; a subsequent honest indexed batch must replace it.

I accept the qualitative calldata-cost tradeoff as a design choice, without claiming to have verified its economic justification.

I do not accept an unconditional assertion that publishing a root and summaries alone guarantees detection or a self-contained proof of every mismatch. Checking against the committed dataset depends on obtaining the relevant document and data needed to reconstruct it. The contract does not guarantee that availability.

Acceptance of this weaker index model does not close the guardian-retirement concern in R2-02.

F-08 — Explicit halted state

I accept the revised invariant:

threshold == 0
OR
1 <= threshold <= auditorCount

Requiring an explicit quorum decision after a removal causes a halt is consistent with avoiding an automatic reduction to one signer. Adding members while halted does not silently resume publication.

One wording distinction matters: halted means no report can finalise through the hub. It does not mean attest necessarily rejects every incoming position. The implementation can record positions at threshold zero, while declining both finalisation and dispute. Documentation should not equate those different behaviors.

F-09 — Local recorded heights versus remote analysis assertions

I accept the revised distinction.

A scan can describe an asset on another chain. Its historical scannedAtBlock is therefore not generally something that should be replaced with this deployment’s current ArbSys height. Recording it as a scanner assertion is coherent.

The contract-generated requestedBlock and committedBlock fields use BlockNumberish. Its pinned implementation selects ArbSys through a constructor probe and otherwise falls back to block.number. Thus the local-chain test allowance does not itself establish an ArbSys guarantee, and a real Robinhood deployment still requires verification that the intended branch was selected.

F-05 — Auditor-only submission

I also accept this documentation-only disposition.

Keeping transaction submission restricted to current auditors is consistent with intentionally leaving reportURI outside the signed digest. That does not make the URI quorum-authenticated; it means choosing the permanent pointer remains a trusted current-auditor action.

4. Other changed-code checks

finalizeAgreed does not create an unsigned-result publication path. It must find enough active holders of the exact supplied digest. Although it does not repeat _checkResult, positions can only have been recorded through attest, which validates the signed score and analysis-time fields before storing them. The deliberately unsigned URI is a separate, already-described trust boundary. I found no additional validation bypass in this change.

The new scan validation remains transactionally atomic. The score check occurs inside the summaries loop after the batch push, but a revert rejects the whole transaction; it does not leave a partially accepted batch. The authorization change consistently removes implicit auditor access. An auditor can still be a scanner if explicitly authorized, which is different from implicit membership.

The disabled renunciation paths cover the intended Ownable contracts: the hub, auditor registry and scan registry. The append-only report registry does not acquire an owner or a mutable writer through these changes.

The original blanket timelock claim must reflect the intended new exception. Scanner additions remain owner-controlled, but the initial owner Safe, acting as guardian, can revoke scanners immediately. That is an explicit change to the authority model, not preservation of the former claim that every scanner change waits 48 hours. The guardian is the configured Safe, not the scan registry’s owner() address, which is the timelock.

5. Verification performed and limitations

I inspected the pinned in-scope contract sources, deployment changes, both disposition documents and relevant regression tests.

I also executed independent Python state-transition models that checked:

The positive F-02 case now has a finalisation path, and the original F-03 removed-holder example now disputes.

A membership-only change can leave an unreachable job without a callable dispute transition.

The cumulative counter can reach 255 with only 32 current members and fail on a quorum-forming next vote.

A requested-job append can lower the comparison value used by the new watchdog freshness rule.

These models assume valid signatures and authorized governance operations. They are not EVM executions, Solidity compilation results or replacements for Foundry regression tests.

I did not compile the contracts, run the Foundry suite, execute Solidity proofs of concept, benchmark gas, or validate a live deployment. Consequently, I do not claim that repository tests pass, that deployed bytecode matches this commit, or that production ownership, guardian, scanner and timelock roles have been checked.

The launch contracts, website and off-chain services remain out of scope. I did not establish scanner-document availability, actual Merkle leaf counts, scoring independence from requester metadata, Safe signer control, or the correctness of later access-vault wiring.

Model

Model: GPT-6 Astra Pro.
Version detail: No finer internal build or weights-revision identifier is exposed to me.

## Final confirmation at `watchdog-review-3`

Same thread, on `c6cc435824c1b1da7c87920ecb248f7ba01ccdd3`. **R2-01 to R2-04 closed, and the
commit confirmed for the watchdog deployment.** One new low finding, R3-01: a contested dispute
reported the submitted position's size instead of the largest agreement in its event. **Fixed at
`watchdog-review-4`**: every position is counted before the decision, and the event carries the
largest active agreement. Regression: `test_aContestedDisputeReportsTheLargestAgreement`.

### The confirmation, verbatim

solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
KAY9 Watchdog — Final Confirmation Review

Repository: kay9T/kay9-protocol
Commit reviewed: c6cc435824c1b1da7c87920ecb248f7ba01ccdd3
Comparison baseline: dc56681878eaae5f1a9b35ac7e14041b0706a654

The opening quotation is from src/KAY9AuditHub.sol:1–2 at the requested commit. Its blob SHA is aea44245ae21227c59240822f77b8964902e36b2.

1. Deployment decision

Yes: I confirm this commit for the described pre-token watchdog deployment from a source-review perspective. R2-01 through R2-04 are closed. I found no deployment-blocking code defect in this closing pass.

One new Low-severity correctness defect remains: the contested-quorum path can emit an incorrect AuditDisputed.bestAgreement value. It does not select or publish the wrong report, bypass quorum, or change quota restoration. It is documented as R3-01 below rather than concealed by the deployment confirmation.

That defect is on the requested-job path, which cannot operate in the described initial deployment because the hub has no access vault. However, the hub is intended to be the permanent one: deploying this commit retains the diagnostic defect for later requested-job operation. Correcting it before deployment avoids accepting it in that permanent contract.

This confirmation does not certify that compilation, the Solidity test suite, deployment rehearsal, or production configuration checks have passed. Those verification limits are stated in section 5.

2. Verification of R2-01 through R2-04
Finding	Status	Reason
R2-01 — A requested report resets watchdog freshness	Closed	recordReport updates _maxAnalyzedAt using the maximum of the existing value and the appended result’s analysis time. Both report paths use this append function. latestAnalyzedAt returns that maximum, with existence determined separately from the history. An older requested result can still settle, but cannot lower the watchdog admission boundary.
R2-02 — A retired guardian retains permanent revocation power	Closed	guardian is replaceable through setGuardian, which is onlyOwner, rejects zero, and emits the old and new addresses. revokeScanner checks the current guardian variable, so the previous guardian loses this capability immediately when replacement executes. The deployment assigns ownership to the timelock.
R2-03 — Membership-only impossibility cannot trigger a dispute	Closed	Permissionless checkDispute(jobId) supplies the missing entry point without requiring a new vote. It checks existence, Requested status and the job’s frozen deadline, then invokes the membership-aware calculation. A successful dispute sets the terminal status and restores quota; another call cannot restore it again. A zero threshold retains the explicitly accepted halted behavior.
R2-04 — Historical votes overflow despite a 32-member current-set cap	Closed for the reported failure	Job.attestations, digestVotes, bestAgreement, the local votes variable and the corresponding event counters are widened to uint16. The reported quorum-forming 256th vote no longer encounters a uint8 increment or truncation. The quorum threshold remains separately represented as uint8. This closes the demonstrated failure; it is not a claim that arbitrary historical growth can never exhaust a finite counter or transaction gas.
R2-01: the original interleaving is now rejected

For the previously reported sequence—watchdog analysis at 11:00, followed by a requested-job analysis at 10:00—the stored maximum remains 11:00. A previously unpublished watchdog result analysed at 10:30 is therefore rejected.

The distinction between commitment order and analysis freshness remains important. latest still returns the last committed record; latestAnalyzedAt now returns the greatest analysis timestamp across the asset’s history. The fix does not prevent historical requested-job results from being appended, nor does it represent their scores as belonging to the maximum timestamp.

R2-03: the original no-vote-left scenario now has an exit

With auditors A, B, C and threshold two, suppose A holds X, B holds Y, and silent auditor C is removed. Calling checkDispute now finds zero silent current auditors and a maximum active agreement of one. It disputes the job without needing a signature from an already-voted or removed auditor.

At or after the deadline, checkDispute rejects the call and leaves expiry to markExpired. This preserves the existing hard deadline rather than creating overlapping terminal paths.

3. New finding in the changed code
R3-01 — A contested-quorum dispute reports the submitted position’s size, not the largest agreement

Severity: Low
Status: Open
Locations: src/KAY9AuditHub.sol:829–831 and 842–845

When _finalizeUnlessContested finds another qualifying position, it calls:

solidity
_dispute(jobId, job, holders.length, required);

Here, holders.length is the number of active holders of the submitted position. It is not necessarily the largest active agreement on the job. _dispute emits that argument as AuditDisputed.bestAgreement, even though its parameter documentation explicitly identifies it as the largest active agreement.

Concrete failure scenario

Governance has configured six current auditors, A through F, threshold four, and a sufficiently long SLA for the job to remain pending across a timelock operation.

A requester opens a valid job.

A, B and C attest to result X. D and E attest to contradictory result Y. F remains silent.

The job remains Requested: X has three active holders and can still reach four through F.

Governance lowers the threshold to two before the job expires.

A current auditor calls finalizeAgreed(jobId, Y).

Both positions meet the new threshold. The contract correctly disputes the job, writes neither result to the report registry, and restores its quota unit. But it emits:

AuditDisputed(jobId, 5, 2, 2)

The largest active agreement is three, so the documented event value should instead be:

AuditDisputed(jobId, 5, 3, 2)

Calling finalizeAgreed(jobId, X) from the equivalent starting state produces the latter value. Thus the caller can affect the reported bestAgreement by choosing which qualifying position to submit, even though the terminal dispute outcome is correctly independent of that choice.

Impact

The on-chain dispute event contains an incorrect diagnostic value. Consumers reconstructing agreement strength from this event receive different answers for equivalent disputes.

This is not a surviving version of the contradictory-report selection defect: neither result enters KAY9Registry, and quota restoration still occurs once.

Suggested fix

Count the active holders of all recorded positions, retain the maximum, and separately determine whether more than one position meets the threshold. If the result is contested, pass the actual maximum into _dispute.

Do not return immediately on the first competing quorum if the event continues to promise the largest active agreement.

Deployment relevance

This does not block basic scan commitments or pre-token watchdog publication. It is nevertheless a real correctness defect in the permanent hub, not merely an inaccurate comment.

4. Review of the other changed behavior
Contradictory recorded quorums no longer let the submitter select the report

Both requested-report finalisation routes now pass through _finalizeUnlessContested after establishing that the submitted position meets the current nonzero quorum.

The helper checks the other recorded digests using current active holders, not historical vote counts. If another position also meets the threshold, it disputes the job rather than recording either result. Consequently, the second family’s demonstrated lowered-threshold report-selection scenario is closed on both attest and finalizeAgreed. The remaining issue is the event value identified above.

This guarantee concerns positions already recorded on-chain. It cannot account for contradictory signatures that have never been submitted; I have not interpreted the fix as claiming otherwise.

The new permissionless function does not create a report-writing bypass

checkDispute accepts only a job ID. It cannot supply a result, replace a digest, nominate signers or append a report. Its terminal action uses the same dispute routine as the other paths. The entry point is non-reentrant and requires the job still to be Requested. I found no new arbitrary-dispute or repeated-refund path in this change.

Guardian replacement preserves the separation of powers

The new setter changes the guardian address; it does not grant scanner authorization or transfer ownership. The guardian’s direct capability remains scanner revocation, while scanner authorization remains onlyOwner. Replacing a guardian does not automatically reauthorize scanners that the previous guardian already revoked.

The counter change requires the new ABI

Widening the counters also changes the canonical signatures of AuditAttested and AuditDisputed, and therefore their event topics. Deployment artifacts and event consumers must use the ABI generated from this commit rather than the round-two ABI. This is a release-integration requirement, not a defect in the widening itself. The event declaration changes are visible in the pinned source; Solidity defines the event signature using its parameter types. 
Solidity Documentation

5. Verification evidence and limits
Source and regression-test inspection

I read the changed contract logic at the pinned commit and the disposition entries. The added Solidity regressions inspected were:

Regression	What its assertions cover
test_aJobRecordDoesNotReopenTheWatchdogFreshnessWindow	Rejecting the older watchdog result after an intervening historical job result.
test_theOwnerReplacesTheGuardian	Rejecting guardian self-replacement, permitting owner replacement, denying the old guardian and permitting the replacement.
test_checkDisputeSettlesAMembershipOnlyImpossibility	Leaving a still-reachable job open, disputing after removal of the silent member, and rejecting a repeated terminal call.
test_contestedPositionsAfterALoweredThresholdDispute	Disputing through finalizeAgreed without appending either contradictory result.

These are inspected test definitions, not tests I executed. The added contested-position test uses equal-sized positions, so it does not expose R3-01.

Executed model checks

I executed independent Python models of the relevant state transitions. They exercised the high-water-mark behavior, guardian replacement, membership-only dispute, halt and deadline boundaries, the quorum-forming 256th historical vote, and contested finalisation through both public routes.

The small-model checks covered 1,024 timestamp sequences and 114,688 membership/position/threshold combinations. The models also reproduced R3-01: choosing X versus Y produced different bestAgreement event values while preserving the same dispute status, empty report output and single quota restoration.

These checks do not execute Solidity, ECDSA recovery, storage layout, gas accounting or EVM calls.

Not verified

I did not compile this tree, run Foundry, execute Solidity proofs of concept, measure deployed bytecode size, or perform a live-chain deployment rehearsal. The GitHub check-run query for this exact commit returned no runs; that is an absence of execution evidence, not a test failure.

I did not verify production Safe control, actual deployed roles, deployed bytecode hashes, chain connectivity, or successful ArbSys selection in deployed contracts. Launch contracts, off-chain services and access-vault custody remain outside this closing review.

6. Remaining items and scope of confirmation

Deployment-blocking code findings identified in this pass: none.

Open code finding: R3-01, Low severity, concerning requested-job dispute-event accuracy. It does not invalidate the closure of R2-01 through R2-04.

The previously accepted boundaries remain accepted, not eliminated: scanner-supplied latest scores are not proven against their batch roots; scannedAtBlock is a scanner assertion; threshold zero is a permitted halted state; and report submission remains auditor-only with an unsigned URI. None of these was represented as newly fixed in this round.

The release checks still needing independent confirmation are a successful build and Solidity test run for this exact commit, use of its generated ABI, and verification of the intended chain, contract wiring, governance delay and deployed roles. Their unverified status limits this report to source-review deployment confirmation, rather than certification that all operational release gates have passed.

Model

GPT-6 Astra Pro. No finer internal build or weights-revision identifier is exposed to me.

## The review, verbatim

The text below is the reply as ChatGPT displayed it, copied from the thread without edits.

KAY9 Watchdog Security and Correctness Review — c38dd247
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
KAY9 Watchdog Security and Correctness Review

Repository: kay9T/kay9-protocol
Commit reviewed: c38dd247c44b6e76d87b438f15364181b63f4945
Scope: only the watchdog contracts, deployment script, and directly relevant imported code named in the request.

Findings
F-01 — Deployment validation does not guarantee that the deploying key loses every role

Severity: Medium

Location: script/DeployWatchdog.s.sol:110-118, 152, 159-163, 213-216

_validate rejects OWNER_SAFE == deployer, but it does not reject the deployer from AUDITORS or SCANNERS. The script even detects the scanner case only in _report and prints a warning rather than failing deployment.

Concrete failure scenario

The operator deploys from hot key D.

D is accidentally included in SCANNERS, AUDITORS, or both.

Deployment succeeds.

The timelock executes scanRegistry.acceptOwnership().

D is no longer owner, but remains an authorised scanner and/or current auditor indefinitely.

If D is later compromised, it can still append basic scan batches; if it is an auditor, it can also contribute signatures to deep/forensic reports. With a threshold of one, it can publish those reports alone.

The explicit property that the deploying key “keeps no role anywhere” therefore is not enforced by the deployment script.

Suggested fix

Reject the deployer anywhere in both arrays during _validate:

for (...) {
    if (cfg.auditors[i] == deployer) revert MustNotBeDeployer("AUDITORS");
}
for (...) {
    if (cfg.scanners[i] == deployer) revert MustNotBeDeployer("SCANNERS");
}

Also make the post-deployment verification explicitly assert that the deployer is neither owner, auditor, scanner, proposer, executor nor timelock admin.

F-02 — Lowering the threshold can create a valid quorum that has no path to finalisation

Severity: Medium

Location: src/KAY9AuditorRegistry.sol:158-162; src/KAY9AuditHub.sol:470-500

attest only tests the digest involved in the current call. Changing auditors.threshold() does not re-evaluate previously recorded positions, and an auditor who already voted cannot resubmit because of AlreadyAttested.

Concrete failure scenario

Current auditors are A, B, C; threshold is 3.

The job has an SLA longer than 48 hours.

A signs result X.

B signs the identical result X.

digestVotes[X] == 2; the job correctly remains Requested.

Through the timelock, governance changes the threshold from 3 to 2.

X now has the required two distinct current auditors, but nothing finalises it.

A and B cannot call attest again because both already have positions.

If C now signs a different result Y, attest only checks Y. _disputeIfUnreachable sees historical bestAgreement == 2, equal to the current threshold, and leaves the job Requested.

Every auditor has now voted and result X satisfies the current quorum, yet no callable path can publish it. The job eventually expires instead.

A valid current quorum can therefore exist without producing a registry entry.

Suggested fix

Add an explicit finalisation path for an already-recorded digest, for example finalizeExisting(jobId, result), which:

derives the digest from result;

calculates its current active holders;

reads the current threshold;

finalises if active holders meet it.

Alternatively, snapshot the threshold per job if threshold changes are not intended to affect existing jobs.

F-03 — Auditor rotation can make agreement impossible without triggering the promised dispute

Severity: Medium

Location: src/KAY9AuditHub.sol:688-707

Finalisation correctly filters removed auditors through _activeHolders, but _disputeIfUnreachable uses the unfiltered historical bestAgreement.

The source comments explicitly acknowledge part of this behaviour. It nevertheless contradicts the stronger stated property that the job becomes disputed when agreement is arithmetically impossible.

Concrete failure scenario

Use a long-SLA job and threshold 3.

Auditors start as A, B, C.

A and B both vote for X; bestAgreement == 2.

Governance adds D and E, then removes A and B, leaving current auditors C, D, E with threshold still 3.

The historical X position now has zero active holders.

C votes Y.

D votes Z.

E is the only silent current auditor.

No result can now reach three active votes:

Y can reach at most two;

Z can reach at most two;

X can reach at most one.

But _disputeIfUnreachable computes historical best == 2 plus silent == 1 and returns because 2 + 1 >= 3.

The job remains Requested even though quorum has become mathematically impossible. The requester keeps its quota unit consumed until another vote arrives or the SLA expires.

Suggested fix

Base the bound on the largest active position, not bestAgreement.

Because membership changes externally, the hub needs enough information to recompute this. A practical approach is to store the distinct digests seen for each job and compute the active holder count of each digest when deciding whether the job is unreachable.

F-04 — latestScan can contain a score that the batch Merkle root does not contain

Severity: Low

Location: src/KAY9ScanRegistry.sol:221-243, 250-299, 336-353

commitScanBatch takes the Merkle root and the on-chain summaries independently. No Merkle proof connects a supplied ScanSummary to the root before _latest is updated.

Concrete failure scenario

An authorised scanner builds a batch whose Merkle tree contains asset T with overallTrust = 20.

It supplies that root to commitScanBatch.

In summaries, it supplies the same asset with overallTrust = 90.

The transaction succeeds.

latestScan(T) returns 90 and points to that batch.

No leaf for that claimed score needs to exist in the batch.

This can arise from a scanner bug as well as malicious behaviour. It is not an authorization bypass—the scanner already controls the basic-scan commitment—but the one-call score is not cryptographically authenticated by the batch it references.

The comment at lines 238-243 says checking summaries would require rebuilding the tree. That is not necessary: each indexed summary can be accompanied by its own Merkle proof.

Suggested fix

For each indexed summary, provide the remaining leaf fields, including reportHash, plus a Merkle proof; compute scanLeaf and verify membership against root before writing _latest.

If that calldata/gas cost is intentionally rejected, document latestScan explicitly as an unverified index supplied by the scanner rather than a Merkle-authenticated projection of the batch.

F-05 — publishWatchdogReport is not permissionless

Severity: Low

Location: src/KAY9AuditHub.sol:262, 513-523, 587-592; script/DeployWatchdog.s.sol:172-175

The source documentation and deployment rationale describe publishWatchdogReport as permissionless. The implementation begins with:

_requireAuditorSubmitter();

and _requireAuditorSubmitter rejects every caller who is not a current auditor.

Concrete failure scenario

Auditors A and B produce enough valid signatures for a watchdog report.

Those signatures are supplied to an independent relay, keeper, or community member.

The relay calls publishWatchdogReport.

The transaction reverts with SubmitterNotAnAuditor.

Unless a current auditor itself submits the transaction, the already-complete quorum cannot be recorded.

Suggested fix

If permissionless relay is a required property, the submitter must not control unsigned permanent data. Either:

include a canonical reportURI in the signed digest;

derive the locator deterministically from signed content;

or remove the mutable locator from the quorum-authenticated record.

Then remove _requireAuditorSubmitter() from publishWatchdogReport.

If auditor-only submission is intentional, remove every claim that this function is permissionless.

F-06 — The 500-scan limit applies to summaries, not to the batch

Severity: Low

Location: src/KAY9ScanRegistry.sol:128, 250-268

The check is:

if (indexed_ > MAX_BATCH) revert BatchTooLarge(indexed_, MAX_BATCH);

where indexed_ == summaries.length.

There is no count > MAX_BATCH check.

Concrete failure scenario

An authorised scanner calls:

count = 50_000;

summaries.length = 100;

valid non-empty URI.

The call succeeds and records a batch claiming to hold 50,000 scans despite the stated property that a batch holds at most 500.

Suggested fix

If 500 is genuinely the batch bound:

if (count > MAX_BATCH) revert BatchTooLarge(count, MAX_BATCH);

The existing summaries bound can remain separately if needed.

If batches are deliberately allowed to contain more than 500 leaves, change the stated property and rename MAX_BATCH to something such as MAX_INDEXED_SUMMARIES.

F-07 — More than 255 auditors can permanently block a job at the 256th attestation

Severity: Low

Location: src/KAY9AuditorRegistry.sol:62-70; src/KAY9AuditHub.sol:479-483

The auditor set has no size ceiling, while Job.attestations and digestVotes are uint8.

The comment states that rejecting the 256th vote is harmless. It is not harmless in every reachable configuration.

Concrete failure scenario

Registry contains 300 auditors.

Threshold is 255, which is valid because the threshold itself is uint8.

254 auditors vote for digest X.

One auditor votes for Y.

job.attestations == 255, X has 254 votes, and quorum has not been reached.

There are still 45 silent auditors, so the job is not disputed.

A 256th auditor now signs X.

votes would reach the required 255, but job.attestations += 1 overflows uint8 and the entire transaction reverts.

Every subsequent attestation also fails at the same counter.

A quorum that is still reachable becomes impossible to record.

Suggested fix

Either cap the auditor set at 255, or widen Job.attestations, digestVotes, and bestAgreement to at least uint16. Widening is safer if future rotations are expected.

F-08 — A non-empty auditor set can legally have threshold zero

Severity: Low

Location: src/KAY9AuditorRegistry.sol:95-97, 103-116, 133-160

Removing the final auditor changes threshold to zero. Adding an auditor afterwards deliberately leaves it at zero until a separate setThreshold call occurs.

Concrete failure scenario

Governance removes the final compromised auditor.

Auditor count becomes zero and threshold becomes zero.

Later governance executes addAuditor(N).

Auditor count is now one while threshold remains zero.

publishWatchdogReport and requested-job finalisation remain halted until a separate threshold change executes.

This directly violates the stated invariant that whenever any auditor exists the threshold is within [1, auditorCount].

The behaviour is deliberately documented in the source, so this is an implementation/specification conflict rather than an accidental hidden branch.

Suggested fix

Either weaken property 8 to explicitly permit the half-recovered count > 0 && threshold == 0 state, or provide an atomic halted-state recovery operation that installs auditor(s) and a valid threshold together and disallow ordinary addAuditor while halted.

F-09 — The ArbSys block-number property is not enforced for scanner-supplied block numbers

Severity: Low

Location: src/KAY9ScanRegistry.sol:185-202, 214-216, 277, 289-296; lib/blocknumberish/src/BlockNumberish.sol:39-54

Contract-generated block fields correctly use _getBlockNumberish():

KAY9AuditHub.requestedBlock;

KAY9Registry.committedBlock;

KAY9ScanRegistry.committedBlock.

But ScanSummary.scannedAtBlock is arbitrary calldata. It is copied into AssetScanned and committed through scanLeaf without checking how it was obtained.

Concrete failure scenario

An authorised scanner accidentally uses Solidity/EVM block.number semantics or another incorrect block source when constructing a scan. It submits that value as scannedAtBlock. The contract accepts it and permanently commits/emits it.

Therefore the literal claim that every recorded block number is guaranteed to be the chain's ArbSys height is stronger than the contracts enforce.

Suggested fix

If scannedAtBlock is intentionally an auditor/scanner assertion, narrow property 10 to contract-generated block fields.

If it must be an on-chain guarantee for local Robinhood scans, redesign the interface so the relevant local block is derived or constrained on-chain rather than accepted as unchecked metadata.

F-10 — DeployWatchdog does not refuse deployment to the wrong chain

Severity: Low

Location: script/DeployWatchdog.s.sol:83-93

The script checks for the mainnet confirmation phrase only when block.chainid == 4663. Every other chain ID simply skips that check and proceeds to _deploy.

Concrete failure scenario

The operator has the wrong RPC selected—for example Ethereum or an unrelated EVM chain.

block.chainid != 4663.

No mainnet confirmation check executes.

The complete watchdog stack deploys successfully to the wrong chain.

The resulting registry/hub addresses may then be mistaken for the intended canonical deployment, and BlockNumberish may fall back to that chain's ordinary block.number.

Suggested fix

Explicitly allow only the intended deployment networks, e.g. Robinhood mainnet 4663 and testnet 46630, with an explicit rehearsal/testnet switch if both are needed.

Assessment of the ten claimed properties
#	Status	Assessment
1	broken	After acceptOwnership, the administrative setters are timelock-owned as intended, but the deployment configuration can leave the deploying key registered as a scanner or auditor. F-01 breaks the “keeps no role anywhere” part.
2	holds	Registry writes are restricted to the immutable hub. Requested-job signatures are recovered against one digest, each auditor can occupy one position, removed signers are filtered before finalisation, and watchdog signatures must be distinct current auditors through strict address ordering. EIP-712 binds the hub address and chain ID, while jobId binds requested reports to a job. reportURI is deliberately outside the digest, but reportHash and every score field are signed.
3	holds	KAY9Registry has no mutation/deletion path for an existing ReportRecord; every report is pushed. Asset history stores report IDs in commitment order, and latest/latestSummary/latestSnapshot read the final ID rather than merging reports.
4	broken	One-position-per-auditor and no averaging both hold. Immediate dispute when agreement becomes impossible does not hold after auditor-set rotation because bestAgreement contains removed votes. See F-03.
5	broken	Commit authorization and append-only batch storage hold. verifyScan performs normal sorted-pair Merkle verification for documented scanLeaf values. The stated 500-scan batch ceiling is not enforced; only the number of indexed summaries is capped. See F-06. Also, the on-chain latest summary is not proven against the root, as described in F-04.
6	holds as literally written	With a zero vault, requestAudit reverts; watchdog reports can still be published; setAccessVault is onlyOwner, rejects zero, validates tier constants and refuses a second binding. The separate scope-level claim that watchdog publication is permissionless does not hold; see F-05.
7	holds for the custom watchdog contracts and their protocol paths	No in-scope KAY9 watchdog contract charges a fee, exposes a token-transfer path, or moves requester principal. The hub only calls the vault's quota consume/restore interface. The token-holding behaviour of KAY9AccessVault itself was explicitly out of scope.
8	broken	The hub will not publish with fewer than the current non-zero threshold, and removals reduce an otherwise-invalid threshold safely. However, after the halted state, addAuditor can produce auditorCount > 0 with threshold == 0, contradicting the stated [1, auditorCount] invariant. See F-08. The unbounded auditor count also creates the F-07 liveness edge case.
9	could not conclude	On-chain, declaredRequesterKind is metadata only: it is stored/emitted and copied into ReportMeta; it cannot directly write or modify a score. Actual score computation is performed by the out-of-scope auditor/scanner software, so this review cannot establish that those services never inspect requester metadata, payment/access state or tier when calculating a score.
10	broken as literally stated	The three block numbers generated by these contracts themselves use _getBlockNumberish(), whose pinned implementation calls ArbSys when available. But ScanSummary.scannedAtBlock is supplied unchecked by the scanner, so not every recorded/committed block number is on-chain guaranteed to have come from ArbSys. F-09. The deployment script also does not enforce deployment to Robinhood Chain, F-10.
What I did not cover or could not verify

I did not review KAY9Genesis, KAY9Token, KAY9TeamVesting, KAY9LiquidityLock, the website, or the off-chain watchdog/auditor/scanner implementations.

KAY9AccessVault was considered only where necessary to understand the hub's tier checks and consume/restore calls. I did not re-audit its token custody or launch configuration.

I did not re-audit OpenZeppelin's Ownable2Step, ECDSA, EIP712, ReentrancyGuard or TimelockController internals. The review checks how KAY9 uses them. I did inspect the pinned BlockNumberish implementation because property 10 depends directly on its ArbSys-versus-block.number behaviour.

I did not verify a live deployed watchdog instance, deployed bytecode hashes, the current timelock roles, whether acceptOwnership() has actually executed, or whether the real production deploying key is absent from the auditor/scanner lists.

I did not verify the off-chain construction of Merkle batches, the claimed number of leaves behind a root, scan documents, content-addressed URIs, or that scanner software uses ArbSys-derived block heights. Those facts cannot be established from these contracts alone.

I did not run the Foundry test suite, fuzzing or invariant tests in this review. The findings above are source-level conclusions from the exact pinned commit.

Model

Model name: GPT-5.6 Sol
Version: GPT-5.6 Sol. No finer internal build or weights revision identifier is exposed to me.
