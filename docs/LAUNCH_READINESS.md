# Launch readiness

The conditions under which $KAY9 may be launched, and the evidence required for each.

This document exists to make one decision hard to take casually. The product goes live first and
the token goes live later, and "later" has to mean something checkable rather than "when we feel
like it". Everything below is a gate: a stated condition, the evidence that settles it, and who
signs off.

**Nothing here authorises anything.** The mainnet launch is signed and broadcast by the project
owner, from wallets the owner controls, after the owner has read this document filled in. No
automated process, no CI job and no assistant may do it. `Deploy.s.sol` refuses to run against
mainnet without an explicit `MAINNET_CONFIRM=I_AM_THE_OWNER`, and that is a speed bump, not the
authorisation.

---

## 0. Status

| | |
|---|---|
| Gates passed | **3 of 14**: 6 (model review), 10 (owner key), 11 (auditor keys). Gate 1 is running (day 0 = 2026-09-25); gate 7's Slither and fork-suite halves were green on 2026-09-11 but predate the 2026-09-18 contract changes, so both are run again against the final tree |
| Watchdog live on mainnet | **yes**, since 2026-09-25 (batch 0 at block 71,926,233; addresses in `packages/chain/deployments/4663.json`) |
| Token launch | **blocked** — gates 1–14 |
| Target launch date | **Tuesday 10 November 2026**, set by the owner on 2026-09-11. A target, not an authorisation: if any gate is open on the date, the date moves. The working calendar is `docs/ROADMAP.md` §8.1 |
| Testnet rehearsal (gate 8) | executed on 2026-09-11 on the clock-fixed contracts through launch, bids, graduation, migration, governance, the oracle warm-up, the exits and claims, the lock, a settled audit, a disputed audit and the stale-feed path; `markExpired` and `upgrade` the same day; `renew` and `unlock` executable from 2026-09-18 when the 7-day period expires. Two findings came out of it (`docs/STATUS.md` §1.8, §1.9), one a site fix already shipped. Transaction hashes in `docs/STATUS.md` §12. **Every stack rehearsed on predates the contract changes merged on 2026-09-18** (`KAY9AuditHub`'s hard deadline, `KAY9TeamVesting`'s launch gate, `KAY9Registry.latestSnapshot`, `KAY9AccessVault.upgrade`), so the gate needs a redeploy and another run before it can close; the September hashes stay as the record of what those runs found |
| Last reviewed | 2026-09-25 |

Update this block when a gate closes. A gate is closed by evidence, not by intention.

---

## Part A — the watchdog must be live and useful first

The premise of the whole plan is that KAY9 earns attention before it asks for money. These gates
are what "earned" means.

### Gate 1 — the watchdog runs on mainnet, unattended, for 30 days

**Condition.** `KAY9ScanRegistry` deployed on chain 4663, a scanner authorised, and batches
committed continuously for 30 days with no manual intervention.

**Evidence.** `batchCount()` on the deployed registry; the block of the first and most recent
commit; a list of any gaps longer than six hours with an explanation for each.

**Not evidence.** A testnet run. A run somebody restarted by hand every morning.

**Status (2026-09-25): running; the 30 days started.** `KAY9ScanRegistry`
`0x79778723c021386F3C7727289A30716edaa635A1` on chain 4663, scanner `0xeaA9…Bda6` authorised in the
constructor, and the Azure job `kay9-scanner-run` committing every two hours. First batch: batch 0,
block 71,926,233, 10 scans, document on IPFS, all 10 proofs verified against the root on chain. The
gate can close 30 days after that commit if no gap exceeds six hours unexplained.

### Gate 2 — the record covers what people actually buy

**Condition.** Every graduation on the chain for 30 days has a basic scan committed within three
hours of the graduation event.

*Changed by the owner on 2026-09-25 from one hour.* One hour would need a pass every hour and about
twice the gas. Measured the same day, the chain produced 8 graduations in three hours of chain time
(against 552 new pools and 1,133 launches), and graduations head the scan queue, so every pass takes
all of them first. The job runs every two hours with 17 scans a pass, about the same daily volume as
every three hours with 25, so the worst case is about two hours and a quarter: two hours to the next
pass, a 2,000-block reorg lag of about three and a half minutes, and the pass itself.

