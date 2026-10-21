# Review of the analysis-pin fix — OpenAI GPT-6, 21 Oct 2026

The OpenAI-family review for gate 6, in a new ChatGPT thread with no earlier context, through the
owner's ChatGPT account with GitHub access. The model menu's effort slider stood at "High"; the
"Pro" level was not offered at the time. It read `kay9T/kay9-protocol` at tag
`analysis-pin-review-1` (`fb6c21d6b1de4bdb26ecef95bdc228b415e09eac`) for the contracts,
`kay9T/kay9` at `c1e405836e69699c1751499cb0fb2bb2a76c3848` for the auditor service and the site,
and `kay9T/kay9` commit `a2f2308` (the Telegram `/scan` work of the same session) at lower
priority. The request it answered is reproduced below its reply. Dispositions are in
`2026-10-21-external-report.md`.

The reply is as received. It was copied out of the ChatGPT page as text, so its tables arrive with
one cell per line, and its first three lines are a rendering artefact of the page, kept as they
came.

## Round 1 reply

```text
solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
KAY9 Adversarial Review — Round 1 of 5

Session: kay9-e0
Date: 2026-10-21
Reviewer: OpenAI GPT-6
Review type: Independent, read-only model review; not a professional security audit.

1. Source verification

Repository

	

Pinned commit

	

Result




kay9T/kay9-protocol

	

fb6c21d6b1de4bdb26ecef95bdc228b415e09eac

	

Read




kay9T/kay9

	

c1e405836e69699c1751499cb0fb2bb2a76c3848

	

Read




kay9T/kay9 (social-bot scope)

	

a2f2308

	

Read

The Solidity source files in the public and private repositories have identical Git blob SHA values at their respective pinned commits:

KAY9AuditHub.sol: a1b24524e39cbb8e3107609c87250903fdd76cd0

KAY9Registry.sol: a8b5c43b3736357b367045ce78d7ed5ca999411d

The review used the actual pinned source, not the change report as evidence.

2. Findings

No confirmed critical or high-severity vulnerability was found in the two immutable Solidity contracts from source inspection. The following findings concern off-chain behaviour, test fidelity and the lower-priority social-bot implementation.

K9-E0-R1-01 — Telegram poll lock can expire while legitimate scans are still running

Severity: Medium (P2)
Repository: kay9T/kay9, commit a2f2308

Locations:

services/social-bot/src/telegram-scheduler.ts:33-41,104-107,178-182,235-250

services/social-bot/src/scan.ts:16-17,52-61,144-151

services/social-bot/src/lock.ts:48-76

Failure scenario

The Telegram poll holds a lock with a ten-minute stale threshold but never calls its refresh() method.

A basic scan has a 120-second timeout per engine invocation. For an EVM address without an explicit chain, scanResolved can invoke the engine twice: Robinhood Chain first, then BNB Chain if the first returns noCode.

Consider three legitimate /scan requests in one poll:

Three different senders submit valid EVM addresses.

Their first-chain scans return noCode slowly, and their second-chain scans also take substantial time.

Each request can occupy close to four minutes without either invocation exceeding its individual timeout.

The sequential poll remains active beyond ten minutes.

A subsequently scheduled poll sees the existing lock as stale and can acquire a replacement while the original poll is still processing.

Because the update cursor advances after each reply, the second poll can fetch updates the original process has not completed.

Both polls can then work on the same messages. Started work is counted against the reply budget, but that budget does not restore mutual exclusion.

Impact: Duplicate scans, duplicate public replies, unnecessary RPC/CPU consumption and two concurrent writers operating under different poll-lock tenures.

Suggested fix

Refresh the poll lock during long-running scans, or enforce a whole-poll deadline shorter than the stale threshold. Add a test using three slow, successful two-chain scans and a second poll attempting to acquire the lock after ten minutes.

This is in the separately requested social-bot scope, not a regression introduced by the analysis-pin contract fix.

K9-E0-R1-02 — Fake hub accepts watchdog publications the real hub rejects

Severity: Medium (P2), test-fidelity defect
Repository: kay9T/kay9, commit c1e405836e69699c1751499cb0fb2bb2a76c3848

Locations:

services/audit-worker/test/helpers/fake-hub.ts:396-405,458-472

services/audit-worker/src/watchdog-report.ts:152-184

Failure scenario

The fake hub's publishWatchdogReport simulation checks duplicate digests and signature count, but not the real contract's StaleWatchdogReport condition.

Example:

Asset A already has a watchdog report with analyzedAt = 200.

A worker still holds a quorum-signed monitoring result analyzed at 150, with a distinct digest.

The worker attempts to publish it.

The fake hub accepts the simulated transaction and appends the report.

The real KAY9AuditHub.publishWatchdogReport reverts because 150 <= 200.

The production contract correctly protects registry freshness. However, a worker test using the fake can report publication success for a transaction that production rejects.

The fake also does not fully model watchdog signer validation.

Impact: Worker tests can miss stale-publication rejection, retry behaviour and incorrect success accounting.

Suggested fix

Make the fake enforce the current maximum analyzedAt per asset, future-time validation and active sorted quorum signers.

Add a test that starts a monitoring analysis, inserts a newer watchdog result before its publication and verifies that the worker handles StaleWatchdogReport correctly.

This discrepancy also existed at the previous private-repository commit 839468c; it is not newly introduced by c1e4058.

K9-E0-R1-03 — Monitoring uses report-hash equality as record identity

Severity: Low (P3)
Repository: kay9T/kay9, commit c1e405836e69699c1751499cb0fb2bb2a76c3848

Location: services/audit-worker/src/monitor.ts:325-364,384-408

Failure scenario

The updated byAsset selection correctly chooses the greatest analyzedAt, breaking ties by commitment order. The subsequent test of whether the selected record is the registry's actual latest record still compares only reportHash.

Two distinct registry records can legitimately reference the same report body.

For example:

Two users request an analysis of the same asset and tier during the same Unix second.

Both jobs receive the same timestamp pin and can produce identical canonical report bytes.

The reports settle separately, receiving different report IDs but the same reportHash.

The records appear in different sweep windows.

Both windows pass the reportHash comparison against registry.latest().

The earlier page is therefore treated as containing the latest record even though its report ID is not the latest ID.

Impact: The same asset may be probed multiple times in a rotation, wasting bounded monitoring capacity. This does not establish that the wrong score becomes latest or that the asset is permanently skipped.

Suggested fix

Compare the actual report ID selected by the registry rather than using reportHash as a record identifier. The page's global report ID is derivable from fromOffset + index; the registry's selected ID can be read through latestSnapshot or another existing summary read.

Add a test placing two different record IDs with the same report hash on separate pages.

The hash-identity comparison predates this round. The analysis-time ordering change fixes the previously reported late-job skip but does not eliminate this older weakness.

K9-E0-R1-04 — Single-chain no-code result is presented as a two-chain conclusion

Severity: Low (P3)
Repository: kay9T/kay9, commit a2f2308

Locations:

services/social-bot/src/scan.ts:144-152

services/social-bot/src/mentions.ts:174-181

Failure scenario

When a scan request explicitly names a chain, scanResolved scans only that chain.

However, when summary.noCode is true, formatScanReply unconditionally claims that the address has no contract code on both Robinhood Chain and BNB Chain.

A user can request a scan explicitly on BNB Chain for an address that has no contract there but does contain a token on Robinhood Chain. The bot reports no contract code on either chain, even though it never checked Robinhood Chain.

Impact: The bot publishes an unsupported factual claim about the other chain.

Suggested fix

Report only the chain actually checked. Use the two-chain wording only when both EVM-chain checks were successfully completed and established that neither has contract code.

Add tests covering explicit Robinhood, explicit BNB and unspecified-chain requests.

3. Required property assessment

The statuses below distinguish source-level conclusions from behaviours requiring execution or deployment evidence.

#

	

Property

	

Status

	

Reason




1

	

Job results are pinned to requestedAt on every registry-writing path

	

holds

	

attest enforces equality at KAY9AuditHub.sol:493; finalizeAgreed can only finalize an existing attested digest. The registry accepts writes only from its bound hub.




2

	

Every latest* read selects maximum analyzedAt, later commit winning a tie

	

holds

	

_history[key].length == 1 handles the first record, including ID 0. The >= comparison updates _latestId correctly, and _latest checks history existence. Asset keys isolate interleaved histories.




3

	

Watchdog publication requires strict freshness against every recorded analysis

	

holds

	

publishWatchdogReport compares with latestAnalyzedAt. Because _latestId tracks the running maximum, a subsequently committed older job cannot reopen the watchdog freshness window.




4

	

No individual submitter, requester or auditor can independently select latest beyond quorum-signed data

	

holds

	

The EIP-712 digest binds analyzedAt, scores, flags, asset and report hash. A job's timestamp is additionally fixed by its request. reportURI remains unsigned and submitter-controlled, but cannot change record selection.




5

	

Launch deployment correctly wires the fresh registry, hub, governance and vault

	

could not conclude

	

Static constructor wiring and address validation are consistent. The exact Deploy.run() production branch was not executed, and governance must subsequently bind the vault to the hub.




6

	

Off-chain readers exactly match registry ordering, without incorrect latest handling or sweep skips

	

broken

	

The principal ordering fixes hold: byAsset selects by analysis time and useAssetHistory sorts by (analyzedAt, reportId). However, the sweep identifies whether a page contains the latest record using hash equality, which is insufficient when distinct records share a body hash (R1-03).




7

	

All earlier watchdog-review properties remain intact

	

could not conclude

	

The inspected quorum, replay, scoring and block-number paths retain their protections. No concrete regression was identified, but full preservation requires broader regression execution and historical-state verification.

Contract-specific checks

Job pinning and finalization

The pinned code enforces result.analyzedAt == job.requestedAt before storing any signature position. finalizeAgreed obtains holders from the digest already recorded by attest, and the digest binds the same analyzedAt.

Changing an unsigned reportURI cannot turn an unpinned result into a pinned digest. No alternate externally accessible job-finalization path was found.

Registry selection and zero values

The _latestId mapping does not confuse report ID zero with an absent asset because existence is derived from _history[key].length.

For an existing asset, the comparison against the selected record's analyzedAt correctly retains the maximum. An incoming record with analyzedAt == 0 is accepted as latest when it is the first record, but cannot displace a later analysis time. Equal timestamps select the later commit.

Watchdog freshness

The removal of _maxAnalyzedAt preserves the intended running-maximum value through _latestId. The watchdog's strict comparison therefore continues to reject stale signed results even when a late requested-job report was appended more recently.

Signature authority and result neutrality

The hub checks the submitting auditor's membership. Job attestations verify recovered active signers and prevent duplicate positions. Watchdog publication requires a sorted active quorum. The digest includes the job ID or zero for watchdog reports, and EIP-712 binds chain ID and deployment address.

Requester-declared metadata is not used to calculate a score. The result is settled from an agreed digest rather than averaging contradictory scores. Block-number reads in the inspected contracts continue through BlockNumberish.

These are source-level observations, not claims that the entire cryptographic or operational implementation is safe.

4. Regression comparison with watchdog-review-4

No new Solidity defect attributable to the analysis-pin fix was confirmed.

The changes in ed0d375 and fb6c21d address the two reported contract-level defects:

The hub now rejects results whose signed analysis timestamp differs from the request timestamp.

The registry now selects the most recent analysis rather than the most recent commitment.

The corresponding private-repository changes also correct the previously identified ordering mismatch in monitor.ts and the asset-history UI.

R1-02 and R1-03 identify weaknesses already present in the earlier worker implementation; neither establishes a newly introduced mainnet-contract vulnerability.

The two social-bot findings concern the separate commit a2f2308. Their relationship to the September watchdog review baseline was not established.

The new hub-and-registry deployment path remains an operational dependency until the post-deployment checklist and testnet rehearsal have produced evidence.

5. Test and launch-readiness assessment

The following test cases were inspected in the pinned repository:

KAY9AuditHub.t.sol: request-time equality rejection, same-second tie behaviour and watchdog freshness after a late job.

KAY9Registry.t.sol: older analysis committed later, newer/equal analysis selection and fuzzed interleaving across two assets.

DeployWatchdog.t.sol: rejection of the superseded mainnet addresses.

monitor.test.ts: the late-job monitoring case and bounded sweep behaviour.

fake-hub.ts: the test implementations of job attestation and watchdog publication.

The tests target the main reported defects appropriately, but reading their assertions is not evidence they pass. The fuzz test covers interleaved assets and repeated analysis times; it is not a proof over all possible execution histories.

The deployment's static address graph is consistent with the proposed plan:

The existing timelock is reused.

The existing auditor registry is reused and validated.

A fresh report registry and hub are constructed.

The hub is initialized with the existing timelock as owner and the existing auditors.

The fresh vault is pointed at that hub.

The hub's own access-vault pointer remains unset until the separately documented governance operation.

The supplied old mainnet hub and registry addresses are explicitly rejected when passed into _validateExistingAuditProtocol.

Gate 13 now documents the exceptional November 2026 launch, and the deployment runbook includes off-chain address changes for the website and auditor services. These documents describe planned actions; they do not prove those actions have occurred.

6. What was not verified

This review did not execute Forge tests, invariant campaigns, Slither, a fork test, a full TypeScript test suite or an end-to-end deployment. The runtime did not have Forge available.

It also did not independently verify the 21 October mainnet reportCount, jobCount and vault-state readings, the live Uniswap-dependent deployment branch, or the real testnet rehearsal at the new contract bytecode.

The complete watchdog engine and every historical finding from the previous review were not re-audited. The lower-priority social-bot review focused on the named scan, scheduling, drafting and associated safety paths rather than every bot subsystem. Real Telegram/X API behaviour and live infrastructure timeouts were not exercised.

No claim is made that every possible attack path has been excluded.

Questions for the next round

Can the session add a real-contract or faithful-fake test for stale watchdog publication during a worker race, showing the worker's actual outcome after StaleWatchdogReport?

Can it add a monitor regression test with two distinct report IDs sharing one reportHash across page boundaries, asserting that only the registry-selected record's page probes the asset?

Can the session supply the Forge and testnet-rehearsal results for the exact launch configuration using only EXISTING_TIMELOCK and EXISTING_AUDITOR_REGISTRY, including the resulting address graph and vault-binding operation?

7. Model identification and review limitations

Model: OpenAI GPT-6
Version: GPT-6; no more specific build identifier is available to this reviewer.

This is a model-generated, adversarial source-code review prepared for engineering verification. Every finding is a proposal for the session to reproduce, confirm or reject against the actual repository. It is neither an instruction to change code nor a pre-approval or release authorization.

Round 1 conclusion: The analysis-pin and registry-latest changes appear internally consistent under static inspection. The confirmed concerns are limited to off-chain operation, test fidelity and the separately scoped social bot. The immutable contracts' full launch behaviour remains unverified until the required execution and deployment evidence is available.
```

