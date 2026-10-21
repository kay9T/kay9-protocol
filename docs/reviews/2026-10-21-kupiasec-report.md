# KupiaSec report, 21 Oct 2026

An unsolicited email to the project mailbox from Nordin Sabli of KupiaSec (sec.kupia.io), sent
21 Oct 2026 03:12 and filed by Gmail as spam. Most of it offers a paid private audit, which the
owner has not taken up. It also reported one issue, quoted here as received:

> **The issue (Low)**
> Where: src/KAY9AuditHub.sol, attest(), finalizeAgreed() and _checkResult()
> What could happen: _checkResult() only rejects an analyzedAt in the future. Neither attest() nor
> finalizeAgreed() binds analyzedAt to the job's requestedAt, so a quorum-signed result analysed
> long before the request could settle a paid deep or forensic job, and the "pin to requestedAt"
> rule exists only as an off-chain convention. The same path also skips the StaleWatchdogReport
> freshness check that publishWatchdogReport() enforces, so a job report with an older analyzedAt
> could become the latest() record over a newer watchdog score.
> Impact: requesters and integrators reading latest() or latestSummary() could be shown an outdated
> trust score for a token whose state changed. Requiring result.analyzedAt >= job.requestedAt, and
> checking against latestAnalyzedAt, would close it.

(No audit is paid for in KAY9; "paid" is the report's wording, not a fact about the protocol.)

## Disposition

| Part | Verdict | What changed |
|---|---|---|
| `analyzedAt` is not bound to `requestedAt` on-chain | **Confirmed, fixed.** The pin was enforced only by `services/audit-worker/src/analysis.ts`, which refuses to sign otherwise. Neither 25 Sep review raised it. | `attest` reverts `AnalysisNotPinned(analyzedAt, requestedAt)` unless the two are equal. Equality, not `>=`: every auditor pins to `requestedAt` so that independent runs agree, and AUDIT_PROTOCOL.md already defined a job's `analyzedAt` as its `requestedAt`. `finalizeAgreed` settles only positions `attest` recorded, so it needs no check of its own. |
| A job result analysed earlier becomes `latest` over a newer watchdog report | **Confirmed, fixed differently from the suggestion.** Both 25 Sep reviews saw this and accepted it as documented ("latest" = last commit, readers show `analyzedAt`). That mitigation cannot reach `latestSummary`, the one-call read a wallet or badge makes, which returns no `analyzedAt`. | `KAY9Registry` keeps, per asset, the id of the record with the largest `analyzedAt` (a tie goes to the later commit), and every `latest*` read returns it. The job's record is still appended, still readable by id, and still the answer to the job. |
| Suggested fix: refuse a job result older than the asset's latest record | **Not taken.** | It would fail an honest job whenever the watchdog reported on the asset between the request and the quorum, and send the requester's quota back for work the auditors did. Choosing `latest` by analysis time fixes what readers see without that. |

## Deployment

The mainnet hub and registry from 25 Sep have never recorded a report or a job (read 21 Oct:
`reportCount() == 0`, `jobCount() == 0`, no access vault). Nothing is redeployed now. The token
launch deploys a fresh pair through `Deploy.s.sol`, given `EXISTING_TIMELOCK` and
`EXISTING_AUDITOR_REGISTRY` but not the old pair's addresses (docs/DEPLOYMENT.md, gate 13 in
docs/LAUNCH_READINESS.md). The ABI changes by one error, `AnalysisNotPinned`; no function changes
shape.

## Tests

`test/unit/KAY9AuditHub.t.sol`: `test_aJobResultMustBeAnalysedAtItsRequestTime`,
`test_aTieInAnalysisTimeGoesToTheLaterCommit`, and `latest` assertions added to
`test_aJobRecordDoesNotReopenTheWatchdogFreshnessWindow`. Tests that attested after warping time
now build the job's result with `_resultFor(jobId)`, which pins it as the auditors do.
`test/unit/KAY9Registry.t.sol`: `test_anOlderLookCommittedLaterIsNotLatest` (replacing the test that
asserted the old order), `test_aNewerOrEqualLookBecomesLatest`,
`testFuzz_latestIsTheNewestAnalysisPerAsset`. `test/unit/DeployWatchdog.t.sol`:
`test_launchRefusesTheSupersededPair`. `services/audit-worker/test/monitor.test.ts`: the late-job
case below.

## Fresh-context review of the fix (Claude Opus 5.5, 21 Oct 2026)

A separate session with no part in writing the fix read the uncommitted change, read-only, and was
asked only for what is wrong or missing. Its output is published in full in
`2026-10-21-kupiasec-fix-anthropic-claude-opus-5.5.md`; below, each finding in one line, then the
dispositions.

