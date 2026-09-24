# KAY9 implementation status (2026-09-11)

This is a progress report, not a completion report. Nothing below is claimed as done unless it is,
and every claim of "done" names the evidence: a commit, a tool run, or a transaction hash.

Two product changes landed before this revision, in order: pay-per-audit was replaced by the access
lock in `KAY9AccessVault`, and the watchdog now ships before the token. This revision adds a third
thing, which is not a product change but a correction that had to be made before either of the
first two could be trusted: **the contracts read the wrong block clock**, and the testnet rehearsal
that this document was waiting for is what found it (§1).

### What is live, and what is not

| | State |
|---|---|
| Token discovery, ten verified sources | written, tested, run against mainnet: 1,459 tokens in one pass over 20,000 blocks |
| Automatic scan pipeline and Merkle batching | written and tested; `services/discovery-worker` wires discovery, scanning, publishing and committing into one deployable job — **not deployed or run anywhere yet** |
| `KAY9ScanRegistry` | written, tested, gas-measured; **deployed nowhere** but the testnet rehearsal stack |
| Live feed, watchdog dashboard, token pages | on kay9.io; the live feed runs the free basic scan in the visitor's browser over the launches that reached a real pool (with a 30 s clock, a per-browser cache and a "look further back" button), prefers the committed on-chain record where the registry holds one, and draws unmeasured dimensions as "not measured" rather than as a number (§1.11) |
| Score calibration | four real tokens, three systematic defects found and fixed; needs 50+ including known rugs |
| Deep/forensic beta intake, pre-token | `services/audit-worker`'s `beta`/`beta-api` written and tested — **not deployed** |
| Testnet rehearsal, chain 46630 | **done end to end on the clock-fixed contracts** (§12) except `renew` and `unlock`, executable from 2026-09-18 (7-day minimum period). Found §1.8 (site could not exit a bid at the clearing price; fixed) and §1.9 (the USD-era oracle failed closed when its poker stopped), which led to §1.10. The KAY9-denominated vault was then redeployed on the same testnet token and rehearsed again the same evening (§13). A third full run on 2026-09-14 covered the launch-path fixes (§14) |
| Access lock | **redenominated to KAY9 on 2026-09-11** (§1.10): deep 5,000 KAY9, forensic 10,000 KAY9, owner-adjustable through the 48 h timelock, no oracle, no keeper. `KAY9Pricing` is gone |
| $KAY9 | **not launched, and gated.** Owner's target date: Tuesday 10 November 2026 (`docs/ROADMAP.md` §8.1); a target that moves if a gate is open |

`docs/DEPLOYMENT.md` §6 is the template for the final mainnet launch report, and it is not filled
in because there has been no launch.

## 1. What the 2026-09-11 audit pass found, and changed

A from-scratch review of every contract, the scripts, the services and the docs, treating each
claim in the repository as a claim to verify. Findings, most serious first. Every contract change
has a regression test in the existing style, and none crosses a non-negotiable in `CLAUDE.md`.

**1.1 The launch was measured on the wrong clock (critical; fixed in `0b528e3`).** On Robinhood
Chain — an Arbitrum Orbit chain — `block.number` inside a contract is the *parent chain's* height
(11,679,667 on testnet, 25,951,849 on mainnet on 2026-09-11), while `ArbSys.arbBlockNumber()` is
the chain's own (117,236,896 and 59,983,529 the same moment). Uniswap's Continuous Clearing Auction
and LBP strategy read the second through `BlockNumberish`. `KAY9Genesis` validated the window and
reported `launchState` against the first, with bounds of 300–7,200 blocks that an earlier revision
had derived from a `Multicall3.getBlockNumber()` measurement — real, and irrelevant, because the
auction never reads that number. The first testnet launch of the day (`KAY9Genesis`
`0x28d6BfaACa136dBAC8db37ac424e700bdA19015c`, auction `0x1C3023A5D5C6aA45CFBdCb34bd9B10C81c6A7D96`,
window 11,679,656–11,679,956) was over before its first bid: `submitBid` reverted `AuctionIsOver()`
while `launchState()` answered `AuctionLive`, and would have kept answering it until the parent
chain reached block 11,679,956, decades away, which also put `markFailed()` and any relaunch out of
reach. No unit test and no mainnet fork could see this; both run on an EVM where the two clocks are
whatever the test sets. Fix: `KAY9Genesis`, `KAY9AuditHub`, `KAY9Registry`, `KAY9ScanRegistry` and
`KAY9Pricing` inherit `BlockNumberish` and read the auction's clock; bounds back to 36,000–864,000
(one hour to one day at 0.1 s); `chainBlockNumber()` exposed; `Launch.s.sol` derives at 100 ms per
block; the fork suite pins `block.number` to a parent-chain height and moves only the ArbSys mock,
so a vault reading `block.number` anywhere now fails it. `docs/RESEARCH.md` has both measurements.

**1.2 Anyone could choose the `reportURI` the registry keeps forever (medium; fixed).** `attest`
and `publishWatchdogReport` were open to any caller, `reportURI` is deliberately outside the signed
struct, and the signature relay is readable by anyone. A stranger holding two honest signatures from
the relay could race the auditors and record a dead or hostile pointer against an honest score. The
submitter must now be an active auditor (`SubmitterNotAnAuditor`); `markExpired` stays permissionless
because nothing reaches the log through it.

**1.3 A hub migration stranded pending jobs (medium; fixed).** `restore` accepted only the current
hub, so once governance pointed the vault at a new hub, the old hub's `markExpired` and disputing
`attest` reverted `NotTheAuditHub` forever and the units stayed stranded. `setAuditHub` now retires
the hub it replaces; a retired hub may `restore` and nothing else.

**1.4 A period could open on a zero requirement (low; fixed).** `lockedKay9 == 0` is how the vault
spells "no record", so an oracle quote that truncated to zero would have opened a period `consume`
and `unlock` could not see, or let `renew`/`upgrade` wipe a live principal. `ZeroRequirement`.

**1.5 The oracle could be bound to the wrong market (low; fixed).** `configurePool` now requires
native ETH / KAY9 at fee 10000 and tick spacing 200; the hook is free because `recover` builds a
hookless pool. The `DEPLOYMENT.md` example bound the hookless key by mistake; corrected.

**1.6 Off-chain (fixed in `9288d63`).** Five findings from reviewing the workers against the
contracts: the timestamp pin was not final while the chain head was still inside the requested
second (two honest auditors could resolve to two blocks and never reach quorum) and silently fell
back to the head or an unpinned read; peer envelopes from the public relay were never
signature-verified before being bundled, so anyone could block co-signing and, on the watchdog
path, block publishing; monitoring and beta reports pinned assets on other chains to a Robinhood
height; `X-Forwarded-For` reset the per-address limits; the discovery worker could commit
`scannedAtBlock = 0`. All fixed, with tests.

**1.8 A bid at the clearing price could not leave through kay9.io (medium; fixed in `60b6202`).**
Found by the rehearsal, not the review. The CCA's `exitBid` serves only bids priced strictly
above the final clearing price; a bid priced *at* it — where most of a real auction's demand
ends up, and where two of the three rehearsal bids were — reverts `CannotExitBid` and must leave
through `exitPartiallyFilledBid(bidId, lastFullyFilledCheckpointBlock, 0)` after the end block.
The site's bid panel offered `exitBid` only, so those bidders could exit from the Uniswap app but
not from kay9.io. The panel now computes the hint from the `CheckpointUpdated` log the price
chart already reads (`partialExitHint`, a pure function pinned by a test against the rehearsal's
own checkpoint chain: 117245106 → 117245119 → 117245829 → 117280992) and sends the right exit
for each bid. `FAIR_LAUNCH.md` names the rule.