## Round 1 request

> # Round 1 of 5 — KAY9 analysis-pin fix (KAY9AuditHub, KAY9Registry) and the off-chain readers
> 
> This round doubles as the **OpenAI-family model review required by gate 6** of
> `docs/LAUNCH_READINESS.md` for two immutable contracts. Your reply will be published verbatim in
> `docs/reviews/`. It is a model review, not a professional audit; KAY9 is never called "audited" or
> "verified safe" because of it.
> 
> ## What to read, exactly
> 
> **Contracts (public):** `https://github.com/kay9T/kay9-protocol`, tag `analysis-pin-review-1` =
> commit `fb6c21d6b1de4bdb26ecef95bdc228b415e09eac`, branch `main`. Before anything else, quote the
> first two lines of `src/KAY9AuditHub.sol` at that commit. If you cannot read it, say so and stop.
> 
> Changed since the last reviewed tag `watchdog-review-4` (only these two commits touch the hub and
> the registry: `ed0d375`, `fb6c21d`):
> 
> - `src/KAY9AuditHub.sol` — `attest` (around line 485–495) now reverts
>   `AnalysisNotPinned(analyzedAt, requestedAt)` unless `result.analyzedAt == job.requestedAt`.
>   `finalizeAgreed` has no own check (it only settles positions `attest` recorded; the EIP-712
>   digest covers `analyzedAt`).
> - `src/KAY9Registry.sol` — `recordReport` keeps per asset `_latestId`, moved when
>   `ids.length == 1 || result.analyzedAt >= _reports[_latestId[key]].result.analyzedAt`.
>   `latest`, `latestSummary`, `latestSnapshot`, `latestSummaryForToken` and `latestAnalyzedAt` all
>   read it through `_latest`. `_maxAnalyzedAt` is gone; `latestAnalyzedAt` is now the latest
>   record's own `analyzedAt`.
> - `script/Deploy.s.sol` — refuses the superseded 25 Sep mainnet hub and registry by address in
>   `_validateExistingAuditProtocol`.
> - Tests: `test/unit/KAY9AuditHub.t.sol` (`test_aJobResultMustBeAnalysedAtItsRequestTime`,
>   `test_aTieInAnalysisTimeGoesToTheLaterCommit`, `_resultFor`),
>   `test/unit/KAY9Registry.t.sol` (`test_anOlderLookCommittedLaterIsNotLatest`,
>   `test_aNewerOrEqualLookBecomesLatest`, `testFuzz_latestIsTheNewestAnalysisPerAsset`),
>   `test/unit/DeployWatchdog.t.sol` (`test_launchRefusesTheSupersededPair`).
> - Background and dispositions: `docs/reviews/2026-10-21-external-report.md` and the earlier
>   fresh-context review `docs/reviews/2026-10-21-report-fix-anthropic-claude-opus-5.5.md`.
>   The binding spec is `docs/CONTRACT_INTERFACES.md` (registry section around line 500–530, hub
>   "Attestation and quorum" around line 690–715).
> 
> **Off-chain readers (private, you have access):** `https://github.com/kay9T/kay9`, branch `main`,
> commit `c1e405836e69699c1751499cb0fb2bb2a76c3848`, range `839468c..c1e4058`. Read first:
> `services/audit-worker/src/monitor.ts` (the `byAsset` choice, around line 325–360, and the
> `latest` comparison right after), `services/audit-worker/test/helpers/fake-hub.ts`,
> `services/audit-worker/test/monitor.test.ts` (the "late job record" test),
> `apps/web/src/hooks/useRegistry.ts` (`useAssetHistory` sort),
> `apps/web/src/components/registry/AssetHistory.tsx`, `docs/DEPLOYMENT.md` (the "Except at the
> November 2026 launch" section and its post-deploy list), `docs/LAUNCH_READINESS.md` gate 13.
> 
> **Lower priority, same session:** `kay9T/kay9` commit `a2f2308` — the Telegram group `/scan`
> command and X reply drafts that carry a basic scan (`services/social-bot/src/scan.ts`,
> `telegram-scheduler.ts`, `hype.ts`, `Dockerfile`). Strangers' text reaches it; look at budget,
> injection and the protocol's wording rules ("KAY9 Technical Risk", never "safe").
> 
> ## Why the change exists
> 
> An external report (21 Oct 2026) said: (1) nothing on-chain bound a job result's `analyzedAt` to
> the job's `requestedAt` — the pin was only enforced in `services/audit-worker/src/analysis.ts`;
> (2) a job record analysed at `requestedAt` but committed after a newer watchdog report became
> `latest`, and `latestSummary` (the one-call read for wallets and badges) carries no `analyzedAt`
> to warn its reader. Both were confirmed.
> 
> Settled premises — challenge them only with a concrete failure scenario:
> 
> - **Equality, not `>=`.** Every auditor pins a job to `requestedAt` so independent runs agree;
>   `docs/AUDIT_PROTOCOL.md` already defined a job's `analyzedAt` as its `requestedAt`.
> - **The reporter's fix (refuse a job result older than the asset's latest record) was not
>   taken:** it fails an honest job whenever the watchdog reports between request and quorum, and
>   sends the requester's quota back for work the auditors did.
> - **No redeploy now.** The 25 Sep mainnet hub `0x3d5Dac2bd018ba499c83E44da485C5E6ec5136dA` and
>   registry `0x3bD24351532274b7ea026d408Ba6bFB0922f5068` hold no report and no job and have no
>   vault (read 21 Oct). The token launch runs `Deploy.s.sol` with `EXISTING_TIMELOCK` and
>   `EXISTING_AUDITOR_REGISTRY` only, which deploys a fresh registry-and-hub pair.
> - **Not taken from the earlier review:** a `Deploy.run()` end-to-end test (needs the live Uniswap
>   stack; the testnet rehearsal covers it), passing the vault into the fresh hub's constructor
>   (keeps the existing launch flow and its `setAccessVault` proposal), and adding `analyzedAt` to
>   `scoreHistory` / `ReportRecorded` (`getReport` exposes it; the event signature stays).
> 
> ## The properties to try hardest to break
> 
> 1. A job result reaches `KAY9Registry` only with `analyzedAt == job.requestedAt`, through
>    `attest` or `finalizeAgreed`, and through no other path.
> 2. For every asset, every `latest*` read returns the record with the largest `analyzedAt`, a tie
>    going to the later commit; this holds for report id 0, the first record, and assets that
>    interleave. History stays append-only and in commitment order.
> 3. `publishWatchdogReport` still refuses a report whose `analyzedAt` is not strictly newer than
>    every record the asset has, including after a job result analysed earlier lands in between.
> 4. Nothing in the change lets a single auditor, the submitter, or a requester choose which record
>    becomes `latest` beyond what a quorum signed. (Think about `analyzedAt` values a quorum can sign
>    for a watchdog report versus a job, ties within one second at ~10 blocks/s, and
>    `analyzedAt == 0`.)
> 5. `Deploy.s.sol` at launch, with only `EXISTING_TIMELOCK` + `EXISTING_AUDITOR_REGISTRY`, wires a
>    correct fresh pair (hub owned by the existing timelock, bound to the existing auditor registry,
>    registry bound to the hub, vault pointed at the hub), and refuses either superseded address.
> 6. The off-chain readers (monitor sweep, asset page) order records exactly as the registry does,
>    so no asset is skipped by the sweep and the page never shows an older look as "Latest report".
> 7. Everything the earlier watchdog review established still holds: quorum of distinct current
>    auditors, no replay across chain/deployment/job, contradictory results never averaged, nobody
>    pays, nothing a requester declares changes a score, block numbers via ArbSys.
> 
> ## What your markdown must contain
> 
> - Findings, most severe first: title, severity, file:line at the pinned commit, a concrete failure
>   scenario (who does what, in which order, what is lost or wrongly allowed), and a suggested fix.
> - A table of properties 1–7 as **holds / broken / could not conclude**, with the reason.
> - Whether the change introduced any defect that was not there at `watchdog-review-4`.
> - What you did not cover or could not verify.
> - Your model name and version, as exactly as you know them.
> 
> Do not soften a finding and do not invent one. Everything you write is a proposal the session
> verifies against the repository. This is round 1 of 5.

