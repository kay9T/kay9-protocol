# Review of the analysis-pin fix — Claude Opus 5.5 (Anthropic), 21 Oct 2026

A fresh session with no part in writing the fix, read-only, on the uncommitted working tree that
became the fix commit. It was told what the external report said and how the change meant to fix it, and
asked only for what is wrong or missing, with specific areas to check: other paths that write the
registry or settle a job, whether equality is right on every chain the auditors serve, the watchdog
freshness rule, `_latestId` edge cases, readers that relied on the old order, the launch wiring in
`Deploy.s.sol`, docs that still state the old meaning, and missing tests. It made no edits and ran
no tests. Its output follows unchanged. Dispositions are in `2026-10-21-external-report.md`.

---

Findings, most severe first. I made no edits and ran no forge tests; everything below comes from reading the code.

**1. Medium: the monitor stops watching exactly the assets this fix is about.** `services/audit-worker/src/monitor.ts:325-351` and `:382-385`
- **Problem:** `byAsset` keeps, per asset, the record with the newest `committedAt` in the window. It then skips the asset unless `registry.latest()` has the same `reportHash` ("a newer record … lives on another page"). Now that `latest` is the newest analysis, take a watchdog report W followed by a late job record J that was analysed earlier.
  - When W and J fall in the same window (they are usually adjacent ids), the page's newest record is J and `latest` is W.
  - The asset is skipped on every sweep and is never probed again, without any log above debug.
  - `docs/AUDITOR_NETWORK.md:327-328` ("latest … is the newest one this window holds") is now false too.
- **Fix:** pick the page's newest record by `(result.analyzedAt, then window index)`, the same rule the registry uses. Or check whether the hash of `current` appears anywhere among this asset's records in the page. Add a monitor test with W and then J in one window.

**2. Medium: KAY9's own asset page still calls the last write "Latest report".** `apps/web/src/hooks/useRegistry.ts:229`, `apps/web/src/components/registry/AssetHistory.tsx:69,74,96`, `apps/web/src/components/token/TokenDetail.tsx:196`
- **Problem:**
  - `useAssetHistory` sorts by `committedAt`. `AssetHistory` takes `reports[0]` as "Latest report", draws its score in the ring and shows its `committedAt`.
  - So the page shows the older job analysis as current, while the badge (`latestSnapshot`) shows the newer watchdog report. That is the reported impact, on our own site.
  - `TokenDetail`'s status comes from the same `reports[0]`.
  - The chart plots points at `committedAt`, so the "score held until the next report replaced it" copy is false for a late job.
- **Fix:**
  - Take the latest from `latestSnapshot().reportId`, or sort by `(analyzedAt desc, reportId desc)`.
  - Show `analyzedAt` next to the headline score.
  - Plot the chart at `analyzedAt`.

**3. Medium: the launch gates are not reopened, by the readiness document's own rules.** `docs/LAUNCH_READINESS.md:22`, `:318-324`, `:347-366`
- **Gate 6 (watchdog-stack extension):** it requires a review by two model families at the commit that is deployed. The new hub and registry have not had that review.
- **Same passage (`:324`):** it says a finding in the watchdog stack after deployment means "a redeploy … and gate 1's clock starts again". The diff records neither a restart nor an owner waiver.
- **Gate 8:** it says that when a rehearsed contract changes, "the steps it touches are run again on a redeployed stack". `attest` and the registry are both in request → attest → dispute → expire. The testnet registry is also still the old one.
- **Gate 7:** Slither and the fork suite have not been run on this code.
- The status table still lists gates 6 and 8 as passed.
- **Fix:**
  - Reopen 6 and 8, and plan the rehearsal on a fresh 46630 stack built from this commit.
  - Get an owner decision on gate 1 and write it down.
  - Re-run Slither and the fork suite.