**1.9 The oracle fails closed when the poker stops (by design; observed).** After the poke loop
ended at 07:33 the TWAP went `available false` with code 3 (largest gap 466 s over the 300 s
maximum) within nine minutes, and every `quoteLock`, `upgrade` and `lock` reverted
`PricingUnavailable(3)` until thirty more pokes had aged the gap out of the 30-minute window.
That is the contract doing what `ACCESS_MODEL.md` says it does. Its operational meaning for
mainnet is blunt: the poker in `services/watchdog` is part of the access model's uptime, a
five-minute outage of it makes new locks and upgrades impossible for the next half hour, and
`unlock` — which reads no oracle — is the only path that must not care. The rehearsal script
now pokes right before the calls that quote (`rehearse_stage6`), and `WATCHDOG.md` should carry
the same sentence for the operator.

**1.10 The lock is denominated in KAY9, not USD (owner decision, 2026-09-11; done).** §1.9 made
the cost of the USD lock concrete: a keeper poking every few minutes forever, at mainnet gas about
0.07–0.36 ETH a month depending on cadence, and "new access" going dark whenever that keeper's
wallet ran dry. The owner's condition for the project was no recurring cost, and the honest
alternatives were either that bill or a lock denominated in the token itself. The owner chose the
latter. `KAY9AccessVault` now holds `requirementOf[tier]` (5,000 KAY9 deep, 10,000 KAY9
forensic), changed only by `setRequirement` through the timelock, bounded to [1 KAY9, 1 % of
supply] with forensic never below deep; a change applies to periods opened or renewed after it, a
live period keeps what it locked with, and `unlock` returns exactly that and reads nothing else.
`KAY9Pricing`, the Chainlink dependency, the keeper, its config and its tests are deleted; the
launch page still reads Chainlink ETH/USD for display only. Slither dropped from 68 to 52
findings with the contract, the one High among them. Trade-off, recorded in `ACCESS_MODEL.md` §4:
the dollar value of access moves with the token until the owner adjusts the number, and every
adjustment is public 48 hours before it applies. Tests:
`test_setRequirementIsBoundedAndForensicNeverBelowDeep`, `test_setRequirementIsOwnerOnly`,
`test_aRequirementChangeNeverTouchesALivePeriodAndUnlockReturnsExactly`, the renew top-up and
return tests re-pointed at a requirement change, and a `setRequirement` action in the invariant
handler. Rehearsed on testnet the same evening, §13.

**1.11 The basic scan measured less than it could, and the site drew "not measured" as a number
(UX finding from the owner, 2026-09-11; done).** Every category the engine could not measure was
published at the uncertainty ceiling, 65, so five dimensions of a browser scan read as the same
suspicious number. Three things were true underneath it: the docs said the basic tier did no holder
fold when the code has folded in the browser for weeks (`WATCHDOG.md` §2.3 fixed to match the
code); the fold already read every Transfer the activity heuristics need and then threw them away;
and the page had no way to draw a ceiling as anything but a number. Engine 1.5.0 keeps, while the
fold walks, the early-buyer window, the recent window and each recipient's first sender, and runs
the same sniper, bundle, wash-pattern and clustering code the deep tier runs — but only over a
window the fold read in full, with `EVM_EARLY_WINDOW_NOT_COVERED` / `EVM_RECENT_WINDOW_NOT_COVERED`
and the covered height otherwise, and clustering only on a complete fold. The report body now names
its `uncertainCategories`, and the site draws those as a dashed empty track labelled "not measured"
with the reason beneath, in every language. The committed record wins where one exists: the live
feed reads `KAY9ScanRegistry.latestScan` for the launches it would scan and shows the watchdog's
result instead of re-scanning. A visitor may point their own browser at their own archive node
(`audit` page, kept in `localStorage`, sent nowhere). The deployer stays unmeasured at this tier on
purpose: a score that changes with a third-party explorer's index is not one anybody can recompute
from the chain, so explorer facts belong beside the report, not inside it. Tests:
`fold-activity.test.ts` (per-window coverage rules, truncation, chunk-order independence), the
basic-scan and adapter suites re-pinned, `basic-browser-safety.test.ts` still green.

**1.12 A confident-looking overall score could be built mostly on unmeasured categories (owner
finding, 2026-09-12; done, engine 1.6.0).** §1.11 stopped a single unmeasured category from
publishing as a number, but the *overall* trust score still averaged every category's ceiling in
regardless — a basic scan of a token where only `contract` (weight 0.30) and `bot` (weight 0.07)
could be measured, both cleanly, published an overall of 76 ("Low risk") even though 63% of the
score's own weight was five categories that were never actually looked at. `scoreSignals` now
renormalizes `overall` to the categories actually measured (excluded, not averaged in, once a
category lands on the uncertainty floor); if nothing at all could be measured, overall sits at the
floor itself rather than dividing by zero. The result carries a new `measuredWeight` (0..1, the
share of category weight behind the headline number), published in the report body and read by the
basic-scan UI: below 100% coverage the score card adds a "Partial coverage" note, and below 50% an
"Insufficient data" one, both naming the percentage. Tests: `scoring.test.ts` gained two cases
(excludes a floored category from overall; holds overall at the floor when nothing was measured);
full watchdog suite re-run clean (260/262, the 2 failures pre-existing and live-network-only).

**1.13 The token detail page and the audit form each had their own scan, and neither read the
other's (owner finding, 2026-09-12; done).** A token already scanned by the live feed — cached in
this browser's `localStorage` — showed as completely unscanned on its own `/token/detail` page,
and clicking "Run a basic scan" from there recomputed from scratch even though the same browser had
already done the work. Two separate gaps: `TokenDetail.tsx` read only the on-chain registry
(`useLatestScan`, always empty since the registry is not deployed) with no reference to the
browser cache at all; and `AuditForm.tsx`'s scan button called the engine unconditionally, never
checked the cache first and never wrote a fresh result back to it. Fixed on both sides: `TokenDetail`
now falls back to the cached reading (labelled "from this browser's cache") when the registry has
nothing, gated to the chain the cache is actually keyed under (`isCacheableChainKey`, new export in
`scanCache.ts`, shared by both files); `AuditForm`'s scan button checks the cache first (instant,
no network) and only calls the engine on a genuine miss or an explicit "Scan again", writing every
fresh result back to the cache on success. Tests: three new cases in `audit-form.test.tsx`
(cache hit skips the engine and labels itself; a fresh scan writes the cache; "Scan again" bypasses
it); `localStorage.clear()` added to that file's `beforeEach` since the form now touches real
storage and one test's write was otherwise read back as a hit by the next test's identical address.

**1.7 Documentation was wrong about the things above.** `RESEARCH.md`, `DEPLOYMENT.md`,
`LAUNCH_READINESS.md`, `ARCHITECTURE.md`, `FAIR_LAUNCH.md`, `TOKEN_DISCOVERY.md`, `ROADMAP.md`,
`CONTRACTS.md`, `AUDIT_PROTOCOL.md`, `WATCHDOG.md`, `AUDITOR_NETWORK.md`, `SECURITY.md`,
`CONTRACT_INTERFACES.md` and `packages/chain/src/chains.ts` all carried the 12-second clock or the
open `attest`. All rewritten. `SLITHER.md` described contracts that no longer existed; rewritten
from a fresh run.

