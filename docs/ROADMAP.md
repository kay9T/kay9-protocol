# KAY9 Roadmap

Everything below is either built and waiting, or a named piece of work with a stated
precondition. Nothing here is a promise of a price, a return, or a reward.

Dates are expressed relative to **TGE**, the moment `KAY9Genesis.launch()` is signed, because
that is the one date the owner controls and every other date hangs off it. The team's unlock
timestamps are the exception in how they are fixed, not in what they mean: they are computed from
the target TGE and burned into `KAY9TeamVesting` when the contracts are deployed, a week earlier,
and cannot move afterwards. If the launch slips past them, the calendar does not pay the team
early: the vesting contract releases nothing until the launch has settled (`KAY9Genesis.settled()`),
and from then on it follows those fixed dates to the second. The owner has set a
**target TGE of Tuesday 10 November 2026** (§8), so the relative weeks below also read as the
calendar in §8.1. It is a target, not a promise: `docs/LAUNCH_READINESS.md` is explicit that a
marketing date never overrides an open gate, and if a gate is open on the date, the date moves.

---

## The order changed: the watchdog ships first

This document used to treat TGE as the pivot — harden, launch the token, then bring the product
up behind it. That order is now inverted, and the inversion is not cosmetic.

**What ships before there is a token at all:** token discovery, free automatic basic scans of
whatever the chain launches, the permanent `KAY9ScanRegistry` record, the live feed, token pages,
the badge, the integration standard and the documentation. None of it needs $KAY9 to exist, none
of it asks anybody for money, and `DeployWatchdog.s.sol` deploys it with no token and no access
vault anywhere in it.

**What waits for TGE:** the access lock, and only the access lock. Deep and forensic audits are
gated on locking KAY9, so they cannot go live in their final form until KAY9 exists. Everything
else about them — the engine, the quorum, the registry, the report format — is testable and tested
without it.

**Why.** A risk product asking to be trusted has to be checkable first. Launching a token and then
building the thing it is supposed to pay for gets the order of proof backwards, and on a chain
producing tens of thousands of token launches a day, "another token that promises a product" is
the single least distinctive thing KAY9 could be.

So the phases below still read in the same sequence, but the gate between §1 and §2 is no longer
"we are ready to launch" — it is the fourteen conditions in
[`docs/LAUNCH_READINESS.md`](LAUNCH_READINESS.md), four of which require the watchdog to have been
live and unattended on mainnet for 30 days with its record independently reconstructed by somebody
outside the project. If a gate is open on the date, the date moves.

## 0. What is already done

The product changed after the first end-to-end build: pay-per-audit was removed and replaced by the
access lock in `KAY9AccessVault`. The contracts, the tests, the services and the website have all
been rewritten for it. `docs/STATUS.md` is the current state, and this table deliberately does not
claim more than it says.

| Item | State |
|---|---|
| Nine contracts, governance wiring | rewritten for the access model |
| Contract tests | rewritten: unit, fuzz, invariant and reentrancy suites, run by CI on every contract change; the fork suite is run by hand against mainnet state (gate 7) |
| Adversarial security review | repeated against the access-model contracts on 2026-09-11, by one reviewer who is not the author. A model review of the whole tree on 2026-09-17 had its contract findings decided and merged on 2026-09-18. Gate 6 closed by the owner on 2026-09-25, after two model families reviewed the commits to be deployed (`docs/reviews/`) |
| Static analysis | re-run on 2026-09-24 against all nine contracts at `launch-review-5`, and on 2026-09-25 against the four watchdog contracts (`packages/contracts/SLITHER.md`) |
| Website | rewritten for the access model; live on kay9.io |
| Analysis engine, EVM and Solana adapters | written; the basic scan runs in the visitor's browser (`docs/BASIC_SCAN.md`) |
| Auditor job, quorum signing | rewritten for attestation and scale-to-zero (`services/audit-worker`), and tested; not running against mainnet |
| Continuous integration and deployment | GitHub Actions |
| Token discovery | ten verified sources on Robinhood Chain; a live pass over 20,000 blocks found 1,459 tokens in nine requests |
| `KAY9ScanRegistry` and Merkle batching | live on Robinhood mainnet since 2026-09-25 (`packages/chain/deployments/4663.json`) |
| Automatic scan pipeline | `services/discovery-worker` runs as the Azure job `kay9-scanner-run` every two hours; batch 0 committed at block 71,926,233 on 2026-09-25 (gate 1) |
| Watchdog deployment script | `DeployWatchdog.s.sol`, no token in it |
| Deep/forensic beta intake, pre-token | `beta`/`beta-api` written and tested (`services/audit-worker`) — a free, walletless queue feeding the existing `publishWatchdogReport` quorum path; not yet deployed |
| Score calibration against real tokens | re-run on 2026-09-26 on 84 tokens and a rugged set of 32 dumps and liquidity pulls; eight engine defects found and fixed in engine 1.12 (gate 4) |
| Live feed, watchdog dashboard, token pages | on kay9.io, reading the live registry |
| Documentation | in `docs/`, kept in step with the code: `docs/CONTRACT_INTERFACES.md` changes before the contracts do |