**Evidence.** Count of `PoolGraduated` events in the window against count of matching
`AssetScanned` entries, and the distribution of the delay between them. Misses listed individually.

**Why it is a gate.** A watchdog that misses the tokens people can buy is not a watchdog. Coverage
of the launch firehose is explicitly *not* required — see `docs/TOKEN_DISCOVERY.md` §1.

### Gate 3 — the record is rebuildable by somebody else

**Condition.** A third party, given only the chain and the batch documents, reconstructs the same
feed KAY9 shows.

**Evidence.** A written procedure someone outside the project followed, and the diff between their
reconstruction and kay9.io — which must be empty.

**Why it is a gate.** If the site is the only place the data exists, every claim on it is
unverifiable and the token is being sold on trust.

### Gate 4 — the calibration is re-run and published

**Condition.** `docs/SCORE_CALIBRATION.md` re-run against at least 50 tokens spanning graduated,
fresh, stablecoin, RWA and at least 10 tokens known to have rugged.

**Evidence.** The updated document, including every false positive found and what was done about
it, and an explicit false-negative discussion for the rugged set.

**Why it is a gate.** The current calibration is four tokens. It found three systematic defects,
which is a good sign about the method and a bad sign about how much has been checked.

### Gate 5 — no invented statistics anywhere

**Condition.** Every number on kay9.io traces to a chain read or a stated measurement.

**Evidence.** A sweep of the rendered site listing each figure and its source. Any figure that
cannot be traced is removed before launch, not explained.

---

## Part B — the contracts

### Gate 6 — model review of the launch path

**Changed on 2026-09-16, by the owner.** This gate used to require review by a human who did not
write the code. Several firms and communities were approached; all of them quoted a fee the project
cannot pay, and the owner decided not to spend on one. The gate is therefore now what the project
will actually do, rather than a standard it was never going to meet. Pretending otherwise, or
leaving a gate open forever as decoration, would be worse than saying this plainly.

**Condition.** `KAY9Genesis`, `KAY9Token`, `KAY9TeamVesting` and `KAY9LiquidityLock` reviewed by at
least two large language models from **different families**, at the commit that will be deployed.
Different families is the load-bearing part: two runs of the same model share the same blind spots,
and part of this code was written by one of them, so a review by that same model is not a second
opinion on it.

**Changed on 2026-09-23, by the owner: which families count.** The code was written with many model
families, not one, so no family is independent of it by authorship, and excluding the family that
happened to write the most would not buy the independence the rule was after. What the gate keeps
is the load-bearing part: the two reviews come from **different families from each other**, each
starts with no context on the project, and each reads only the tagged commit. The reviews are
GPT-5.6 Sol (OpenAI) and Claude Fable 5.1 (Anthropic).

**Evidence.** Each review published in full — the model and its version, the date, the commit, what
was in scope, and every finding. For each finding either a fix with its commit or a written reason
for accepting it. What a review did **not** cover is published with it.

**What this gate is not, and what must never be claimed.** This is not a professional audit. No firm
is accountable for it, nobody carries liability for a miss, no fuzzing campaign ran for weeks, and no
human outside the project has read the launch path. The word "audited" is not used about KAY9
anywhere on the site or in these documents, for the same reason the protocol refuses to say
"verified safe" about anybody else's token: a reader would hear a guarantee that does not exist.
What may be said is exactly what happened — reviewed by named models, on a date, with the output
published.

**This gate closing does not make the contracts safe.** It makes what was done visible.

**Extended on 2026-09-18: the watchdog stack is reviewed before it is deployed, not before the token
is.** `DeployWatchdog.s.sol` puts `KAY9AuditorRegistry`, `KAY9ScanRegistry`, `KAY9Registry` and
`KAY9AuditHub` on mainnet about a month before the token, because gate 1 needs its 30 days, and they
are exactly as immutable as the launch path. The same condition and the same evidence apply to them,
and have to be met before *that* deployment. A finding in one of them afterwards is not a patch: it
is a redeploy, every scan committed to the old registry answers to a contract nothing points at, and
gate 1's clock starts again. `docs/ROADMAP.md` §8.1 dates this ahead of the watchdog's deployment.