**Looked at and deliberately left alone.** The immutable registry-to-hub binding
(`docs/REGISTRY_UPGRADE.md`, Option A): the reasoning holds and 1.3 removes the one migration
hazard it had. The two-tier hardcoding in the vault and hub: a third tier means a new vault and
hub, which the retired-hub path now makes survivable, and generalising the quota logic on the eve
of launch is speculative work on the contract that holds other people's money. The 48-hour timelock
on `setRequestsPaused`: it is not an emergency brake and the docs say so; a paused hub still settles
every open job. The capital-only cost of quota: $100 refundable buys four in-flight deep audits, so
$10,000 keeps 400 jobs open and re-requests them as they expire — a capacity concern for the
auditors, bounded by their own per-invocation ceilings and by `setQuota`/`setUsdTarget`, not a
correctness flaw; noted in §8. The two-of-three quorum with two identities in the owner's accounts
(`AUDITOR_NETWORK.md` §4.3): the documented mitigation is honest and there is no mechanism that
substitutes for independent operators; it stays the first item of `ROADMAP.md` §6.

## 2. Contracts

Nine contracts plus governance wiring, `KAY9Pricing` having been removed by §1.10. `forge build`
is clean on the current tree.

| Contract | State |
|---|---|
| `KAY9Token` | unchanged. Fixed 1,000,000,000 supply, no mint, no owner, no tax |
| `KAY9TeamVesting` | unchanged. Three tranches at immutable calendar timestamps |
| `KAY9Genesis` | **reads the auction's clock** (`BlockNumberish`); bounds 36,000–864,000; `chainBlockNumber()` |
| `KAY9LiquidityLock` | unchanged |
| `KAY9AuditorRegistry` | unchanged |
| `KAY9AccessVault` | **requirement is a fixed KAY9 amount per tier** (`requirementOf`, `setRequirement`, bounds, forensic ≥ deep); no oracle; retired hubs may `restore` |
| `KAY9Registry` | `committedBlock` is the chain's own height |
| `KAY9AuditHub` | submitter must be an auditor; `requestedBlock` is the chain's own height |
| `KAY9ScanRegistry` | `committedBlock` is the chain's own height |

## 3. Tests

| | Result |
|---|---|
| `forge build`, `forge fmt --check` | clean |
| Offline tests, default profile | **321 passed, 0 failed** across 24 suites on 2026-09-23 (unit, review, invariant and script suites; the pricing suites and `VaultZeroRequirement.t.sol` went with the redenomination) |
| Fork tests, live Robinhood mainnet | **3 passed** on 2026-09-23 at `b7006af`, forked at mainnet block 70,397,407, with `test_fork_nonGraduation` now going on to relaunch through the canonical stack with the owner-facing salt unchanged (first run the same day at `686b27c`, block 70,346,959) with `block.number` held at a parent-chain height and only ArbSys moved (`test_fork_fullLaunchCycle`, `test_fork_nonGraduation`, `test_fork_recoverAfterFailedMigration`). The previous run was 2026-09-11 at block 59,996,178, before the September remediation touched `KAY9Genesis` |
| Slither, all nine contracts | re-run 2026-09-24 at `launch-review-5`, after the gate-6 fixes: 68 distinct findings in 13 classes, none a defect and none above Medium, each dispositioned in `packages/contracts/SLITHER.md` |
| `@kay9/chain` | 93 passed (2026-09-23) |
| `@kay9/watchdog` | 324 passed offline (2026-09-23); the three live tests against the public mainnet RPC are skipped in CI and were run by hand the same day, 3 of 3, after the same-block determinism test was made to say which reads the endpoint refused instead of only that two hashes differed |
| `@kay9/audit-worker` | 252 passed (2026-09-23) |
| `@kay9/discovery-worker` | 83 passed (2026-09-23) |
| `@kay9/web` typecheck, lint, unit tests, static export | clean; 265 passed; `next build` exports 217 page routes (2026-09-23) |

## 4. Services

Rewritten for the access model in an earlier revision; hardened today (§1.6). Deployment shape
unchanged: three scheduled scale-to-zero jobs. `docs/AUDITOR_NETWORK.md` §4.3 still states that at
launch two of the three auditor identities run inside accounts the owner controls.

## 5. Website

Renders the access-lock flow and the browser basic scan as before. New today: the live feed and the
watchdog page run the basic scan in the visitor's browser over the launches that reached a real
pool, one at a time and at most a dozen, and show the ring, band and block for each — labelled as a
reading this browser took, never as an on-chain record, because the scan registry is not deployed.
The cross-chain tree draws the Solana adapter as shipped with a "basic scan" state (it is; the
browser scan runs for Solana mints and BNB Chain tokens), distinct from "live", which only Robinhood
carries. Stat tiles and cards tilt toward the pointer; a landed scan sweeps once; reduced motion
turns all of it off. Checked at 1280 px and 390 px: no horizontal overflow, scan states legible.

## 6. Documentation

The three authoritative specifications remain `docs/ACCESS_MODEL.md`, `docs/AUDITOR_NETWORK.md`
and `docs/CONTRACT_INTERFACES.md`. Everything in §1.7 was brought in line today. `docs/ROADMAP.md`
§8.1 now carries the calendar worked back from the owner's target date.

## 7. Verification: done, and still to do

| | State |
|---|---|
| Static analysis on the current tree, vault included | **done 2026-09-11**, `SLITHER.md` |
| Fork suite against real mainnet state | **done 2026-09-23** on the post-remediation tree, 3 of 3 at mainnet block 70,397,407, relaunch included (§3) |
| Testnet rehearsal, `DEPLOYMENT.md` §3 | **executed 2026-09-11** end to end on the USD-era contracts, §12; the KAY9-denominated vault, registry and hub then redeployed on the same token and the access path rehearsed again, §13; renew/unlock from 2026-09-18 |
| Adversarial review of the vault, hub, dispute and restore paths | done by this pass, by one reviewer who is not the author; **gate 6's watchdog part is still open** — it asks for reviews by two model families rather than a human external audit, which was sought and not funded |
| External review of the launch path | a model review of the whole tree ran on 2026-09-17 and its findings were decided and merged on 2026-09-18 (§15); **gate 6 closed for the launch path on 2026-09-25**: GPT-5.6 Sol and Claude Fable 5.1 reviewed it, both confirmed `launch-review-5`, published in `docs/reviews/`, closed by the owner |

## 8. Known limitations and risks

- **The launch auditor set is not three independent operators** (`SECURITY.md` §2.6).
- **Quota is bounded by capital, not by cost.** A 5,000 KAY9 refundable lock keeps four deep jobs
  in flight and expired jobs hand their unit back, so a large depositor can keep the auditors' queue
  full indefinitely. The auditors bound their own work per invocation; governance can raise the
  requirement or cut the allowance on 48 hours' notice. Worth a per-account request-rate limit if it is
  ever exercised; not built now.
- **The public Robinhood mainnet RPC is pruned**, caps `eth_getLogs` at 10,000 matched logs, and
  intermittently sends a duplicated CORS header the browser refuses. The browser scan survives it
  (a refused read is unmeasured, not clean) and logs the refusals; a dedicated endpoint for the
  browser path remains the right fix.
- **Testnet is slower than mainnet.** Measured 2026-09-11: about 0.19 s per block on 46630 against
  0.1012 s on 4663, so a one-hour window on testnet takes nearly two hours of wall-clock time.
- **The requirement is a number, not a price.** 5,000 KAY9 is worth whatever KAY9 is worth that
  day; if the token moves a long way the owner adjusts through the timelock, and the 48 hours in
  between are the only lag. There is no oracle to fail and no keeper to fund, which was the point.
- **The vault handover is two-step**, `settle()` prices off spot, ETH dust stays in Genesis,
  Uniswap's stack is third-party code, `forge coverage` cannot run — all unchanged from the
  previous revision.

## 9. Owner inputs still required