**4. Medium: the runbook never re-points anything off-chain at the new pair, and the old pair can never be switched off.** `docs/DEPLOYMENT.md:164-171`, gate 13
- **Problem:**
  - The plan covers `Deploy.s.sol` only. These still name the old addresses and are never told to change:
    - `packages/chain/deployments/4663.json`, including `codeHashes`.
    - `apps/web/api/deployment.json`.
    - The three auditors' `AUDIT_HUB_ADDRESS`, `REGISTRY_ADDRESS` and `AUDIT_HUB_START_BLOCK`: auditor A in the Azure env, auditor B in GitHub secrets, and auditor C.
    - `services/social-bot/facts.md`.
    - The address table in the public repo.
  - The EIP-712 domain changes with the hub address. An auditor left on the old address signs for the old hub, so jobs on the new hub cannot reach 2-of-3 and expire.
  - The old hub still accepts `publishWatchdogReport` from the same auditor set forever, so a stale config keeps writing into a registry with the old semantics.
- **Fix:** add a post-deploy checklist to gate 13 covering:
  - The address and code-hash updates above.
  - Redeploying all three auditors.
  - Watching `reportCount()` on the old registry after launch.
  - A note that the old pair stays writable.

**5. Low: no end-to-end run of `Deploy.run()` in the launch shape.** `packages/contracts/test/unit/DeployWatchdog.t.sol:284`
- **Problem:** the only test calls `_config`. The branch that predicts the hub address from the nonce and builds a fresh pair next to a reused timelock and auditor registry is not executed anywhere in the suite.
- **Fix:** add a test that runs `run()` with only `EXISTING_TIMELOCK` and `EXISTING_AUDITOR_REGISTRY` set, then asserts:
  - `registry.auditHub() == hub`, `hub.registry() == registry`, `hub.auditors() == existing`, `hub.owner() == timelock`.
  - `vault.auditHub() == hub` and `vault.pendingOwner() == timelock`.
  - The expected `hub.accessVault()`.

**6. Low: the fresh hub is still built with a zero vault.** `packages/contracts/script/Deploy.s.sol:173-175` and `:466-471`
- **Problem:** the vault already exists at line 155, but the hub gets `KAY9AccessVault(address(0))`. That forces an extra 48-hour `setAccessVault`, which can be called once only. `_report` prints that proposal in every case.
- **Fix:** in the fresh branch, pass `accessVault` to the constructor and print the `setAccessVault` step only when the hub is reused.

**7. Low: tests that should exist but don't.**
- **`test/invariant/Kay9Invariants.t.sol` / `Kay9Handler.sol`:**
  - No invariant that `latestSummary().reportId` is the last id with the largest `analyzedAt` in the asset's history. The handler already produces out-of-order cases: watchdog reports at `now`, jobs at `requestedAt`.
  - No invariant that a fulfilled job's record has `analyzedAt == job.requestedAt`.
  - No handler action that tries an unpinned `attest` and expects a revert.
- **`test/unit/KAY9Registry.t.sol:324`:** `test_latestReturnsTheMostRecentReportForTheAsset` now passes only because of the tie rule (`_result` uses a constant `analyzedAt`).
- **Fix:** add a fuzz test over two interleaved assets with random `analyzedAt`, including report id 0 owned by the other asset.

**8. Low: the fresh registry is the last chance to make history reads follow the new rule.** `packages/contracts/src/KAY9Registry.sol:74-81`, `:409-426`
- **Problem:**
  - `scoreHistory` returns commit order and `committedAt` only, so its last point is no longer `latest`. The badge page documents it to integrators.
  - `ReportRecorded` has no `analyzedAt`, so an indexer working from events cannot apply the rule.
  - The registry is immutable after this deploy.
- **Fix:** before the launch deploy, add `analyzedAt` to `scoreHistory`'s output (or a sibling read) and to `ReportRecorded`. Optionally add a flag saying whether the record became latest.

