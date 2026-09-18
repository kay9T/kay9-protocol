# The KAY9 auditor network

Three auditor identities, a two-of-three quorum, and no server that has to stay awake. This
document specifies how an audit request becomes a signed result on-chain, what each auditor
independently recomputes, where the code runs, and what the arrangement does **not** guarantee.

The contracts are `KAY9AuditHub` and `KAY9AuditorRegistry`. The worker is
`services/audit-worker`. The analysis engine is `services/watchdog`.

## 1. The shape of it

```
requester -> KAY9AuditHub.requestAudit          (on-chain; quota checked in KAY9AccessVault)
             AuditRequested(jobId, chainKey, assetId, tier, ...)
                |
                +--> auditor A   independent analysis, pinned to job.requestedAt
                +--> auditor B   independent analysis, pinned to job.requestedAt
                +--> auditor C   independent analysis, pinned to job.requestedAt
                |
             each signs an EIP-712 AuditResult and calls KAY9AuditHub.attest
                |
             first result to reach threshold votes finalises
                |
             KAY9Registry.recordReport    (append-only, never overwritten)
```

Nothing in that path requires a KAY9-operated API, and nothing requires kay9.io. The request is a
transaction, the authorisation is a contract read, the result is a transaction, and the history is
a public array.

## 2. Why the analysis is reproducible

A two-of-three quorum only means something if two honest analyses, run separately, arrive at the
same answer without talking to each other. Most risk analysis is not like that: it involves
thresholds, heuristics and floating point, and two honest implementations will disagree in the
last digit. So the protocol makes agreement structural rather than hopeful.

**The point of reference is chosen by the chain, not by the auditors.** There is nothing to
negotiate and no clock skew: all three read the same historical state. This single decision is
what makes the rest possible. It takes two forms, because one rule does not cover every case.

- **A requested audit, on any chain**, is analysed as of `job.requestedAt`, the job's timestamp,
  which the hub writes into the job when the request lands. The timestamp is chain-agnostic, so the
  rule is identical whether the asset is on Robinhood Chain, BNB Chain or Solana: each auditor's
  adapter resolves it to that chain's own block with a deterministic binary search
  (`blockAtTimestamp`), landing on the same height without talking to each other.

  This is deliberately the timestamp and not `job.requestedBlock`, even though since 2026-09-11 the
  hub stamps that field from the chain's own height (`ArbSys.arbBlockNumber()`) rather than from
  `block.number`, which on this Orbit chain is the parent chain's and was never a height any RPC
  call here accepts (R01 in KAY9-REVIEW.md). A block number is only meaningful on the chain that
  produced it; a timestamp means the same thing on every chain an audited asset can live on, so one
  rule covers every case. The pin is final only once the target chain has moved past
  `requestedAt`: the adapter refuses to analyse — and the worker retries on its next wake — while
  the chain head is still inside that second, because this chain stamps about ten blocks with the
  same one-second timestamp and two auditors running inside it would otherwise resolve to two
  different heights and never agree.
- **An unsolicited monitoring report** has no job and therefore no request timestamp at all, so the
  auditors need a rule they can each apply without talking. The rule is: take the chain head, step
  back `MONITOR_BLOCK_LAG` blocks so reorganisations have settled, then round down to a multiple of
  `MONITOR_BLOCK_GRID`. Three auditors sweeping minutes apart land on the same number, **provided
  the grid is wider than the gap between their invocations** — Robinhood Chain measures at 0.1012
  seconds a block (`docs/RESEARCH.md`), so "minutes apart" is thousands of blocks, not the "few"
  an earlier version of this default assumed. **All three must be configured with the same lag and
  grid**, and a mismatch shows up as a monitoring report that can never reach quorum rather than as
  an error, so it belongs in the deployment checklist. The defaults are a lag of 64 blocks and a
  grid of 18,000 (about 30 minutes) — comfortably past the deployed schedule's six-minute offset
  between Azure and GitHub Actions plus the dispatch jitter either platform can add on top of it.

**The deterministic core is recomputed by all three, in full.** These signals are pure functions of
chain state at a fixed block, so three honest auditors must produce byte-identical output:

- token metadata, decimals, total supply
- mint, freeze, pause and blacklist capability, derived from bytecode and from the ABI surface
- proxy detection and the implementation slot, admin and owner
- owner and admin privileges, and whether any of them can alter transfers
- transfer-fee logic and whether it is mutable
- liquidity pool discovery, reserves and whether the LP position is locked or withdrawable
- holder balances, folded from the complete `Transfer` log, and the resulting concentration
- the deployer, the deployment block, and the deployer's other deployments
- the early-buyer window: which addresses bought in the first blocks and what share they took

**The probabilistic layer is quantised.** Wallet clustering, Sybil scoring, wash-trading
likelihood, insider-group detection and creator fingerprinting are not bit-reproducible even
between honest implementations. Each of those emits a score rounded to the nearest 5 and a flag
bit, never a raw float. Rounding to a coarse grid is what lets three independent computations agree
on a value without coordinating on one, while still being three independent computations. Where a
heuristic is genuinely uncertain, it sets `INSUFFICIENT_DATA` rather than guessing, and a signal
that could not be measured is reported as unmeasured rather than as clean.

**The report body is canonical bytes.** The off-chain report is serialised as canonical JSON with
sorted keys and fixed number formatting, so `reportHash = keccak256(body)` is identical across
auditors, and pinning it to IPFS yields the same content identifier from all three. Two auditors
that agree therefore produce the same `reportURI` as well as the same score, and a reader can fetch
the body from any of them and verify it against the chain.

This answers the cost question honestly. Full independent recomputation three times is affordable
here because the work is bounded, the inputs are pinned, and the expensive part is log retrieval
rather than computation. Nothing is signed by an auditor that the auditor did not compute.

## 3. Disagreement is not hidden

Each auditor takes at most one position per job. `attest` records it, and the hub tracks how many
auditors hold each distinct result.

- The moment one result reaches `auditors.threshold()` votes, the job finalises against it. The
  holders of that position are re-checked against the active auditor set first, so an operator
  removed through the timelock cannot carry a job over the line on a vote cast beforehand.
- The job becomes `Disputed` the moment agreement is arithmetically impossible, which with three
  auditors and a threshold of two means three mutually different results.
- Contradictory scores are **never** averaged. There is no mean, no median and no tie-break that
  invents a number nobody signed.
- A disputed job restores the requester's quota unit, and the conflicting positions stay readable
  per auditor through `attestationOf`. Anybody can see which auditor said what.

The ordinary case costs one transaction: whichever auditor goes second submits the first one's
agreeing signature together with its own. An auditor that disagrees pays for its own transaction to
say so. That asymmetry is intentional; dissent should be cheap enough to be free of friction but it
is not the common path.

**Only an auditor may submit.** `attest` and `publishWatchdogReport` refuse a caller that is not in
the active auditor set. The signatures do not cover `reportURI` — three auditors pinning identical
bytes to three backends must still agree — so whoever lands the finalising transaction chooses the
pointer the registry records forever. The signature relay (§4.1) is readable by anyone, so an open
submit path would have let a stranger race the auditors with a pointer of their choosing. The hash
still binds the body, so a score can never be changed this way; what the gate removes is a permanent
dead link written by somebody with no key. The worst case left is one of the three operators, and
`msg.sender` names them.

An auditor batching signatures has to check first. `attest` reverts the **whole** call with
`AlreadyAttested` if any signer in the batch already holds a position, so a relay that blindly
includes a peer's signature takes its own attestation down with it. The worker reads
`attestationOf` for each peer before batching and falls back to a single-signature call. That is a
property of the contract worth stating rather than a quirk of one implementation: the contract is
deliberately strict, because silently ignoring a duplicate signature would make the vote count
depend on submission order.

A job nobody answers within the service level, six hours by default, can be expired by anyone,
which also restores the quota.

## 4. Where the code runs

The requirement is scale-to-zero: when nobody has requested an audit, the audit infrastructure
should cost nothing and run nothing. There is no VPS fleet, no full node to maintain, and no
always-on process anywhere in this design.

Each auditor is a stateless job. It wakes, reads the chain, analyses, signs, submits, and exits.
Its only durable state is a cursor recording the last block it scanned, and losing that cursor
costs a re-scan, not a wrong answer.