Owner address, team beneficiary, creator-fee recipient, three auditor addresses held by three
parties, the TGE time of day (the date is set: 10 November 2026), floor and graduation FDV,
production RPC endpoint (archive, for the auditors), explorer API endpoint, IPFS pinning
credentials, WalletConnect project id. The two lock requirements are decided (5,000 and 10,000
KAY9) and can be changed through the timelock at any time. None of the addresses defaults to the developer.

## 10. Order of work from here

The calendar in `docs/ROADMAP.md` §8.1 is the order. The next four things, in sequence: finish the
rehearsal's renew and unlock on 18 September; commission the external launch-path review the same
week; deploy the watchdog to mainnet by 9 October so gate 1's thirty days end before the target;
re-run calibration against fifty tokens by 16 October.

## 11. Implementation review (2026-09-09)

Engine 1.3 adds Solana browser scans, strict mint parsing, corrected revoked-extension findings,
validated Raydium CPMM and Orca Whirlpool pool observations, and bounded initialization-transaction
lookup. Engine 1.4 extends that with fee-aware CPMM sell models, LP supply checks, bounded swap
classification and associated-launch lookup; capture, immutable archive files, CLI replay and
audit-worker archive loading are implemented and tested. See `docs/IMPLEMENTATION_REVIEW.md` and
`docs/SOLANA_ARCHIVE.md`.

## 12. Testnet rehearsal record, chain 46630 (2026-09-11)

This section records the day's first rehearsal, on the USD-denominated vault that §1.10 replaced
the same evening. It is kept as it was run: the launch, auction, migration, governance and audit
paths it exercised are unchanged, and the oracle rows are the evidence behind §1.9. The
KAY9-denominated vault's rehearsal is §13.

Run with `script/Testnet.s.sol` and `script/Rehearse.s.sol` from a throwaway deployer
(`0xe4b0C959e1c5eB15C4ed04e0544cA90bf6b1c7Cf`), three throwaway auditor keys and one throwaway
depositor key, all testnet-only and never holding value. Explorer: `https://explorer.testnet.chain.robinhood.com`.

**Attempt 1 — the launch that exposed §1.1.** Stack deployed at 04:52 UTC on the pre-fix bytecode
(`KAY9Genesis` `0x28d6BfaACa136dBAC8db37ac424e700bdA19015c`, `KAY9Pricing`
`0x1bC6610c67aBe0C8361e34134c32Fff57510A397`, `KAY9AuditHub`
`0x5f1510c0E1D98dF4e49EBf129C16E9593f8332AB`). `launch()`
`0xa2ba2e041f397da33ebfebd033250ed8be9566fc1d8303978141a23d5088d499` created auction
`0x1C3023A5D5C6aA45CFBdCb34bd9B10C81c6A7D96` with window 11,679,656–11,679,956. First `submitBid`
reverted `AuctionIsOver()` (chain height 117,236,896); `launchState()` = 1. Abandoned; kept as the
evidence for §1.1.

**Attempt 2 — the clock-fixed contracts (commit `0b528e3`).** Addresses in
`packages/chain/deployments/46630.json`:

| Contract | Address |
|---|---|
| KAY9Genesis | `0xae9fFb1E36722e3007AE5f4f8028570A78b3773a` |
| KAY9Token | `0x7F284A8BBbb9dd3b3EC0b6aEfe0e278d8B748048` |
| KAY9TeamVesting | `0x08C9a8078e17057b794a48Ae302B0CC369A75949` |
| KAY9LiquidityLock | `0x6C18E454466545cd91C5134B4c44422E8E7692d7` |
| KAY9AuditorRegistry | `0xe2CEF61e152aD3A550345c887452E6232AbB4b4C` |
| KAY9Pricing | `0xcffE5Ad8d40988008ef3A6a82DB6D752F90C491E` |
| KAY9AccessVault | `0x1dF829F2B3e97E0AeA99e8002eF8B84D95517f34` |
| KAY9Registry | `0x629Ddb2C9169E2EC64606FB328Bb43115e66f4d9` |
| KAY9AuditHub | `0xe5d9ECdE96A917797061141f19E34BF45aD59D41` |
| TimelockController (60 s rehearsal delay) | `0x9B0244c1e83D60AcD5fEF237C6BA5d9821b48198` |
| MockV3Aggregator | `0x28436fF249354307f2CD79349C3F3BC5b5Ab45E7` |
| LBPStrategy / LiquidityLauncher / InitializerHook (rehearsal copies) | `0xAF0fE986D44Db1eAd8C5ce28687EFCB681312000` / `0x73F1af11Db8454Ac7f643B29cB989215077FCf0D` / `0x2dAB92DC7E9D82bCB527b50767911AAd83226000` |
| FeeSplitter / BeneficiaryVault / Compounding (rehearsal copies) | `0xB89a8654bfd418b8A205018351D9Fe957356A6eF` / `0xA43d71F0159FA9E47D439c09874DCD8eF4149B04` / `0xEA19aDda45b87D2d1A684Ad06F90170325FB5d5e` |
| Auction | `0xE3288449c64CD4e7925d1E376cEA95F8FdEBD0EA` |