## Round 2 reply

This round came back as a downloaded markdown file, reproduced unchanged.

> # KAY9 — Adversarial Review, Round 2 of 5
> 
> **Date:** 22 October 2026  
> **Reviewer:** OpenAI GPT-6 (no more specific model build/version exposed)  
> **Type:** Independent, read-only model review; **not** a professional security audit or launch authorization.  
> **Private repository:** [`kay9T/kay9` @ `2071c6c2f88abb9fc0abc41e23b17aeb62d5c432`](https://github.com/kay9T/kay9/commit/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432) (`c1e4058..2071c6c`, one commit).  
> **Public protocol:** [`kay9T/kay9-protocol` @ `71f6713c32f53d2566872c1fcef4a07e3dc06272`](https://github.com/kay9T/kay9-protocol/commit/71f6713c32f53d2566872c1fcef4a07e3dc06272) (one commit after `fb6c21d6`).
> 
> ## 1. Immutable-source verification and overall verdict
> 
> GitHub's compare results show **no changes to `src/KAY9AuditHub.sol` or `src/KAY9Registry.sol`** in `fb6c21d6..71f6713c`; that public commit changes `script/Rehearse.s.sol`, the testnet deployment manifest and review/readiness documentation. I also independently compared Git blob IDs at the two revisions:
> 
> | File | Blob SHA at **both** public commits |
> |---|---|
> | `src/KAY9AuditHub.sol` | `a1b24524e39cbb8e3107609c87250903fdd76cd0` |
> | `src/KAY9Registry.sol` | `a8b5c43b3736357b367045ce78d7ed5ca999411d` |
> | `script/Deploy.s.sol` | `c75d0ea2400d56f6ca40cf97b7786027029c867f` |
> 
> The private repository's one-commit diff changes the monitoring worker, its fake and tests, the social-bot scan/Telegram code and tests, and documentation/rehearsal artifacts. **There is no confirmed new defect in the two immutable contracts in this round.** The primary record-selection and scan-output fixes close their original scenarios. The Telegram lease issue is **narrowed, not fully closed**; two lower-severity issues concerning test realism and a related cashtag response are also described below.
> 
> ## 2. Findings, most severe first
> 
> ### K9-E0-R2-01 — An unbounded X callback can outlive the Telegram poll lease; a stolen lease is not detected
> 
> **Severity:** Medium (P2), residual part of R1-01.  
> **Pinned locations:** [`services/social-bot/src/telegram-scheduler.ts:178-210,235-252`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/src/telegram-scheduler.ts#L178-L252), [`services/social-bot/src/x-client.ts:68-75,107-114`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/src/x-client.ts#L68-L114), [`services/social-bot/src/lock.ts:62-66`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/src/lock.ts#L62-L66), [`services/social-bot/src/hype.ts:287-331`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/src/hype.ts#L287-L331).
> 
> **Concrete scenario.** A poll acquires the 10-minute-stale lock and receives an owner's X draft-approval callback followed by a `/scan` message. Callback handling is processed *before* the new `release.refresh()` point. `handleHypeCallback` removes the pending draft, then awaits `replyToTweet`; the underlying `signedRequest` calls `fetch()` **without any `AbortSignal` or timeout**. If that request hangs for over ten minutes, a second scheduled poll can reclaim the stale lock and process the same fetched batch, including the `/scan`. When the first X request finally returns, the original poll still iterates its locally fetched updates and can also scan and reply to that message. Its next `release.refresh()` silently does nothing if another holder owns the file; it neither throws nor stops work. The shared cursor and answer-budget state do not fence the already-fetched work of the first poll. The second callback will generally find its draft already removed, so **duplicate X publication is not the established consequence**; duplicated scans/replies and overlapping poll processing are.
> 
> The new test in [`telegram-poll.test.ts`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/test/telegram-poll.test.ts) backdates a lock during one scan and proves it is refreshed before the next one; it does **not** exercise callback handling, a genuinely stolen lease, or a stalled outbound X call.
> 
> **Suggested fix.** Enforce an actual deadline on `signedRequest`/X posting and refresh or heartbeat the poll lock during potentially lengthy callbacks. Have a refresh/lease-check report lost ownership rather than silently succeeding, and fence remaining message processing when ownership is lost. Regression test: block a callback's X request past lock expiry, start another poll and confirm the original cannot process a later `/scan` after the takeover. This is a still-existing gap in the original global poll-lock concern; it does not establish a new Solidity regression.
> 
> ### K9-E0-R2-02 — Updated monitor fixtures disagree with their pinned canonical report timestamps
> 
> **Severity:** Low (P3), newly introduced test-fidelity defect.  
> **Pinned locations:** [`services/audit-worker/test/monitor.test.ts:78-113`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/audit-worker/test/monitor.test.ts#L78-L113), [`services/audit-worker/test/helpers/fake-engine.ts:50-95`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/audit-worker/test/helpers/fake-engine.ts#L50-L95).
> 
> **Concrete scenario.** `seedReport` asks the fake engine to produce a canonical body with `options.now = 1_780_000_000` and pins the resulting JSON and hash. It then overwrites **only** the registry-facing `result.analyzedAt` with `1_779_913_600` by default (or another supplied value). The fake engine's canonical report still contains `analyzedAt = 1_780_000_000`. A test can therefore treat the record as an honest earlier analysis while the content-addressed body names a different time. This discrepancy would not pass the honest worker's normal `runPinnedAnalysis` consistency/pinning expectations; the Solidity registry itself does not validate off-chain canonical-body equality. In particular, the newly expanded monitoring tests can pass while never exercising a baseline whose on-chain analysis time matches its actual report body.
> 
> **Suggested fix.** Pass `options.analyzedAt ?? 1_779_913_600n` as the fake engine's `options.now` *before* creating the canonical JSON/hash, and use the engine-produced result without post-hash timestamp mutation. For tests intentionally constructing inconsistent or adversarial metadata, name that fixture explicitly. Assert parsed canonical-body `analyzedAt` equals the seeded `result.analyzedAt` for normal monitoring fixtures.
> 
> This finding does **not** invalidate the new fake hub's on-chain freshness comparison or show that it incorrectly accepts a stale result; it limits how realistic the surrounding tests are.
> 
> ### K9-E0-R2-03 — Chain-specific cashtag miss is reported as absence on every supported chain
> 
> **Severity:** Low (P3), pre-existing and newly noticed in this round.  
> **Pinned locations:** [`services/social-bot/src/scan.ts:123-135,154-162`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/src/scan.ts#L123-L162), [`services/social-bot/src/mentions.ts:93-106`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/services/social-bot/src/mentions.ts#L93-L106).
> 
> **Concrete scenario.** A user sends `/scan $ABC on solana`. `pickCashtagToken` filters GeckoTerminal results to the explicitly requested chain. Suppose the search yields a matching BNB token but no Solana match. `resolveToken` returns `{ missing: 'ABC' }`; `scanReply` announces that KAY9 found no `$ABC` pool on **Robinhood Chain, BNB Chain or Solana**. That is false about BNB and was not established by the Solana-specific filter. An external search failure also returns an empty result and receives the same definitive absence wording.
> 
> **Suggested fix.** On a miss, name only the requested chain, or say that no matching pool **could be resolved** for the requested chain rather than asserting universal absence. Distinguish API failure from a successful empty search if feasible. Add cashtag tests for explicitly selected Solana/BNB with a match on another chain and for search failures.
> 
> This is **not** a regression from `2071c6c` and does not undo R1-04's correction of the separate `noCode` message.
> 
> ## 3. Disposition of the four round-1 findings
> 
> | Round-1 ID | Status | Verification |
> |---|---|---|
> | **R1-01 — poll lease expires during sequential work** | **narrowed** | `await release.refresh()` before each scan/AI answer protects normal sequential scans under their per-operation bounds. The new test checks renewed mtime between scans. Callback approvals still bypass refresh and include an X `fetch` without a deadline; refresh also fails to signal lost ownership (R2-01). |
> | **R1-02 — fake accepts stale/future watchdog report** | **closed for the reported stale/future checks** | `fake-hub.ts` now compares against the maximum per-asset `analyzedAt` and rejects future timestamps. `monitor.test.ts` asserts zero broadcasts/publications and a skipped/unfinished asset after a stale rejection. The fake remains simplified (e.g. it does not fully reproduce watchdog signer validation), and normal seeded report-body timestamps are now inconsistent (R2-02). |
> | **R1-03 — same hash, different registry IDs** | **closed** | `reportId = BigInt(fromOffset + index)` and `latestSummary`'s returned ID are compared directly, not by hash. The two-page identical-hash regression test exercises both pages. A partial `getReports` page advances by `records.length`, so it does not shift later IDs; the next pass starts at the actual next record. At end-of-log, the cursor wraps only after `advanced >= reportCount`. A zero-length response while count is positive would stall, not skip, the cursor; no new bug in the ID calculation was identified. |
> | **R1-04 — no-code wording overclaims checked chains** | **closed** | `scanResolved` records the actual successfully returned chain reads. Explicit EVM and Solana chain requests, cashtags resolved to a chain, and fallback Robinhood → BNB follow the same list rule. Tests cover explicit BNB and both EVM chains. A separate no-pool-on-all-chains claim remains in the unresolved-cashtag branch (R2-03). |
> 
> ## 4. Updated assessment of properties 1–7
> 
> | # | Property | Status | Reason |
> |---|---|---|---|
> | **1** | Job result reaches registry only pinned to job request time | **holds** | Immutable hub and registry blobs match round 1. `attest` enforces equality; `finalizeAgreed` uses recorded signed positions and cannot bypass it. |
> | **2** | Per-asset `latest*` chooses maximum analysis time, tie to later commitment; append-only history | **holds** | Contract code unchanged; `_latestId` and the existing property/fuzz tests handle ID zero and interleaved assets. Rehearsal documentation records a late job that did not displace a fresher watchdog. |
> | **3** | Watchdog always requires strictly greater `analyzedAt` | **holds** | Contract unchanged; `latestAnalyzedAt` is drawn from the maximal-analysis record. The fake now reflects the relevant time comparison. |
> | **4** | Single auditor/submitter/requester cannot choose latest outside quorum-approved values | **holds** | EIP-712 result digest and quorum pathways unchanged, and job result analysis time remains pinned. Ties use signed timestamps plus deterministic commitment order. |
> | **5** | **Exact `Deploy.s.sol` mainnet launch shape** correctly wires reused timelock/auditors, fresh hub/registry, vault | **could not conclude** | Static source shows the correct predicted registry↔hub binding, timelock owner and reused auditors; the superseded pair is rejected. The testnet rehearsal tests a *different* script and constructs the hub with a bound vault, whereas `Deploy.s.sol` constructs it with **zero vault** and relies on a subsequent **timelock `setAccessVault`** action. It also does not exercise the mainnet Genesis/Uniswap launch branch. This is still unexecuted for the exact production shape. |
> | **6** | Monitor and asset UI use the registry's same record ordering; no permanent skipped asset | **holds** | Monitor chooses page maximum `analyzedAt` (ties by later index), compares actual registry report IDs and preserves the cursor on unfinished publication; UI sorts by `(analyzedAt desc, reportId desc)`. The identical-hash two-page case now selects only the correct page. This is a source-level ordering conclusion, not a proof of liveness under arbitrary RPC failures or continuous writes. |
> | **7** | Earlier watchdog-review properties remain intact in the full system | **could not conclude** | The immutable contract source and inspected quorum/replay/neutrality/ArbSys paths remain unchanged, and CI supplies strong passing regression evidence. A complete proof across all live deployments, environmental configuration and future auditor-set transitions is beyond the executed evidence. No new contradiction was identified. |
> 
> ## 5. Forge, CI and testnet evidence
> 
> **CI independently inspected.** GitHub Actions **CI run [`39599065994`](https://github.com/kay9T/kay9/actions/runs/39599065994)** is marked successful on private commit `c1e405836e69699c1751499cb0fb2bb2a76c3848`. Its **Contracts** job (`119218725925`) log includes the exact line **“Ran 24 test suites … 358 tests passed, 0 failed, 0 skipped”**. The package/services/site job also passed. This confirms the stated **358-test CI result at `c1e4058`**, not execution of the production launch or a guarantee for every changed file at `2071c6c`. When checked during this review, the new commit's CI run [`39613485725`](https://github.com/kay9T/kay9/actions/runs/39613485725) was **in progress**, so this review does not label it green.
> 
> **Testnet evidence inspected in the repository.** [`docs/STATUS.md` §19 at `2071c6c`](https://github.com/kay9T/kay9/blob/2071c6c2f88abb9fc0abc41e23b17aeb62d5c432/docs/STATUS.md) records the rehearsal on Robinhood testnet chain **46630**, deploying:
> 
> - Vault: `0xF5cf0D803d2aAE907013601F81D30b2649aB48aE`
> - Registry: `0x0AE753d8384E2F50737c5173758CA7063A1d3161`
> - Hub: `0xcFaA0aC0e289da555c45cAb68354bC01812b5AC0`
> 
> The recorded sequence covers an unpinned A+B-signed job result **simulated** to revert `AnalysisNotPinned(1792587356,1792587355)`; a watchdog report 0 with `analyzedAt=1792587392`; then a fulfilled job report 1 committed later but analyzed at `1792587355`; all `latest*` reads choosing report 0; three separate pinned dissents disputing another job and restoring quota; and a separate expiration restoring quota. [`script/Rehearse.s.sol`](https://github.com/kay9T/kay9-protocol/blob/71f6713c32f53d2566872c1fcef4a07e3dc06272/script/Rehearse.s.sol) contains dedicated `pinCheck`, `watchdogReport`, `latestOrder` and pinned-job-result paths consistent with the recorded steps. The updated `deployments/46630.json` names the same addresses.
> 
> **Evidence limit:** I inspected the committed rehearsal code, record, selected transaction identifiers and manifest, but did **not** independently retrieve testnet transaction receipts, bytecode or storage from the supplied RPC: direct RPC access was unavailable in this environment. The file prints transaction hashes in abbreviated form, rather than enough bytes to submit a receipt query directly from the report. Consequently I can confirm the *documented* testnet sequence and that its script exercises the intended paths, **not** independently attest that the listed receipts and contract state match chain 46630.
> 
> The testnet stack also differs from production in two material respects: `Rehearse.deployAuditStack` bypasses `Deploy.run()` and constructs the hub with an already bound vault; it uses a 60-second timelock rather than the production timelock and does not reproduce the full new token/Uniswap launch flow. Its result is useful **gate-8 workflow evidence**, but does **not** close the exact-shape portion of property 5 or substitute for the separately required launch checks.
> 
> ## 6. Regressions and coverage limitations
> 
> **Newly introduced by `2071c6c`:** R2-02 is a test-fixture consistency defect. No regression in the immutable Solidity contracts was found; Git blobs are identical. The hash-to-ID change itself is correct for the stated paging boundary and tie cases. The new `checked` metadata correctly lists actually read chains; R2-03 is older, separate missing-pool wording. The Telegram refresh helps normal scans, but R2-01 is the remaining previously exposed lease failure, not a newly created vulnerability.
> 
> I did **not** run Forge or local TypeScript tests myself, execute the exact mainnet `Deploy.run` branch, independently query the rehearsal's on-chain state, exercise the real X/Telegram APIs, or reproduce the callback takeover with a deliberately stalled HTTP connection. I verified prior CI logs and read source/test implementations at the pinned commits. Claims concerning live deployment, future schedules or full preservation of all historical safety properties should not be upgraded to proven merely from this model review.
> 
> ## 7. Suggested verification for round 3
> 
> 1. Reproduce R2-01 with a pending X-approval callback and a stalled `replyToTweet` call; after lock takeover, verify that the old poll cannot send or process later scan updates.
> 2. Repair R2-02 so that an ordinary seeded report's on-chain `analyzedAt` and the timestamp inside its canonical pinned body agree, and retain the stale-publication and late-job regression assertions.
> 3. Test the unresolved *chain-specific cashtag* path in R2-03, including a pool on a different chain and an API search failure. If deferred, ensure copy does not overstate what was checked.
> 4. Preserve an explicit launch-time check for `hub.accessVault()`: it remains zero after the fresh production constructor until the timelock executes `setAccessVault`; ensure the configured new hub, registry and all auditor deployments agree afterward.
> 
> **Round-2 conclusion:** The core Solidity analysis-pin and registry selection changes remain unchanged and source-consistent. R1-02, R1-03 and R1-04 close their original scenarios; R1-01 is narrowed by the new refresh but is not closed for callback-driven lease loss. The available CI and recorded testnet rehearsal substantially improve evidence for the tested paths without proving the precise future mainnet launch configuration. This is a model review, **not** an audit, a statement that KAY9 or a token is safe, or authorization to launch.

## Round 2 request

> # Round 2 of 5 — verification of the round-1 fixes, and the testnet evidence
> 
> ## What to read
> 
> - `https://github.com/kay9T/kay9`, branch `main`, commit `2071c6c2f88abb9fc0abc41e23b17aeb62d5c432`,
>   range `c1e4058..2071c6c` (one commit).
> - `https://github.com/kay9T/kay9-protocol`, branch `main`, commit
>   `71f6713c32f53d2566872c1fcef4a07e3dc06272`. **The two contracts are unchanged since tag
>   `analysis-pin-review-1`** (`fb6c21d6`); only `script/Rehearse.s.sol`, `deployments/46630.json`
>   and docs changed. Please confirm that from the diff rather than from this sentence.
> 
> ## How each round-1 finding was handled (all accepted, all fixed in `2071c6c`)
> 
> - **R1-01** — `services/social-bot/src/telegram-scheduler.ts`: `await release.refresh()` before each
>   scan or answer, after the budget is spent. Test `keeps the poll lock fresh across slow scans, so
>   a later poll cannot take it over` in `test/telegram-poll.test.ts` (it backdates the lock inside
>   the first scan and checks the second scan starts with a fresh one).
> - **R1-02** — `services/audit-worker/test/helpers/fake-hub.ts`: the fake `publishWatchdogReport`
>   now refuses `AnalyzedInFuture` and `StaleWatchdogReport` against the asset's latest record
>   (same rule as the registry). Seeded records in `test/monitor.test.ts` default to an
>   `analyzedAt` one day before the fake chain's blocks, since every real record is older than the
>   block a sweep re-analyses at. New test `does not count a report the hub refuses as stale as
>   published, and holds the asset`. The worker's actual outcome after the revert: not counted as
>   published, the asset reported in `skipped` with the revert, and held in `unfinished`, so the
>   rotation stays on it and the next sweep re-analyses at a later epoch block.
> - **R1-03** — `services/audit-worker/src/monitor.ts`: each window record gets its registry id
>   (`fromOffset + index`); `latestRecord`/`latest` is replaced by `latestReportId`, which reads
>   `latestSummary` (one read per asset instead of one) and the asset is probed only when that id is
>   the page record's id; the probed asset is built from the page record. New test `probes only
>   from the page of the registry-selected record when two records share one report hash`, which
>   fails on the previous code.
> - **R1-04** — `services/social-bot/src/scan.ts` `scanResolved` returns `checked` (every chain
>   read, in order); `formatScanReply` names only those in the no-code sentence. Tests in
>   `test/mentions.test.ts`.
> 
> ## Your three questions
> 
> 1. Stale publication during a worker race: R1-02 above.
> 2. Two report ids with one hash across pages: R1-03 above.
> 3. Forge and testnet evidence: Forge 358 tests pass locally and in CI on `c1e4058` (the contracts
>    job, which runs on contract changes). The testnet rehearsal is recorded in `docs/STATUS.md` §19
>    of `kay9T/kay9` with every transaction hash, on chain 46630: a fresh vault
>    `0xF5cf0D803d2aAE907013601F81D30b2649aB48aE`, registry `0x0AE753d8384E2F50737c5173758CA7063A1d3161`
>    and hub `0xcFaA0aC0e289da555c45cAb68354bC01812b5AC0`, deployed by `Rehearse.s.sol`
>    `deployAuditStack` next to the existing testnet token, auditor registry (3 auditors, threshold
>    2) and a 60-second timelock. Observed: an unpinned A+B-signed result reverted
>    `AnalysisNotPinned(1792587356, 1792587355)` (simulated); watchdog report 0 analysed at
>    1792587392, then job 1's record (analysed 1792587355) committed after it as report 1, and
>    `latestSummary`/`latestSnapshot`/`latest`/`latestAnalyzedAt` all name report 0; job 2 disputed
>    by three pinned dissents with its unit returned; job 3 expired with its unit returned. You can
>    read all of this on the chain yourself if your tools reach it (RPC
>    `https://rpc.testnet.chain.robinhood.com`). It is **not** the launch configuration:
>    `Deploy.s.sol` with only `EXISTING_TIMELOCK` + `EXISTING_AUDITOR_REGISTRY` needs a launched
>    token and the Uniswap stack; the rehearsal deploys the same three contracts with the same
>    wiring, except that the hub is constructed with the vault rather than bound later by
>    `setAccessVault`.
> 
> ## What to do this round
> 
> - Verify each fix at the pinned commit: does it close the finding, and did it introduce anything
>   new (lock refresh semantics when the lock was taken over; the id arithmetic when the window
>   wraps or `getReports` returns fewer records; the fake now diverging from the real hub in a new
>   way; a `checked` list wrong for cashtag or Solana requests)?
> - Re-assess properties 5, 6 and 7 from round 1 with the evidence above, and say plainly what
>   still cannot be concluded and why.
> - Any new finding, ranked as before, with file:line at the pinned commits.
> 
> Return one markdown file: findings (most severe first), a table of the round-1 findings as
> closed / narrowed / still open, the property table updated, what you did not verify, and your
> model name and version. Everything you write is a proposal the session verifies against the
> repository. This is round 2 of 5.