### 4.1 How a job is triggered

There is no third-party blockchain webhook service for Robinhood Chain, so the trigger is a
**scheduled poll plus an optional nudge**:

- **The poll is the guarantee.** Every auditor wakes on a schedule, reads `AuditRequested` logs
  since its cursor, and processes anything it has not already signed. At a five minute cadence
  against a six hour service level, a missed nudge costs latency and nothing else. Polling an
  `eth_getLogs` range costs one RPC call per wake.
- **The nudge is the latency optimisation.** After a request confirms, the browser may call a small
  trigger endpoint per auditor. That endpoint takes a job id, verifies the job on-chain itself, and
  starts the analysis. It trusts nothing the caller says: an invented job id finds no job and does
  nothing, and a replayed nudge for a job already signed is a no-op.

The nudge is never required for correctness. Turn kay9.io off and every request is still served,
just up to five minutes later.

The same public endpoint throttles by source address, and it throttles datacentre egress far harder
than it throttles a residential connection: the identical holder fold that fails from a container
completes from a laptop. That is one more reason basic scan belongs in the visitor's browser, where
the rate limit is per visitor rather than one shared bucket, and one more reason the auditors need
their own endpoint rather than the public one.

### 4.2 Idempotence

Two triggers for the same job must not produce two attestations. Before signing, an auditor checks
`attestationOf(jobId, self)` on-chain; if it is already set, the job is done for that auditor. The
check is on-chain rather than in the worker's own storage precisely so that a lost cursor, a
duplicate event, a retry, a cold start or a second concurrent invocation cannot double-sign. A
transaction that reverts with `AlreadyAttested` is treated as success.

### 4.3 The deployment, and what it honestly is

Two constraints decide this, and both are hard numbers rather than preferences.

**The whole Azure budget for KAY9 is 100 MYR a month**, about 21 to 22 US dollars, covering
everything: the website, the auditors, and any service added later. **And the owner will not use a
credit card**, which rules out AWS and Google Cloud entirely, since both require one to open an
account even for their always-free tiers.

Prices below are from the Azure retail API for `southeastasia`, read rather than remembered.

| | Cost | Verdict |
|---|---|---|
| Container Apps, scale-to-zero job | inside the monthly free grant of 180,000 vCPU-seconds and 2M requests | fits |
| Container Apps, one always-on 0.25 vCPU replica | about $5.73/month | a quarter of the budget, idle |
| Container Registry Basic | $0.1666/day, about $5.06/month | do not use; `ghcr.io` is free |
| B1s virtual machine | $0.0132/hour, about $9.64/month plus disk | half the budget for one box |

Scale-to-zero is therefore not an architectural preference here. It is the only shape that fits.
One idle container would consume a quarter of the budget for the privilege of doing nothing.

**At launch:**

| Auditor | Platform | Idle cost | Trigger |
|---|---|---|---|
| A | Azure Container Apps job, in the owner's existing subscription | zero when not running | cron plus HTTP nudge |
| B | GitHub Actions scheduled workflow, in a separate repository | zero | `schedule` plus `repository_dispatch` |
| C | a third key, held by the third person named below, in a store separate from A and B, run as its own scheduled job | zero when not running | cron plus HTTP nudge |

Three signing keys, three secret stores, three identities in `KAY9AuditorRegistry`.

**Who holds them, as of 2026-09-16.** One key is the developer's. One is the project owner's. One is
held by a third person who is not otherwise involved in the project. The three are in three
countries. The project does not publish their identities, so a reader cannot check any of that
sentence — it is the project's statement about itself and is written here as one.

**Two of the three are the project.** The developer and the owner are both inside it, and the
threshold is two, so the project can still produce any result the contracts will accept without the
third holder waking up. The third vote can never decide anything on its own. So this arrangement is
**not** protection against the project, and nothing on the website may suggest that it is. What
changed on 2026-09-16 is that no single person holds a quorum, which is a smaller claim and a true
one.

**What the quorum does do**, precisely: a single leaked key cannot commit a result on its own, and a
single lost key does not stop the protocol, because removing an auditor lowers the threshold with
it. The arrangement is only as strong as its two weakest keys, so each belongs in a different store
with a different way in, and the key that signs governance belongs on hardware, held by a person,
rather than in a job.