| Step | Transaction | Observed |
|---|---|---|
| Deploy (Testnet.s.sol) | `0x797388ff…5b143` (Genesis) … `0xc09e5646…2a189` (vault ownership proposed); full list in `broadcast/Testnet.s.sol/46630/` | 35.4 M gas, 0.0007 ETH |
| `launch()` | `0xa2d5b5c8b38f48ccda659943500ee7ec22a37dccbd4bbbb050b6e7d339f8e2bd` | window 117,244,992–117,280,992 on the chain's clock; floor FDV 4.0e14 wei, required raise 3.64e14 wei; `launchState` 1 while the window is open |
| `submitBid` ×3 | `0x0a63dfb1…70361`, `0x5a4904b7…aa514`, `0xb38f64b4…65563` | one bid per transaction; a second bid at the same price in the same block reverted `BidMustBeAboveClearingPrice`, as it should |
| `checkpoint` after the end block | `0xd34f85aad1aa7a7c032ed37a47c9eb27ca29df62c989c53941d56b18578452c3` | 06:42 UTC, chain height 117,281,147 ≥ end 117,280,992; `isGraduated` true, `launchState` 2 |
| `migrate`, `lock`, `settle` | `0x22b449862926e519cf4df8f625d19d49bc4464537f24aa8e3021a1b42e16da8f` (migrate+lock), `0xbdab9dbda3047f04101ef547e64c4b24116c9dddaaf3a4312d8ec6aa15942949` (settle) | LP tokenId 3968 owned by FeeSplitter, `launchState` 3, pool hook `0x2dAB…6000` |
| Timelock batch: `acceptOwnership`, `configurePool(genesis.poolKey())`, `setLockDuration(7 days)`, `setSla(1 hours)` | `0xa2106489d8c5cff1d5dfad14be9e31197c7bb7a93d77970fed55ba8542256c50` (schedule, op `0xbe996c75…`), `0x3be6ad3575979061bc5a0ffc0a823c724e310f4cbe7fb7dc953c38245ee4f54f` (execute, 60 s later) | vault owner = timelock, `poolConfigured` true, `lockDuration` 604,800, `slaSeconds` 3,600 |
| Mock feed set (2.5e17 E8) | `0xe3e147e8084c1e313d53c5bab73da18713abcb08083574f29e761907ac3fa71e` | oracle `available false`, code 2 (one observation) until the window fills |
| `poke` ×40, 06:45–07:33 UTC | `0x22bf0954…2235` … `0xb6126307…07f1`, then `0x780e73d8…f50fb` | `available true` at 07:33 (19 observations, largest gap under 300 s, TWAP 6.2495e29 vs spot 6.25e29 KAY9/ETH e18) |
| `exitBid` ×3 → `claimTokens` ×3 | bid 2: `0x00309f100e53f180ed7c6615b8b8c6b25f770654ff5b340b23c17816a7948352` then `0x2595a846f629be5557bce40a934ca8b29ba32281283559980e59c588d97dbc4a`; bids 0 and 1 through `exitPartiallyFilledBid(id, 117245119, 0)`: `0x47f39cda4b001622868496ea1fb1b200826b1446f192dcb5ce7f172b319004d4`, `0x41cea6baf7ca56b8a842ba6e135f4925610dc8e3b6e3e295f77308dae56a0233`, then `0x682a32879b14876d906191d505526999bd53bb0e351b5f7a02e9b8f51641523a`, `0x9beb311f3d63890c7f410bd43c5ef32dd24b9dce63ce1ca15a01f38866c9f48c` | **§1.8**: `exitBid` refused bids 0 and 1 with `CannotExitBid` because they sat exactly at the final clearing price (1.2677e17); `claimTokens` before any exit reverts `BidNotExited`. Depositor ends with 454,974,999.99 KAY9, the whole auction allocation less dust |
| `approve`, `lock(1)` | `0x9a6ef371a02e02304e29d2799bb37b7f39ac737f2e11dc8595d3a8808e60c8de`, `0xcc8a28fb0f8c38ca991fdd91e1195dfc90ca75b67e9511f427e2fdb46243862c` | deep period, requirement 25,000.000000000000027 KAY9 for the $100 target at the rehearsal FDV; before the claim the same call reverted `ERC20InsufficientBalance`, as it must |
| `requestAudit` (job 1), `attest` A+B | `0x206b7da5455af365812c2c64d8ad64c66b359bd01d34012fcec49fc458998443`, `0x88f927358177c1f416877ad9bc35bd256a3dc3362ff1a7e05d7b4de1bbe46808` | reportId 0, job status 2 (settled); a `requestAudit` sent before the lock reverted `NoAccess()` |
| `requestAudit` (job 2), `attest` ×3 with three different results | `0x22436f41889829834db38978b07e16fa3c3fa9bec8c0491a8dbcb36423c44518`; `0x65f97fedaba61343a37238c327214994fc415e023d14118ea52410c5684f4d72`, `0xa30c3a34f90bae0441b1cbb9fd4e4e36ba4d7af0cea44a22153173fe3e6b8c39`, `0xa8a109604d10fdfc091fd4fb6a5472c1089823091c131ca5f7c76398f567cf49` | disputed: no two auditors agreed, no report written, the unit refunded |
| `requestAudit` (job 3), left to expire; `markExpired` after the 1 h SLA | `0xfe042b9fad861e1a90b3681ba7a1ef83cdee8b16c88f49620c0a00d4cf0e4bdf`, `0x4fb903a268dc7a428d54594ea274fa4e00446e9b32c30ea71c546900c7d46d24` (08:40 UTC, 66 s after `jobExpiresAt`) | job status 4 (expired), deep units used went 2 → 1: the unit came back, `totalLocked` unchanged at 125,000 KAY9, nobody paid anything |
| Stale feed (`updateAnswerAt` 2 h back), `quoteLock` while stale, feed restored | `0xf6f68582200bbf1cb51aa41cf9641199329fa803e0105f86ea91696ea1f97465`, `0x1cf0dae7ffde41808d79ac1c42f3f6cbff605313a7940e5189cd4bfbe4ba0bc6` | `quoteLock` reverted `PricingUnavailable(3)`. Honest note: code 3 is the TWAP's own gap check, not the feed check (code 4). The poker had stopped at 07:33 and the 466 s gap tripped first, so this run did not isolate the stale-feed path; the unit tests do (`Pricing.t.sol`), and **§1.9** records what the run did show |
| `upgrade` (deep → forensic) | `0x9f7816f99883da1bb3da92bcf78f8090ba4142d4a2716ee8f5fc8b00d5acb04d` (08:19 UTC, after 30 more pokes; the first attempt at 07:39 reverted `PricingUnavailable(3)`, §1.9) | tier 2, `totalLocked` 125,000.000000000000138 KAY9 = vault balance, `expiresAt` unchanged at 1789717047 (2026-09-18), deep 2 of 4 used, forensic 0 of 1 |
| `renew`, `unlock` | **not before 2026-09-18** (`MIN_LOCK_DURATION` is 7 days; the period was opened with the minimum); `script/rehearse-renew-unlock.sh` | |

This table is updated as each step lands; the transaction files under
`packages/contracts/broadcast/` are the primary record.

## 13. Second rehearsal: the KAY9-denominated vault (2026-09-11, evening)

Run with `Rehearse.s.sol` stages `deployAuditStack`, `govSchedule`/`govExecute`, the access stages
and the new `requirementSchedule`/`requirementExecute`, against the token, auction, auditor
registry and timelock of §12. The old vault, registry and hub were left exactly as they were.

| Contract | Address |
|---|---|
| KAY9AccessVault (KAY9-denominated) | `0x995cd0EB6360ec78eA9AFb3738169F84437821bc` |
| KAY9Registry | `0x3b5D0fE7ad0361f3664EebAC8330d14677Ae6186` |
| KAY9AuditHub | `0x0FaE26903Ec6AE3F56702c5897eFaEB1ceA900cC` |

| Step | Transaction | Observed |
|---|---|---|
| `deployAuditStack`: vault, registry, hub, `setAuditHub`, `transferOwnership(timelock)` | `0x9248250c307b1da7ad7e38107bb5793475146bbdf72ef9709b56d470d7e14916` (vault), `0x464f7b7c95f75d0917bf22ea350f52c6d7bccb220324add40cf04959ddf1e1ad` (registry), `0xa1691daf2a64eb8e561f6f4208c73bb46bcf4f357d863ebfb432437f6f89aeb8` (hub), `0xda96f30916ae5ec0a807c7f1947e1e1d57c3bd901dc7ce933cf1b381edc9bc17`, `0x1ad43d40e7c3146d74286ac36116f8fcb8ef537760d1283c40183b0294499e68` | 09:57 UTC; `requirementOf(1)` 5,000 KAY9, `requirementOf(2)` 10,000 KAY9 from the constructor; the hub's address predicted from the deployer nonce and verified |
| Timelock batch: `acceptOwnership`, `setLockDuration(7 days)`, `setSla(1 hours)` | `0xaacad1c99d752875c0433d33967c0fddb35452fe04b5ea1fd14c96659776ed3a` (schedule), `0x94914e7de481966776360d2dd266ee5d87bbf5132a3c5b8a9fe0a99fc86364e9` (execute, 60 s later) | vault owner = timelock; no `configurePool`, nothing to bind |
| `approve`, `lock(1)` | `0x1dac26328fed7903725b3a41cbf83adce2ea7376ef9a1722963367d066cd4a43`, `0x39bb2cb9400cfb3d04edf6ce57f74ea25a225ce7f087942595fb31f229ba7297` | exactly 5,000 KAY9 taken, `totalLocked` 5,000, no oracle read, no keeper running anywhere |
| `requestAudit` (job 1), `attest` A+B | `0x933f0595238db969351a0f52980b1e17d33c10aaab50a28737c84ef0ce0653d3`, `0x751f5372693086ab012b3a6b869dc76cf8a2f696f4dffed9a27f9fc982fbe5aa` | settled, report 0 in the new registry |
| `requestAudit` (job 2), `attest` ×3 with three different results | `0x1df64792fe6afdb4c4fce3aafc5937ca680e217df1931911f3e5653102e6d17f`; `0x8407bfc9719ac0b31d6e9403b1dbcc845a44f2d66e83c3f1e2e25b22dfa6e4c0`, `0x997dd5b31cfaa085e5743f600a08e433f2bac36223ef9710bfac8dc32fa76882`, `0xc7b9179651b1316a9b686bdeb5115b8a1144a275ffbcbf18e738b97ccc525907` | disputed, unit refunded |
| `requestAudit` (job 3), left to expire | `0xa4047d714afe2fb25e0c1753815774a57c1515d8dd8c42fcad7436d1f8c85563` | `markExpired` `0x1fc5409ef4e68db571558ad1f6e143760d7c858419c1836ebe9ae407b8337b4c` at 11:01 UTC, 26 s after `jobExpiresAt`: job status 4, deep units used 2 → 1, `totalLocked` unchanged at 10,000 KAY9 |
| `upgrade` (deep → forensic) | `0x1c2e150192210b05ab75047f7adff2130a1297bd2820f287c0ead5ce16a1177d` | topped up 5,000 → 10,000 KAY9 at once, no warm-up, no waiting; the USD-era upgrade had needed thirty minutes of pokes first |
| `setRequirement(1, 7,000 KAY9)` through the timelock while the period is live | `0x37a19458dd4454c15b8898ffa9eea02dbe9f1224998184086e7fcd47f1eb2b63` (schedule, op `0xee1c2de5…61b9`), `0x4216910f19ac2a9fabbd017c873e8bb1978b5c248d54b17a369a1f5f7318de16` (execute) | `requirementOf(1)` 7,000, `requirementOf(2)` 10,000; the depositor's live period unchanged: tier 2, `lockedKay9` 10,000, `expiresAt` 1789725585 (2026-09-18) |