## 1. Before launch — the watchdog runs, and hardening

No token exists yet, so this phase has no deadline pressure. Do not compress it.

This is also the phase in which the watchdog goes live on mainnet and stays live: deploy
`DeployWatchdog.s.sol`, authorise a scanner, and let discovery and automatic scanning run
unattended while the hardening below proceeds. The 30 days of unattended operation that gate 1
requires can only accumulate in real time, so starting it early costs nothing and starting it late
delays everything. `services/discovery-worker` (`services/discovery-worker/deploy/README.md`) is
the job that does this — written and tested against `services/watchdog`'s existing discovery and
scan-pass logic, not yet deployed. Standing it up on a real schedule, against a real
`setScanner`-authorised key, is what starts the 30-day clock.

- **Finish the rewrite.** Done: `forge test` is green against the access-model contracts and the
  invariant suite drives the new job states. It stays first on this list because everything below
  assumes it, and a contract change reopens it.
- **Re-run static analysis and the adversarial review against the final tree.** Both were repeated
  on 2026-09-11 against the access-model contracts, `KAY9AccessVault` included. The contracts have
  changed since (2026-09-18: the hub's hard deadline, the vesting gate, the registry's second read,
  the vault's upgrade rule), and a result is about the tree it ran on.
- **Testnet rehearsal.** Run the full cycle on Robinhood testnet 46630: deploy, launch, bid from
  several accounts, end the auction, migrate, lock the position, settle the unsold supply — and
  then the access model: lock, request, attest with two auditors, dispute with three,
  expire an unanswered job, renew, and unlock the whole principal. This is scripted in
  `docs/DEPLOYMENT.md` §3 and §3.1 and needs only a funded testnet key.
- **Owner wallets.** Owner address (a single account, not a Safe), team beneficiary, creator-fee
  recipient, three auditor addresses.
  Nothing deploys until these exist and none of them may be a developer key.
- **An independent audit, if the launch valuation justifies it.** The Uniswap Liquidity
  Launcher, the Continuous Clearing Auction and Uniswap v4 are already audited by OpenZeppelin,
  Spearbit and ABDK, and KAY9 uses them as deployed rather than forking them. What is unaudited
  by a third party is the roughly 2,000 lines of KAY9 code around them. At a four-figure opening
  valuation a third-party code audit costs more than the protocol holds; above that it is
  negligence not to get one. Decide by looking at the floor and graduation figures you choose.
- **A published bug bounty.** Cheap, immediate, and it signals the right thing. Scope it to
  `packages/contracts/src`, and state the payout source honestly: the protocol has no revenue, so a
  bounty is funded by the owner or it is not funded. Do not announce one that has no source.
- **Exact unlock timestamps.** The 6 and 12 month team unlocks are calendar dates computed from
  TGE and burned into the contract at deployment. They are printed for review before signing and
  can never be changed afterwards.

**Precondition to leave this phase:** the rehearsal passed end to end, and the owner has read
the final launch report in `docs/DEPLOYMENT.md` §6.

## 2. TGE — launch week

| When | What | Who acts |
|---|---|---|
| T-7d | Deploy contracts to Robinhood mainnet, verify every one on Blockscout | owner signs |
| T-7d | Publish addresses, flip the repository public | anyone |
| T-2d | Announce the auction window and the floor and graduation figures | owner |
| T-0 | `KAY9Genesis.launch()`, auction opens | **owner signs** |
| T-0 + 4h | Auction closes, final clearing price fixed | automatic |
| T-0 + 4h | `LBPStrategy.migrate()` creates the v4 pool and mints the position | anyone |
| T-0 + 4h | `KAY9LiquidityLock.lock()` makes the liquidity permanent | anyone |
| T-0 + 4h | `KAY9Genesis.settle()` turns unsold supply into locked liquidity | anyone |
| T-0 + 4h | Team tranche 1 unlocks, 10,000,000 KAY9, 1 percent | permissionless release |
| T-0 + 4h | The Buy panel on kay9.io enables itself: it reads `launchState` 3 and quotes ETH → KAY9 through the Uniswap v4 quoter and Universal Router; the owner checks once that the Uniswap app's deep link opens the right chain and token | automatic; owner checks |

Everything after the owner's single signature is permissionless. That is the point: no step
depends on the team being alive, awake or willing.

**`NEXT_PUBLIC_ALLOW_INDEXING` is not on this table, on purpose.** It used to be tied to T-7d,
which quietly contradicted §0's whole premise — a product that has to earn attention before it
asks for money cannot also be invisible to search engines for the entire time it is doing that
(R33 in KAY9-REVIEW.md). Whether the site is ready for search engines is a question about the
product — is the live feed real, are token and report pages meaningful landing content, is nothing
thin or private exposed — and has no fixed relationship to TGE. It can be enabled before, at, or
after this table's dates, on its own evidence, the same way a `docs/LAUNCH_READINESS.md` gate
closes: on demonstrated readiness, not a calendar offset from a token event.

## 3. Weeks 1–4 — the access model and the auditors go live

The contracts ship at launch; this is turning the service on, in the order the dependencies force.

- **Confirm the lock requirements.** The vault deploys with 5,000 KAY9 for deep and 10,000 KAY9
  for forensic. There is no oracle to bind and no off-chain process to start: the requirement is a number
  stored in the vault, and if the auction's clearing price makes the defaults unreasonable the
  owner schedules `setRequirement` through the 48 hour timelock. The change is public for 48 hours
  before it applies and never touches a period that is already open. The website reads
  `requirementOf` from the vault and never hardcodes the amount.
- **Complete the vault handover.** `accessVault.transferOwnership(timelock)` runs at deployment but
  is `Ownable2Step`, so the timelock's `acceptOwnership()` is a scheduled governance call that takes
  48 hours. Until it executes the deployer key still owns the vault. This is the first thing to
  verify after launch, not the last.
- **First access locks.** The first depositor is the first real test of the claim the whole model
  makes, so watch one period end to end on mainnet: lock, spend the allowance, unlock, and confirm
  the balance came back whole.
- **Three auditors running, quorum 2 of 3**, each as a scheduled job that scales to zero, with the
  optional nudge wired from the site.
- **First deep audits.** Expect the first published report to score something badly; that is the
  product working, not a problem.
- **The browser basic scan public**, running client-side against a public RPC with no wallet and no
  KAY9.

**Known gap to close here:** the analysis engine needs an archive node to resolve token deployers
and read historical state. The public Robinhood RPC is pruned and answers a historical `eth_getCode`
with `metadata is not found`. Until an auditor runs or rents one, creator-history signals report as
unmeasured rather than clean.

## 4. Months 2–3 — reading, integrating, monitoring

- **Selling from kay9.io.** The launch-day Buy panel takes ETH in and needs no token approval. The
  reverse direction (KAY9 → ETH) needs Permit2 and an approval flow; it ships here, after the same
  review the rest of the swap path gets, and until then the panel says "to sell, use Uniswap".

The audience beyond the individual buyer is builders. This phase is about being consumable.

- **Registry integration.** `latestSummary`, `latestSummaryForToken` and `scoreHistory` already
  exist so that a wallet, DEX or launchpad can render KAY9 risk with one contract call and no
  KAY9-operated API. The work is documenting them as an integration surface, publishing a minimal
  client, and finding the first integrator. Nothing here requires a new contract.
- **Risk over time on the site.** The registry appends, so an asset has a score history rather than
  a score. Show it as a history, always with `committedAt`, and never render `latest` as current
  safety.
- **Continuous monitoring live.** The scheduled delta sweep of assets that already have a report —
  owner or admin changed, proxy implementation changed, LP position moved or unlocked, top holder
  share crossed a threshold, deployer moved funds — publishing quorum-signed alerts through
  `publishWatchdogReport` with flag bit 19 set. Nobody pays for these and nobody asked for them,
  which is the point.
- **BNB Chain** analysis live. Needs an explorer API key and an RPC endpoint.
- **Solana** analysis live: mint and freeze authority, token-2022 extensions, holder concentration.
  Engine 1.3 also reads Raydium CPMM/Orca pool state and searches bounded mint initialization
  history. Executable depth, creator reputation and historical snapshots remain open; standard RPC
  scans cannot produce pinned quorum reports.
- Registry browsing across all three chains in one view.

KAY9 itself does not bridge. Analysing a chain never requires a token on it, and no wrapped KAY9
will be created to fake presence somewhere.

## 5. Months 3–6 — depth

- **Forensic tier fully exercised.** The contracts ship with `TIER_FORENSIC` active at a 10,000
  KAY9 lock, one forensic and four deep audits per period, and `upgrade` from a live deep period. The
  work is the analysis depth behind it: deeper wallet clustering and funding-source tracing.
- **Analysis coverage.** v3 position ownership so `UNLOCKED_LIQUIDITY` becomes measurable (v4 is, since engine 1.10),
  creator-history liquidity checks, Solana AMM state decoding, and a read-only simulation path to
  turn the honeypot heuristic into a demonstrated result. `docs/WATCHDOG.md` §10 has the detail.
- **Report permanence.** Move report bodies to Arweave alongside IPFS so the on-chain hash always
  resolves. A pinned body nobody serves is a broken link with a valid hash.
- **A mirrored frontend.** The site is a static export specifically so the whole thing can be pinned
  to IPFS. Publishing that hash is the proof that kay9.io is a convenience. The basic scan runs in
  the browser, so a mirror is a fully working scanner and not a brochure.

## 6. Months 6–12 — making the auditors independent

This is the honest weak point of V1 and it is worth stating plainly, because it is a fact about the
launch configuration rather than a risk about the design.

At launch there are three signing keys, three secret stores and three identities in
`KAY9AuditorRegistry`, held by three people in three countries, but **not three independent
operators: two of the three are the project.** One key is the developer's, one is the owner's, and
the third is held by a person not otherwise involved. The platforms follow the same shape. Opening
accounts on three genuinely independent commercial clouds requires a payment card this project does
not have, so auditor A runs as an Azure Container Apps job in the owner's subscription and auditor B
as a GitHub Actions workflow in a separate repository the project also controls. A two-of-three
quorum protects against one dishonest or compromised auditor, and no single person holds a quorum.
It does not protect against the project, or against a compromise of the project's accounts, because
that is two of the three. `docs/AUDITOR_NETWORK.md` §4.3 and `docs/SECURITY.md` §2.6 say this in
full, and the website says it too.

The fix is a move, not a mechanism, and it has a precondition rather than a date:

- **Auditor B onto Google Cloud Run and auditor C onto AWS Lambda**, both of which scale to zero on
  their free tiers, as soon as either a funding method exists or independent operators volunteer to
  run them. This is the single highest-value change on this roadmap, because it is the only one that
  changes what the quorum actually guarantees.
- **Grow the auditor set past three** through the timelock, raising the threshold with it, so that a
  single platform outage or a single compromised operator matters even less.
- **Publish which platform runs which auditor** and keep it current, so that the claim can be
  checked rather than trusted.
- Team tranche 2 unlocks at TGE + 6 calendar months, 40,000,000 KAY9, taking the cumulative total to
  5 percent. Tranche 3 at TGE + 12 months brings it to 9 percent. Both are enforced by immutable
  timestamps and neither can be accelerated.

**Precondition to call this phase done:** no two auditors share an operator, an account, or a
credential store, and `docs/SECURITY.md` §2.6 can be deleted rather than reworded.

## 7. Not on the roadmap, on purpose

Listing these matters as much as the roadmap itself, because a roadmap that promises things the
contracts cannot do is a liability.

- **No presale, no private round, no IPO.** The auction is the only sale. Adding a presale would
  contradict the audit engine's own risk signals, require changing a fixed distribution, and
  give early buyers a better price than everyone else.
- **No staking rewards for holders.** The contracts mint nothing and there is no yield to pay.
  Any "rewards" claim would be paid out of somebody else's principal.
- **No governance token promises.** The 48 hour timelock is administrative safety, not a vote.
  Do not describe it as governance.
- **No additional minting, ever.** There is no mint function to call.
- **No LP withdrawal.** The position sits in Uniswap's FeeSplitter, which has no withdrawal
  path. This cannot be added later.
- **No pay-per-audit.** Not a fee, not a price per audit, not an escrow, not a treasury cut, not a
  burn of a requester's KAY9. Access is a lock and the principal comes back in full. This is not a
  decision waiting to be revisited: a per-audit fee puts the analyst on the payroll of the
  analysed, and every good score then looks bought whatever the code actually does. Reintroducing it
  would require a new `KAY9AuditHub`, and the reason not to would not have changed.
- **No yield on locked KAY9.** No APY, no reward, no emission, no share of anything, and no
  slashing. `KAY9AccessVault` mints nothing and receives nothing beyond the principal it will
  return. A lock is access, not an investment, and the moment it pays a return it becomes one.
- **No paid green badges.** There is nothing to pay. A creator can request an audit of their own
  token and score 25/100, and the report says who requested it.

## 8. Dates the owner sets

Fill these in and the relative weeks above become a calendar.

| Item | Value |
|---|---|
| Target TGE, date and time UTC | **Tuesday 10 November 2026**, set by the owner on 2026-09-11; time of day UTC to be confirmed by the owner. A target that moves if a readiness gate is open (§8.1) |
| Auction duration | 24 hours, about 864,000 blocks on the chain's own clock (owner, 2026-09-25; it was 4 hours) |
| Floor FDV, USD | to be set, reference 1,000 |
| Graduation FDV, USD | to be set, reference 10,000 |
| Team unlock, tranche 2 | TGE + 6 calendar months, computed at deployment: 10 May 2027 at the TGE time of day if TGE is 10 November 2026 |
| Team unlock, tranche 3 | TGE + 12 calendar months, computed at deployment: 10 November 2027 at the TGE time of day if TGE is 10 November 2026 |
| Deep access lock | 5,000 KAY9, changeable only through the 48 hour timelock (`setRequirement`), never below 1 KAY9 |
| Forensic access lock | 10,000 KAY9, changeable only through the 48 hour timelock (`setRequirement`), never below the deep lock, never above 10,000,000 KAY9 |
| Access period | 30 days, changeable only through the 48 hour timelock, within 7 and 365 days |

### 8.1 The calendar, working back from 10 November 2026

Set on 2026-09-11. Every line is a precondition from `docs/LAUNCH_READINESS.md` with the latest
date it can close and still leave the gate after it enough room. Nothing here is a launch-day
promise: a slipped line moves the launch, not the gate.

| By | What must be true | Gate |
|---|---|---|
| **Done** Wed 23 Sep 2026 (brought forward from 25 Sep; first set for 18 Sep) | Model review of the launch path (`KAY9Genesis`, `KAY9Token`, `KAY9TeamVesting`, `KAY9LiquidityLock`) by two model families, OpenAI GPT-5.6 Sol and Anthropic Claude Fable 5.1, both confirmed at the deploy commit `launch-review-5` and published in `docs/reviews/`. A model review of the whole tree ran on 17 Sep; deciding its contract findings moved the commit on 18 Sep, so that review is input to this line, not the evidence gate 6 asks for | 6 |
| Fri 2 Oct 2026 (slipped from 18 Sep) | Testnet rehearsal complete end to end **on a stack redeployed from the current tree**, including the renew and unlock steps, which need the 7-day minimum period to expire after the lock. The stacks rehearsed on in September predate the contract changes merged on 18 Sep (the hub's hard deadline, the vesting gate, the registry's second read, the vault's upgrade rule), so their transactions no longer show what will be deployed | 8 |
| **Done** Thu 25 Sep 2026 (was Fri 2 Oct) | Both model families' reviews of the **watchdog stack** run at the commit to be deployed (`KAY9AuditorRegistry`, `KAY9ScanRegistry`, `KAY9Registry`, `KAY9AuditHub`, and the timelock wiring in `DeployWatchdog.s.sol`), every finding fixed or accepted in writing, Slither re-run. These contracts are as immutable as the token's and go to mainnet a month earlier: a finding after 9 Oct is not a patch, it is a redeploy and a new 30 days | 6, 7 |
| **Done** Fri 25 Sep 2026 | Owner address, team beneficiary, creator-fee recipient and three auditor addresses exist; the auditor keys are held by three people in three countries and prove control; signatures in `docs/LAUNCH_READINESS.md` gates 10 and 11 | 10, 11 |
| **Done** Thu 25 Sep 2026 (was Fri 9 Oct) | Watchdog live on mainnet: `DeployWatchdog.s.sol` broadcast, scanner authorised, `services/discovery-worker` committing batches unattended. This is the latest start that gives 30 days before launch | 1, 2 |
| **Done** Thu 25 Sep 2026 | Every number on kay9.io traced to its source (`docs/reviews/2026-09-25-gate5-sweep.md`); run again in the launch week | 5 |
| **Done** Sat 26 Sep 2026 (was Fri 16 Oct) | Calibration re-run against 50+ tokens including 10 known rugs, published: 84 tokens and a rugged set of 32, engine 1.12 (`docs/SCORE_CALIBRATION.md`) | 4 |
| **Done** Thu 24 Sep 2026 (was Fri 23 Oct) | Every launch-path review finding fixed or accepted in writing; suites green; Slither and fork suite re-run against the final tree (`launch-review-5`). Gate 6 closed for the launch path by the owner on 25 Sep | 6, 7 |
| Sun 25 Oct 2026 (was Sun 8 Nov) | Gate 1's 30 unattended days complete, counted from batch 0 on 25 Sep at block 71,926,233, provided no gap exceeds six hours unexplained | 1 |
| Fri 30 Oct 2026 | Third party reconstructs the scan record from the batch documents; diff against kay9.io empty | 3 |
| Mon 2 Nov 2026 | Site sweep: every figure traces to a chain read or a stated measurement | 5 |
| Tue 3 Nov 2026 | Mainnet token deployment (`Deploy.s.sol` against the live watchdog's timelock, registry and hub), Blockscout verification, `acceptOwnership` and `setAccessVault` scheduled on the 48 h timelock | 12, 13 |
| Thu 5 Nov 2026 | Timelock operations executed; `owner()` checks pass everywhere | 12 |
| Fri 6 Nov 2026 | Launch parameters derived, printed and confirmed by the owner in writing; auction window announced | 9 |
| Mon 9 Nov 2026 | Owner confirms gates 1–13 closed in writing | 14 |
| **Tue 10 Nov 2026** | `KAY9Genesis.launch()` signed; auction runs 24 h; migrate, lock and settle are permissionless afterwards | — |

What is *not* on this calendar is anything that depends on money the project does not have: the
independent-operator move in §6 has a precondition, not a date, and stays that way.

## 9. How this document stays honest

Every dated claim here is either a contract constant, a value the owner sets before signing, or
a piece of work with its precondition named. When a phase slips, the date changes and the reason
is written down. Nothing moves from §7 into the roadmap without a contract change, an audit and
a note explaining what changed and why.