**9. Low: docs and copy still give `committedAt` as the date of `latest`.**
- **Places:**
  - `docs/AUDIT_PROTOCOL.md:264-265` and `:689`.
  - `docs/CONTRACTS.md:369-370`.
  - `ARCHITECTURE.md:371`.
  - `docs/AUDITOR_NETWORK.md:331-332`.
  - `apps/web/src/app/[locale]/badge/page.tsx:65` (`committedAt // always render this`, and it advertises `latestSummaryForToken`).
  - `apps/web/src/i18n/dictionaries/en.ts:1053` says "when it was measured", but that call returns the commit time.
  - `apps/web/src/components/badge/LiveBadge.tsx:122,322` renders `committedAt` as "last updated" and ignores `analyzedAt` (`tuple[7]`), although the `latestSnapshot` NatSpec says a reader must always show it.
- **Fix:** match `CONTRACT_INTERFACES.md` ("when it was taken" = `analyzedAt`), point integrators at `latestSnapshot`, and show `analyzedAt` in the badge.

**10. Info: the watchdog deploy script still tells the operator to reuse the old pair.** `packages/contracts/script/DeployWatchdog.s.sol:247-248`, `docs/DEPLOYMENT.md:157-161`
- **Problem:** the script prints `EXISTING_REPORT_REGISTRY` and `EXISTING_AUDIT_HUB` for the launch, and DEPLOYMENT.md still says "must be given all four". Nothing in `Deploy.s.sol` refuses the old pair on mainnet.
- **Fix:** have `Deploy.s.sol` refuse the 25 Sep hub or registry addresses (or code hashes) on chain 4663.

**11. Info: the check binds the signed label, not the state that was analysed.**
- **Problem:** a colluding quorum can still analyse an earlier block and label it `requestedAt`. The NatSpec and doc line "nothing stopped a quorum settling a job with an analysis taken long before" overstates what the check gives.
- **Also:** with about 10 blocks per second, a tie on `analyzedAt` can join a watchdog report pinned to its epoch block and a job pinned by timestamp that read a different block in the same second. The later commit wins even if it read the earlier block.
- **Fix:** reword both statements; say that a verifier checks `analyzedAtBlock` in the report body.

**Checked and sound:**
- **Other write and settle paths:** no finding. `recordReport` is reached only from `_finalize` (via `attest` or `finalizeAgreed`) and from `publishWatchdogReport`. `finalizeAgreed` can only settle positions `attest` recorded, and the digest covers `analyzedAt`.
- **Equality on every chain:** no finding. `analysis.ts:201` enforces `analyzedAt === requestedAt` for EVM, BNB and Solana (including the snapshot path), and `auditor.ts:317` always pins jobs by timestamp. Block pins are used only by the monitor, which goes through the watchdog path with no equality check.
- **`publishWatchdogReport` freshness:** no finding. `latestAnalyzedAt` is the running maximum, because the update uses `>=`. That is the same as the old `_maxAnalyzedAt`, including `analyzedAt == 0`.
- **`_latestId` edge cases:** no finding. Report id 0, the first record (`ids.length == 1` short-circuits), ties, and isolation between assets are all handled.
- **`Deploy.s.sol` wiring with `EXISTING_TIMELOCK` + `EXISTING_AUDITOR_REGISTRY`:** no finding. The authority graph accepts that shape. The address prediction is correct and checked by `require`. The hub is owned by the existing timelock and bound to the existing auditor registry. `vault.setAuditHub` is called with the new hub, and vault ownership is handed to the timelock. Items 5 and 6 are the only gaps.
- **ABIs:** no finding. `packages/chain/src/abis/kay9.ts` and the regenerated ABI both carry `AnalysisNotPinned`.
- **Other readers:**
  - `beta.ts` uses only `exists`.
  - `JobView` reads by `job.reportId`.
  - `RegistryTable` lists in log order.
  - `useAuditedAssets` uses `historyCount`.
  - The social-bot and discovery-worker do not read `KAY9Registry`.

  No finding.