`renew` and `unlock` on this vault are executable from 2026-09-18 like the first one's;
`script/rehearse-renew-unlock.sh` takes the vault address from the environment.

## 14. Third rehearsal: the launch-path fixes (2026-09-14)

A fresh stack on commit `a8b7baf`, which carries the `KAY9Genesis` launch fixes (official pool
already present, sweeping unsold tokens on recovery, reclaiming the strategy reserve on relaunch,
the final-checkpoint gate in `launchState`, settlement anchored below the clearing price), the
hub's full `Job` struct in the site and worker ABI, and the launch page reading the auction's own
clock. Same throwaway deployer, auditor and depositor keys as §12. Launch parameters: floor FDV
$1, graduation FDV $2, one-hour window, two-minute start delay, ETH at $2,500.

| Contract | Address |
|---|---|
| KAY9Genesis | `0x26b3C50d694250bCED5e8A2c9A67E4580cf6E48F` |
| KAY9Token | `0x0eCA792f1eAD002bF3842EF8c0fd79B730115d42` |
| KAY9TeamVesting | `0x65bc071006754CD020Fd7ebf794cc1550E18794F` |
| KAY9LiquidityLock | `0x21A4F689de9bD0C0190d93FB42A52F08a589234E` |
| KAY9AuditorRegistry (A, B, C, threshold 2) | `0xbd44f189589735379eCfb252b64A3ccbB523c58F` |
| KAY9Registry | `0x263278042bd258215799Ea2a18AaC30378395a13` |
| KAY9AuditHub | `0x8118fC3EE3A801a274eb34d7B3691b8D6880F80A` |
| KAY9AccessVault | `0x194D1B0a3cC1C1918CBf9e9560974295fdBa3855` |
| TimelockController (60 s rehearsal delay) | `0x56157a72401A5FD360E379B530679D56e600f111` |
| LiquidityLauncher / LBPStrategy / InitializerHook (rehearsal copies) | `0x5CCAfA57672B02CeF3Ec439E600838a3a77572B9` / `0xE16cC5D2aF2D2Eb663C018AadB3194b147E32000` / `0x79E49680eC8CF0375Eef78B0a6119B2C1b982000` |
| FeeSplitter / BeneficiaryVault / Compounding (rehearsal copies) | `0xBAABb91149E2a8200aBB478Da2F2492eF8E2BB34` / `0x927C15986D79206176c34433D679dA83e68Db96b` / `0x8D29DB3a7922bEBdAd0246F984d17Fa668f50C21` |
| Auction | `0x1924736771cBC6A42cC49208ED742C9d202CBd74` |

`KAY9ScanRegistry` `0x0cEb7E43200256A668506668c9e88BD5434cFa87` was kept from the earlier stack.

| Step | Transaction | Observed |
|---|---|---|
| Deploy (Testnet.s.sol) | 14 transactions, full list in `broadcast/Testnet.s.sol/46630/` | 23:56 UTC on 2026-09-13; 26.4 M gas, 0.000264 ETH, all succeeded |
| Timelock batch: `acceptOwnership`, `setLockDuration(7 days)`, `setSla(1 hours)` | `0x0498010e5bf2bbf46a2455bc17acd6eec0dc959eee91cead5550f5e967fdd7e5` (schedule), `0x91cf0eb9b71ffa9f6a31ae57ce02019c95e74f70f72330eaba36602dd5ad8771` (execute) | vault owner = timelock, `lockDuration` 604,800, `slaSeconds` 3,600 |
| `launch()` | `0x0744f8f51ca8b83d3fb33a9ba6a4417a707eebf7acb1c45d7296d4d83c124b20` | auction at the predicted address, window 119,012,029–119,048,029 on the chain's clock, required raise 3.64e14 wei, `launchState` 1 |
| `submitBid` before `startBlock` (simulated) | none | reverted `AuctionNotStarted` at chain height 119,011,092 |
| `submitBid` (bid 0, 5.46e14 wei at 8× floor) | `0xed947bf58051006a25647f2039729e637c7a73656d1a5ff10f39ff0f6f29a2b8` | accepted at chain height 119,012,245 |
| After `endBlock`, before the final checkpoint | none | chain height 119,048,175: `launchState` **2**, `isGraduated` false, `lastCheckpointedBlock` 119,012,262. The final-checkpoint gate held: the launch did not read as failed before the last block was checkpointed |
| `checkpoint` | `0xd12553f0a69712ea7dfcc960e600993cefada111b542747d476a4dcab94fc717` | `isGraduated` true, `launchState` 2, clearing price 9.507e16 |
| `exitBid(0)` | `0xfaa76e40e462bff40cbeb7c6a1dc6dfc31bc25fd9609c4f34eb76c5f2870f43f` | exited in one call |
| `migrate`, `lock`, `settle` | `0x7e5978576d257b763e011951daf1f88e844fbe3993ede40cb9264b72c71ca3df`, `0x1ae9c5789f92ff763f6564cee203b0ecdff97d06515bdded3c8c50f0544e2d2f`, `0xb2655b288616c96e2176967bc042a684bf438da0e8b28a7decd607c06ff30d41` | LP tokenId 4504 owned by the FeeSplitter copy, `lockedCount` 1, `settled` true, `launchState` 3, pool hook `0x79E4…2000` |
| `claimTokens` | `0xfda7d39fac32c32eea98d2fdcc353583fed3b488d70115d2f9ac5707d7ecd46f` | depositor holds 454,999,999.999999999 KAY9, the whole auction allocation less dust |
| `approve`, `lock(1)` | `0xb5aa0baa255dac30419107c6cc545e10d1ba94d34d2341eb3e81015846cabc3c`, `0x257e495a6fa7d40dd35a29f7ac6c5b023f52551c29bf090f1db438a939805b77` | deep requirement 5,000 KAY9 |
| `requestAudit` (job 1), `attest` with the A+B signatures in one call | `0xded3c3a464552561b5c47188a3bfee82f65b4c8205ba59ca5949918ffac003c9`, `0x4b77c2af961170c7c196427126f7965d7c815ec3a059196e5e215ed73ee3eafd` | decoded with the site and worker ABI as `Requested, 0 attestations, SLA 3600s`, then `Fulfilled, 2 attestations`; report 0, overall trust 42 |
| `requestAudit` (job 2), `attest` ×3 with three different results | `0xc1df06ad392d3bb6a284b815fafae4ca5ab3139e56f768bb5dfef10b7496c6bc`; `0x1da82fad469ba0f88ecef70e397a2cb618b4d7a560a484066c6b4587bdd92e2e`, `0x473d2884262d274fef8019dd270c24569eaeb6a3fe6156d2c10430d50fb49f77`, `0xfeadfa4a4af6ed8401fd4a9801dddda375a3d4064b6c50f36741b19fa5a76a31` | decoded as `Disputed, 3 attestations, SLA 3600s` |
| `upgrade` (deep → forensic) | `0xd43df93f03ff734a9ab04bfe68a662250cd2851ae2dfe88addd6e8b36da0b399` | forensic requirement 10,000 KAY9 |