**What a reader can check**, without taking anything on trust: every report names its signers, so
the distribution of signatures over time is public; and the funding of the three auditor addresses
is visible on chain. Today that funding is central — gas for all three comes from the project's
deployer account, because two of the holders are not being asked to pay for the project's costs.
Anyone auditing this will see one address paying for three auditors, and should read it as exactly
what it is rather than as evidence of anything hidden.

**The real protection is elsewhere, and it always was.** If the record is reproducible — run the
engine at the block the chain chose and get the same bytes — then a wrong verdict is detectable by
anyone, whoever signed it and however many of them there are. That is gate 3 of
`docs/LAUNCH_READINESS.md`, and it is worth more than the operator count.

This ends being a limitation when two of the three keys are held outside the project, not when the
code changes.

**The subscription can be suspended, and that takes the website with it.** The Azure subscription
is `MSDN_2014-09-01` with the spending limit **on**, so overspending cannot produce a bill. It
produces something worse for a project like this: when the monthly credit is exhausted, Azure
suspends the whole subscription, and the Static Web App serving kay9.io lives in it. An auditor
that runs away with a loop therefore does not cost money, it takes the site down. Every scheduled
job must bound its own work per invocation, `max-replicas` stays at 1, and the budget alert is not
optional.

**As soon as it is possible**, meaning when either a funding method exists or independent operators
volunteer, B moves to Google Cloud Run and C to AWS Lambda, both of which scale to zero on their
free tiers, and the auditor set grows past three through the timelock. `docs/ROADMAP.md` carries
this as the operator-decentralisation phase rather than as a footnote.

Cloudflare Workers were considered and rejected for the analysis itself: the free plan needs no
card, but the CPU limit makes a full log fold impossible. It remains a candidate for the nudge
relay, which is a few milliseconds of work.

### 4.4 What each auditor needs

- an RPC endpoint per analysed chain, and for creator history an **archive** endpoint. The public
  Robinhood mainnet RPC is pruned, measured rather than assumed: a historical `eth_getCode` answers
  `metadata is not found`. It also caps `eth_getLogs` at 10,000 matched logs per query, so a holder
  fold over an active token is 30 to 40 sequential calls rather than one
- a signing key, held in the platform's secret store, used for nothing else
- a small amount of ETH on Robinhood Chain for gas
- an IPFS pinning credential

Until an operator has archive access, creator-history signals report as unmeasured. The engine
already does this rather than reporting them as clean; see `docs/WATCHDOG.md`.

**A separate, still-open determinism gap: the deployer's *other* deployments (`EVM_CREATOR_SERIAL_DEPLOYER`
and its neighbours) need an explorer API, not just an archive RPC, and score real points when they
fire — up to 40 for creator risk (R04, R10 in KAY9-REVIEW.md).** An auditor without an explorer
configured never resolves this signal at all; one with an explorer, querying the identical pinned
state, can. Two honest, independently-run auditors can therefore land on genuinely different
creator-risk scores for the same asset, not merely different report bytes — quantising the
probabilistic layer does not help, because the gap is the signal's presence, not its precision. The
raw explorer observations that used to leak this operator's own configuration into the hashed
report body are gone (R04, fixed), which closes the purely cosmetic half of the problem, but the
scoring half remains: until every production auditor is provisioned with equivalent explorer
access — an operational requirement, not a code fix — or this signal is moved out of consensus
scoring entirely, forensic-tier quorum on a token with real creator history is not guaranteed to
form. Track this against `docs/LAUNCH_READINESS.md`'s reproducibility gates before relying on it.

**A dedicated RPC endpoint does not fit the budget.** Paid providers start around 20 to 50 dollars
a month, which is the whole 100 MYR or more, before anything else runs. So auditor A on Azure will
meet the same datacentre rate-limiting measured above, and the browser trick that rescues the basic
scan does not help it: a server has no residential address to borrow. The honest options, in the
order they should be tried, are to find a free-tier endpoint that tolerates datacentre egress, to
have the owner run a node outside Azure, or to accept that the holder fold degrades on the paid
tiers and report the affected signals as unmeasured. The third is survivable and already the
engine's behaviour, but it should be a decision rather than a discovery, because a deep audit whose
holder concentration is unmeasured is worth materially less than one whose is not, and the product
must not charge a lock for it without saying so.