**Status (2026-09-25): closed by the owner for the launch path.** GPT-5.6 Sol (OpenAI) and Claude
Fable 5.1 (Anthropic) each reviewed the launch path in a fresh session; the fixes were verified by
GPT-5.6 Sol and Claude Opus 5.5, and both confirmed the final commit `launch-review-5`
(`41e30ecd`). Every review, verification and confirmation is published verbatim with a disposition
for each finding in `docs/reviews/`, and the OpenAI thread is public on ChatGPT. The owner
reviewed what is accepted there and closed the gate for the launch path on 2026-09-25.

**Watchdog stack (2026-09-25): closed by the owner.** GPT-5.6 Sol (OpenAI) and
Claude Opus 5.5 (Anthropic) reviewed `KAY9AuditorRegistry`, `KAY9AuditHub`, `KAY9Registry`,
`KAY9ScanRegistry` and `DeployWatchdog.s.sol` at `watchdog-review-1`; three fix rounds followed, and
both confirmed the result for deployment. The commit to deploy is `watchdog-review-4` (`a71cb5c6`).
Slither found nothing new there. Every review and confirmation is published verbatim in
`docs/reviews/`. The owner closed this part of the gate on 2026-09-25, so gate 6 is closed in full.

### Gate 7 — the full suite passes, including the parts that are inconvenient

**Condition.** Contracts, chain package, watchdog and web suites green; Slither clean or every
finding triaged in writing; the fork test run against mainnet state from the launch week.

**Evidence.** CI run id, Slither output with triage notes, fork test output.

### Gate 8 — the testnet rehearsal is complete end to end

**Condition.** On chain 46630: bid → graduate → migrate → lock → lock access →
request → attest → dispute → expire → renew → unlock, every step executed and observed. There is
no oracle to bind: the access requirement is a fixed KAY9 amount stored in the vault.

**Evidence.** Transaction hashes for each step and the resulting on-chain state.

**A rehearsal is evidence about the contracts it ran on.** When a contract in the rehearsed path
changes afterwards, the steps it touches are run again on a redeployed stack; hashes from the old
one are kept as history and close nothing.

**Why it is a gate.** The single most expensive error in this project so far — a block-number
convention wrong by a factor of 120, which would have made the documented four-hour auction
impossible to submit — was invisible to unit tests and to a mainnet fork. Only a real deployment on
the real chain showed it.

### Gate 9 — the launch parameters are computed, checked and signed off

**Condition.** Floor FDV, graduation FDV, auction duration in blocks, claim block and migration
block all computed and confirmed by the owner.

**Evidence.** `Launch.s.sol --json` output, and the owner's written confirmation of each figure.

**Watch the clock.** Auction windows are counted on the clock the auction reads, which on this
Arbitrum Orbit chain is `ArbSys.arbBlockNumber()` — the chain's own height, about every 0.1 s —
and **not** the `block.number` a contract sees, which is the parent chain's and advances about
every 12 s. The planned 24 hours is **864,000** blocks. `KAY9Genesis.chainBlockNumber()` returns the clock
it validates against; `Launch.s.sol` derives from it. `docs/RESEARCH.md` has both measurements and
the testnet launch that was over before its first bid because the other clock was used.

---

## Part C — custody and keys

### Gate 10 — every production address is the owner's

**Condition.** The owner address, team beneficiary, creator fee recipient, treasury and deployer are all
controlled by the project owner. None is a developer address, and none is an address that has ever
appeared in a transcript, a log or a commit.

**Evidence.** Each address and who holds it.

**There is no multisig.** The owner decided on 2026-09-16 that the owner address stays a single
externally owned account. What that costs is worth stating rather than discovering: that one key is
the timelock's only proposer and executor, the owner of `KAY9Genesis`, the team vesting beneficiary
and the creator-fee recipient. Lose it and governance, the 90 M team allocation and the fee stream
are gone at once, with no recovery path in any contract. A Safe would have survived losing one key
and could have added signers later; an account cannot. Nothing on the website may describe the owner
as a Safe or a multisig.