Not exercised in this run: `recover` and a relaunch (both covered by the unit tests), `markExpired`
(§12 and §13), and `renew`/`unlock`, which need the seven-day period to pass
(`script/rehearse-renew-unlock.sh`, from 2026-09-21 for this vault).

## 15. Snapshot review and what it changed (2026-09-18)

A model review of the whole tree at `ba6e887` (OpenAI's ChatGPT, 2026-09-17, 21 findings) was checked
finding by finding against the source, and what held was fixed and merged to `main` as pull requests
#11 to #18. It is one model family's review and it was not run at the commit to be deployed, so it
closes no gate; it is recorded here because it changed contracts.

| Area | What changed | Evidence |
|---|---|---|
| `KAY9AuditHub` | the deadline is hard: `attest` reverts `JobExpired` at or after `jobExpiresAt`; vote counters use checked arithmetic | `KAY9AuditHub.t.sol`, three deadline tests |
| `KAY9Registry` | `latestSnapshot` returns `analyzedAt` and the tier beside `committedAt`; `latestSummary` unchanged; `solana:mainnet` named as an alias | `KAY9Registry.t.sol` |
| `KAY9TeamVesting` | dates unchanged; `release` reverts until `KAY9Genesis.settled()`; the beneficiary moves in two steps; `Deploy.s.sol` refuses a TGE in the past | `KAY9TeamVesting.t.sol` |
| `KAY9AccessVault` | `upgrade` never refunds and never locks less than the forensic requirement | `KAY9AccessVault.t.sol`, five tests |
| `KAY9Genesis` | unchanged; how a returned raise is classified, and what a gift of half the raise buys, is measured, written into `ARCHITECTURE.md` §4.2 and pinned | `KAY9Launch.t.sol`, `KAY9Recover.t.sol` |
| `DeployWatchdog.s.sol` / `Deploy.s.sol` | the authority graph is validated before anything is reused: timelock delay, proposer, executor, no role left with the deployer | `DeployWatchdog.t.sol` |
| Engine `1.7.0` | v4 depth read from the right side of a native pair; a bounded search window says what it could not see instead of scoring it; the pinned client pins `getBlockNumber` too | `liquidity-units.test.ts`, `activity-coverage.test.ts` |
| Auditor worker | a signed analysis never consults an explorer; every queue is fair by turn; one scan and one sweep per data directory, each with its own file; a finality lag | `services/audit-worker/test` |
| Discovery worker, social bot, site, CI | see the pull requests; CI now builds and tests every service, and a manual deploy answers to the same CI gate as an automatic one | CI on `main` |

**Nothing above was deployed on chain when this section was written.** That is no longer true: §17
records the redeploy, and Slither was re-run on 2026-09-22 against the post-remediation tree (§7).

## 17. Fourth rehearsal: the redeploy, and the failure path (2026-09-21)

A fresh stack on commit `42e20de`, the first carrying the September re-review's remediation — the
hub's hard deadline, the team-vesting launch gate, `KAY9Registry.latestSnapshot` with its ninth
field `declaredRequesterKind`, `KAY9AccessVault.upgrade`, and `KAY9AuditorRegistry.isHalted()`.
Deployed from `Testnet.s.sol`; the throwaway deployer is the one in `packages/contracts/.env`, and
the depositor and three auditor keys were generated for this run.

| Contract | Address |
|---|---|
| KAY9Genesis | `0xE55Cf2510fbf3842dBC47438b9C4E33044854FA5` |
| KAY9Token | `0x6B55770CE4a5494EE1680b2E4cdB2087004BFF59` |
| KAY9TeamVesting | `0x6fCce3fC9989E0595EeA8005c058cCC72EE47D1c` |
| KAY9LiquidityLock | `0x7217A0C9E7E91a2df5Ab36cd8964A2F75737E73a` |
| KAY9AuditorRegistry (deployer, A, B, C, threshold 2) | `0x9C6e290809763067eA2e5C8F252f6A33BFE03CfB` |
| KAY9Registry | `0x5A2E8eA1286a43B5c561c59f444A55b6Da50bbDD` |
| KAY9AuditHub | `0x340aaeFCeffA487fDB930739363e9Bd09D9B08E2` |
| KAY9AccessVault | `0xCE25552D10F0499322b80A74d91B9e24ae5C997d` |
| KAY9ScanRegistry | `0xA06f45B9Ea4862F5fE61Fd793ecb23Ca3C0E1F6F` |
| TimelockController (60 s delay) | `0x2254A8E3801fCAc3fDa4E06FFcD346f12e1B4027` |
| Auction (first launch, failed) | `0xEF43F36a36690C4dc73e1CB6FB015C1cfF09Bd23` |

`KAY9ScanRegistry` was deployed separately: `Testnet.s.sol` does not cover it and
`DeployWatchdog.s.sol` would have built a second timelock and auditor registry beside the first.
`deployments/46630.json` now names this stack — the one it named before held a registry whose
`latestSnapshot` returns seven fields where `@kay9/chain` decodes nine.

### 17.1 Verified on the stack before any launch

| Check | Result |
|---|---|
| Supply split | 455,000,000 auction / 455,000,000 strategy / 90,000,000 vesting — 45.5 / 45.5 / 9 |
| Vesting schedule | TGE, +182 days, +365 days |
| Team vesting gate | `release()` reverts `LaunchNotSettled` while the auction is live |
| `latestSnapshot` | decodes as nine fields, `declaredRequesterKind` among them |
| `isHalted()` | false, against a real two-of-four quorum |
| `requirementOf` | 5,000 and 10,000 KAY9 |
| `latestScan` on an unseen asset | "never scanned", not a score of zero |
| Wiring | hub to vault, registry and auditor registry |

Governance was exercised through the timelock rather than by the owner key directly: the vault's
pending ownership accepted, its lock period set to the seven-day minimum, the hub's SLA set to an
hour, and a second batch adding the three auditors and raising the threshold to two. Both batches
scheduled, waited out and executed — the mainnet path, at 60 seconds instead of 48 hours.

### 17.2 The launch failed by one wei, and that is the finding

Launch parameters: floor FDV $5, graduation FDV $10, one-hour window (36,000 blocks of the chain's
own clock, about 2h05m at testnet's 0.208 s/block), three-minute start delay, ETH at $2,500. The
graduation threshold came out at 1,819,999,999,999,999 wei.

`Rehearse.s.sol`'s `bid()` committed exactly that, once. The auction credited
**1,819,999,999,999,998** — one wei short — so it ended un-graduated and `launchState` went to
`Failed`. What a bid contributes is credited through the clearing price and that conversion rounds
down, so a bid of exactly the threshold can never reach the threshold. The default `BID_COUNT` of
three had hidden this in §12, §13 and §14 by committing three times the requirement; `BID_COUNT=1`,
chosen here to fit the gas budget, is what exposed it. Fixed in `Rehearse.s.sol`: the bid is now the
threshold plus a tenth of a percent plus one wei, with the reason written next to it.

**The failure path then ran properly, and no previous rehearsal had ever reached it:**

| Step | Result |
|---|---|
| `exitBid(0)` after a failed auction | the depositor's whole 0.00182 ETH back, less gas — 0.0000659 to 0.0018852 |
| `markFailed()` | permissionless, started the 48-hour cooldown; relaunch allowed from 2026-09-23 13:53 UTC |
| `recover()` | reverts `NothingToRecover`, correctly: it serves a *graduated* launch whose migration failed, not an auction that never graduated |
| Tokens | the 455,000,000 stay in the auction until a relaunch sweeps them; `markFailed` moves no tokens |

So the documented guarantee — *if less than `requiredCurrencyRaised` is raised, bidders withdraw
their full ETH* — is now rehearsed rather than only asserted.

### 17.3 What a later session needs to know

The deployer key persists in `packages/contracts/.env`; the depositor and auditor keys were
generated for this run and are deliberately **not** stored anywhere — keys do not go into the
repository, the documents, the memory store or the task state. A relaunch therefore generates four
fresh throwaway keys and runs one timelock batch that **adds the three new auditors, removes the
four stale members (the deployer and the three whose keys are gone) and sets the threshold to two**,
which takes two transactions and 60 seconds of delay; adds before removals, so the threshold never
follows the set down to zero on the way. The removals are not tidiness. The hub disputes a job only
once no position can still reach the threshold, and every active auditor that has not voted counts
as a vote that could still arrive, so with the deployer or a dead key left in the set the
rehearsal's three dissents leave the job `Requested` until the SLA runs out, and the dispute path
is never exercised. The registry on this stack is `[deployer, A, B, C]` with threshold 2, which is
exactly that shape. `Rehearse.s.sol`'s `dispute` stage now refuses to broadcast unless the job ends
`Disputed`, so the mistake fails the simulation instead of passing as a rehearsal (2026-09-23). The
depositor's refunded ETH was swept back to the deployer so nothing is stranded on a key that no
longer exists.

What the relaunch itself does is settled by the code and proven offline: `launch()`'s second branch
calls the strategy's `migrate` on the failed auction, which takes its recovery branch and hands the
455,000,000 reserve back, then sweeps the 455,000,000 unsold tokens out of the auction, then checks
the balance against the full allocation (`test_relaunchReleasesReserveFromStrategy`,
`test_nonGraduationAndRelaunch`, `test_relaunchKeepsTheOwnerFacingSalt`; the fork suite runs the
same relaunch through the canonical mainnet stack in `test_fork_nonGraduation`). Reusing `LAUNCH_SALT` is safe: the strategy salts the auction with the migration
parameters as well, and the migration block differs.

### 17.4 Still owed on this stack

The graduation path (`graduate`, `migrate`, `claim`) and everything downstream of it — `lockAccess`,
`request`, `attestPair`, `dispute`, `expire`, `upgradeAccess`, and reading a real report back out of
`latestSnapshot` — need a relaunch, which the cooldown puts at or after **2026-09-23 13:53 UTC**.
`renew` and `unlock` need a seven-day period on top of that. Gate 8 stays open until those run.

## 18. Fifth rehearsal: the relaunch, and the stack the reviewed code deploys (2026-09-23)

Three runs on chain 46630 on 2026-09-23. The first two stacks predate the gate-6 review fixes; the
third is deployed from `launch-review-5`, the commit both model families confirmed, and is the one
`packages/chain/deployments/46630.json` names now. The four throwaway keys (depositor and auditors
A, B, C) are kept, git-ignored, in `packages/contracts/.env.rehearsal`, because `renew` and `unlock`
need the same depositor seven days after the lock.

### 18.1 The relaunch the 2026-09-21 failure opened

On the 2026-09-21 stack (`KAY9Genesis` `0xE55C…4FA5`), after the 48-hour cooldown, `launch()` was
called again with the owner-facing salt unchanged (14:10 UTC). `launchCount` 2; the failed auction
`0xEF43…Bd23` swept to 0 KAY9; the strategy holding one 455,000,000 reserve, not two; `KAY9Genesis`
at 0 after moving the whole 910,000,000 again; a new auction `0xE155…Dd35` live. That is the path
the offline and fork tests prove, now also executed on the real network.

### 18.2 The final stack, from `launch-review-5`

Deployed with auditors A, B, C at threshold two from the start, so the dispute stage's arithmetic
holds without a rotation batch. Governance ran through the 60-second timelock.

| Contract | Address |
|---|---|
| KAY9Genesis | `0x232afD59C175d35b16dB54a31009B40e8943d436` |
| KAY9Token | `0x2D829fC24da0cB4aeAedAF6CA2deD9b02170ef6c` |
| KAY9AccessVault | `0x91C8d903841B1AeDd591cAeBfD112dE8BC22a649` |
| KAY9AuditHub | `0xab5457f94c8483a42c47Cdc251f4676ff20e0f6D` |
| KAY9Registry | `0x6849B62AF3FA1FDA72c2891290cBEd9BBbADadb9` |
| KAY9AuditorRegistry | `0x519734bf522d9ec37219ec038ccF3B17C01Abb69` |
| TimelockController | `0x30BEfcc29B2aA47AC7379fB19B45E3C825577Ff2` |
| Auction | `0xf784DE24e70224cC626B6FAA94dc6F96A51e1521` |

| Step | Transaction | Observed |
|---|---|---|
| `govSchedule` / `govExecute` | `0x45958791…7f15f`, `0x116446ee…7c8b7` | vault owned by the timelock, period 7 days, SLA 1 h |
| `launch` | `0x498f6e6d…7452e` | $5 floor, $10 graduation, one hour; required raise 1,819,999,999,999,999 wei |
| `bid` | `0xd0d40cec…54a43` | one bid of the threshold plus 0.1 % plus one wei |
| `graduate` | `0x63f3595e…5692a` | graduated |
| `exitBid(0)`, `claim` | `0xb52748ba…9f184`, `0x1d8e674c…328c8` | |
| `migrateAndSettle` | `0x97a56f44…4b19b` | **one transaction**: migrated, migration position locked, settled; `migrationSucceeded` true; the vault holds **0 wei** afterwards (the 2026-09-21 stack's separate calls left 48) |
| `lockAccess`, `request`, `attestPair` | `0x04407e2f…a724b`/`0xee3926f4…04cf7`, `0x24b9bd10…f412`, `0x108322f5…afe1` | report 0 committed |
| `request`, `dispute` | three dissents `0x642bf704…6070`, `0xad152671…0661`, `0x01ffd82c…500e` | job disputed, its unit refunded; the stage refuses to broadcast otherwise |
| `upgradeAccess` | `0x2cde45d0…c4f1` | deep to forensic, 10,000 KAY9 locked |
| `latestSnapshot` | read | exists, report 0, trust 42, tier 1, requester kind 1, analysed and committed times set |
| `expire` | `0x0f7e9efe…e38b0` | job status 4 at 19:00 UTC, its deep unit returned (2 to 1 used), `totalLocked` unchanged at 10,000 KAY9 |

### 18.3 What gate 8 still needs

`renew` and `unlock` on this stack, from seven days after the lock: **2026-09-30 17:58 UTC**,
`script/rehearse-renew-unlock.sh` with the same environment.