## 5. Continuous monitoring

An audit is a snapshot. Risk moves, so the registry keeps every snapshot and the network keeps
looking.

A scheduled sweep, on the same scale-to-zero footing, walks assets that already have a report and
runs a cheap delta check: has the owner or admin changed, has the proxy implementation changed, has
the LP position moved or unlocked, has a top holder's share crossed a threshold, has the deployer
moved funds. Those are all direct reads and cost almost nothing.

When a delta is material, the auditors run a full analysis and publish through
`publishWatchdogReport`, which appends a quorum-signed report with no job and no requester. Nobody
paid for it and nobody asked, which is what makes KAY9 a watchdog rather than a vendor. Reports
that supersede an earlier one set flag bit 19.

A monitoring report **inherits the depth of what it supersedes**, and this needs saying because the
registry does not record it. A watchdog report is written with `tier` zero, since nobody requested
it and no allowance was spent, and zero is also the value of the basic tier. An implementation that
reads the depth back out of the registry would therefore re-analyse a forensically audited asset at
basic depth and publish a shallower report as though it superseded the deeper one. The rule is to
take the greatest tier across all of an asset's records and never to read a zero as basic — **within
the records one sweep's rotation window actually holds**, which is the honest scope of what a
paginated walk over `getReports` can see in one invocation, not literally every record an asset has
ever had (R16 in KAY9-REVIEW.md). A forensic audit that has scrolled out of the current window and a
later monitoring report both exist permanently in the append-only history, but a sweep that only
sees the recent one in isolation has no way to notice the older, deeper one without a persistent
per-asset index this service does not keep. The same bound applies to which record is "latest": it
is the newest one *this window* holds, not necessarily the newest that exists.

Because the registry appends, the result is a genuine history: an asset that scored 89 in September
and 42 in October has both records, both signed, both permanent. No surface may render the latest
score without its `committedAt`, and none may describe an old audit as current safety.

## 6. Open, and proprietary

| Open and verifiable | Proprietary |
|---|---|
| every contract | wallet-clustering heuristics |
| the request and quota protocol | Sybil and insider-group detection |
| the result schema and the flag bitmask | creator fingerprinting |
| EIP-712 signature construction and verification | advanced wash-trading models |
| the registry and its whole history | cross-chain identity correlation |
| the access vault and its arithmetic | |
| the deterministic core of the analysis | |
| the canonical report format | |

The split is drawn so that **everything needed to check a result is public** and only the detection
models that constitute the competitive advantage are not. A reader can always fetch the report,
verify its hash against the chain, see which auditors signed, see the pinned block, and recompute
every deterministic signal themselves. What they cannot do is reproduce the clustering model.

A proprietary heuristic that cannot be checked is therefore never allowed to be the sole basis of a
claim. Every flag the report raises must cite the on-chain facts that support it, and the report
format enforces this: a flag with no evidence array is invalid.

**One flag is specified but not yet set, and the reason is worth recording.** Flag bit 18 says the
auditors proved on-chain that the requester is the asset's deployer, which is what turns a token
creator's self-declaration from a claim into a fact. Setting it means resolving the deployer, and
resolving the deployer means reading historical state, which needs an archive endpoint the budget
in §4.3 does not currently stretch to. So until an operator has archive access, a creator-requested
audit is rendered as declared and unverified, everywhere, without exception. That is the correct
behaviour rather than a stopgap: the alternative is a badge saying "verified creator" that was
never verified.

## 7. What this network does not claim

- It does not claim a token is safe. `KAY9 Audit Completed` and `KAY9 Technical Risk` are the
  permitted phrasings; `KAY9 Verified Safe` is not, anywhere, ever.
- It does not claim intent. A report describes what the code can do and what the wallets did. It
  does not accuse anyone of fraud, and language asserting criminality is out of scope for the
  engine's output.
- It does not claim a score is current. It claims a score was true of a named block.
- It does not claim three-way platform independence at launch. See §4.3.
