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