**This is the non-negotiable one.** No developer, contractor or assistant may be configured as
token owner, treasury, team beneficiary, creator fee recipient, LP beneficiary, production deployer
or production cloud owner. If any address is uncertain, the launch does not proceed.

**Status (2026-09-25): owner key proven.** The owner address
`0xD75F06091CCc53Aa4cC499C6D3AdBa66fF6f95d3` is also the team beneficiary and the creator-fee
recipient. Its holder signed "KAY9 gate 10: I hold the owner key … myself. 2026-09-25"
([Etherscan 339091](https://etherscan.io/verifySig/339091)), checked independently with
`cast wallet verify`. The deployer `0x2A83A3d8B3150f13E88213A60c5764aDEcEc1984` was supplied by the
owner and proves itself when it broadcasts the deployment.

### Gate 11 — the auditor keys exist and are held separately

**Condition.** Three auditor keys, held by three parties, none of which is the deployer. The
quorum threshold matches what `Deploy.s.sol` will be given.

**Evidence.** The three addresses, who holds each, and a signed message from each proving control.

**Status (2026-09-25): met.** Each holder signed "KAY9 gate 11: I hold the auditor key … myself.
2026-09-25" from their own wallet on their own machine, at the same time over a video call. Each
signature was checked independently with `cast wallet verify`. The threshold is 2, which is what
`Deploy.s.sol` will be given.

| Key | Address | Holder | Proof |
|---|---|---|---|
| A | `0x15eF6E1AA03F94d4406DE7d3c740695e91a7539A` | the developer | [Etherscan 339092](https://etherscan.io/verifySig/339092) |
| B | `0xAde40808C319a12C79fE1b93f8F36ee0DA5DBB2d` | the owner or the third holder | [Etherscan 339093](https://etherscan.io/verifySig/339093) |
| C | `0xC629eA2d6f41832d720C762e4252aF710EE4c379` | the owner or the third holder | [Etherscan 339094](https://etherscan.io/verifySig/339094) |

### Gate 12 — the timelock actually holds what it should

**Condition.** After deployment, the 48-hour `TimelockController` owns every administrative role,
and `acceptOwnership()` has executed everywhere `Ownable2Step` needs it.

**Evidence.** `owner()` on each contract, read from chain, equal to the timelock address.

**A trap worth naming.** `Ownable2Step` makes a handover a *proposal*. Until the timelock
executes `acceptOwnership()`, the deploying key still owns the contract. The watchdog contracts
avoid it by taking the timelock as owner in their constructors; the token deployment still hands
some contracts over and prints the step in capitals. It has to be checked, not assumed.

---

## Part D — the token itself

### Gate 13 — the token launch attaches to the live watchdog

**Condition.** `Deploy.s.sol` is run with `EXISTING_TIMELOCK` and `EXISTING_AUDITOR_REGISTRY` set
to the addresses `DeployWatchdog.s.sol` produced.

**Evidence.** The values used, and the script's own validation passing — it checks the registry's
quorum, its members and its owner against what the launch expects, and refuses a mismatch.

**Why it is a gate.** Deploying a second auditor registry would leave every scan committed before
the launch answering to a set of auditors that no longer governs anything. The failure is silent at
the time and permanent afterwards.

### Gate 14 — the owner has read this document and signs the launch

**Condition.** The owner confirms in writing that gates 1 to 13 are closed, and personally signs
and broadcasts the mainnet transactions.

**Evidence.** The owner's confirmation and the resulting transaction hashes.

---

## What is deliberately not a gate

- **A price, a market cap or a listing.** None of them says the product works.
- **A marketing date.** If a gate is open on the date, the date moves.
- **Audience size.** A watchdog with ten users and a correct record is ready; one with ten thousand
  users and an unverifiable record is not.
- **Feature completeness.** Watchlists, alerts, the wallet graph and the SDK are all wanted and
  none of them gates the token. What gates it is that the record is real, covers what matters, and
  can be checked by somebody else.

---

## What may ship before any of this

The watchdog itself, the free basic scan, the live feed, token pages, the badge, the integration
standard and the documentation — all of it is public good with no token attached, and none of it
waits. That is the point of the ordering: everything that helps somebody can ship immediately, and
the only thing gated is the part that asks them for money.