1. Medium — `services/audit-worker/src/monitor.ts`: the sweep chose each asset's page-newest record
   by `committedAt`, then probed only when that matched `latest`; with `latest` by analysis, an
   asset with a late job record behind a fresher watchdog report would be skipped on every sweep.
2. Medium — `apps/web` (`useAssetHistory`, `AssetHistory`, `TokenDetail`): the asset page sorted by
   `committedAt` and showed `reports[0]` as "Latest report", plotting the chart at commit time, so
   the site itself showed the older look as current.
3. Medium — `docs/LAUNCH_READINESS.md`: by the document's own rules, the change reopens gate 6 (two
   families must review what is deployed) and gate 8 (rehearsed steps re-run on a redeployed
   stack), and gate 6's text says a watchdog-stack finding restarts gate 1's clock.
4. Medium — `docs/DEPLOYMENT.md`: no post-deploy list re-points the deployments file, the site, the
   three auditors' hub and registry settings, facts.md and the public address table; the EIP-712
   domain includes the hub address, so a stale auditor cannot sign for the new hub; the old pair
   stays writable.
5. Low — no test runs `Deploy.run()` in the launch shape (timelock and auditor registry reused,
   fresh registry and hub).
6. Low — `Deploy.s.sol` builds the fresh hub with a zero vault although the vault already exists,
   costing a 48-hour `setAccessVault`.
7. Low — tests: no invariant or fuzz property over interleaved assets and random `analyzedAt`; one
   existing registry test passes only through the tie rule.
8. Low — the fresh registry is the last chance to put `analyzedAt` into `scoreHistory` and
   `ReportRecorded`.
9. Low — docs and site copy still give `committedAt` as the date of `latest`
   (AUDIT_PROTOCOL, CONTRACTS, ARCHITECTURE, AUDITOR_NETWORK, the badge page and `LiveBadge`).
10. Info — `Deploy.s.sol` would accept the superseded pair; `DeployWatchdog.s.sol` still prints it
    as the pair to reuse.
11. Info — the check binds the signed time, not the chain state read; the NatSpec overstated it.

Sound, per the same review: no other path writes the registry or settles a job; equality is right
for every chain the auditors serve (jobs are always pinned by timestamp, `analysis.ts` enforces
equality for EVM, BNB and Solana); the watchdog freshness rule still holds, since `latestAnalyzedAt`
is still the running maximum; `_latestId` handles report id 0, the first record, ties and asset
isolation; `Deploy.s.sol` wires a correct fresh pair with only the timelock and auditor registry
reused; the ABIs carry the new error; no other reader depends on the old order.

| # | Disposition |
|---|---|
| 1 | **Fixed.** The window picks by `analyzedAt`, a tie to the later record. New test `still probes an asset whose late job record describes an earlier moment than its watchdog report`, shown to fail on the old code. The fake hub now applies the registry's rule for `latest` and the hub's `AnalysisNotPinned`. AUDITOR_NETWORK.md §5 updated. |
| 2 | **Fixed.** `useAssetHistory` sorts newest analysis first, ties by report id; the headline date under "Latest report" and the chart use `analyzedAt`. Per-row lines still say when each record was committed, which they label as such. |
| 3 | **Recorded; the owner decides.** Gates 6 and 8 are marked reopened for the hub and registry in LAUNCH_READINESS.md; gate 1 is written down as an open owner decision. |
| 4 | **Fixed.** A post-deploy list in DEPLOYMENT.md, referenced from gate 13. |
| 5 | **Not done here.** `run()` needs the live Uniswap stack; the reopened gate 8 rehearsal on a fresh testnet stack exercises this exact path. |
| 6 | **Not taken.** The existing launch plan already includes the `setAccessVault` proposal, and changing the launch flow three weeks out for 48 hours of requests is not worth a new path. |
| 7 | **Fixed.** `testFuzz_latestIsTheNewestAnalysisPerAsset` over two interleaved assets, eight possible times (so ties are frequent), report id 0 on either asset. |
| 8 | **Not taken.** `scoreHistory` returns commit times and says so; `getReport(reportId)` gives an indexer `analyzedAt`; changing the event's signature would break every log filter for no reader that needs it now. |
| 9 | **Fixed in the docs** (AUDIT_PROTOCOL §4.1 and the verify recipe, CONTRACTS, AUDITOR_NETWORK). The badge's "Recorded on-chain {date}" is a true statement about `committedAt` and is left; showing `analyzedAt` there is a copy change in thirteen languages, noted for later. |
| 10 | **Fixed.** `Deploy.s.sol` refuses either superseded address (`test_launchRefusesTheSupersededPair`). `DeployWatchdog.s.sol` is history and is left. |
| 11 | **Fixed.** The NatSpec and CONTRACT_INTERFACES.md now say the check binds the signed time, and point at `analyzedAtBlock` in the report body. |
