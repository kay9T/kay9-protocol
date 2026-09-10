# KAY9 — The On-Chain Watchdog

**A technical whitepaper.** Everything here is either a contract constant, a value the owner sets
before launch, or a piece of work with its status stated plainly. Where something is not built
yet, this document says so — see [Current status](#8-current-status) before reading anything
else as a claim about what exists today.

---

## Disclaimer

This document describes a protocol design and its current build status. It is not investment
advice, not an offer or solicitation to buy any token, and not a promise of price, return, or
reward. $KAY9 has not launched. Nothing here should be read as "verified safe" or as a guarantee
about any token KAY9 scans, including KAY9 itself — a technical audit is a reading of on-chain
state at a point in time, not a safety guarantee. See [§10, risks and known limitations](#10-known-limitations-stated-plainly).

---

## Abstract

KAY9 is a free, automatic, on-chain watchdog for token launches, plus a fixed-supply token with a
fair launch and permanently locked liquidity. The watchdog half does not need the token to exist:
it discovers new launches on Robinhood Chain, runs a free technical scan on each one without being
asked, and commits the result to a permanent on-chain registry — no wallet, no fee, no request. The
token half funds a deeper audit tier: locking KAY9 (not spending it) unlocks a quota of deep and
forensic audits, each requiring a two-of-three signed quorum from independent auditors before it
publishes. Every report, whether automatic or requested, lives in an append-only registry that
anyone — a wallet, a DEX, a launchpad, or another developer — can read directly from the chain,
with no KAY9-operated API in the path.

---

## 1. The problem

Robinhood Chain produces on the order of 20,000–50,000 new token launches a day; of those, roughly
600 reach a real trading pool with real liquidity. A buyer deciding whether to trust one of those
600 has no free, disinterested source of technical analysis available *before* they act — most
existing "audit" products are paid, requested, and therefore financially entangled with the thing
they are scoring: a project that pays for its own audit and receives a good one has bought
something that looks identical to an audit that was actually clean.

The hard problem on a chain producing tens of thousands of launches a day is not finding tokens —
it is ranking them: surfacing the roughly 600 that reach a real pool ahead of the noise, and
scanning them before anyone asks.

## 2. The watchdog: free, automatic, before the token exists

KAY9's watchdog is designed to run with no $KAY9 token in the loop at all. It discovers new
launches and pool-creation events directly from chain state (ten verified sources on Robinhood
Chain), runs a free automatic technical scan against each one at the basic tier, and commits the
result to `KAY9ScanRegistry` — a separate, permanent, Merkle-batched on-chain record — with no
wallet, no lock, and nobody's permission required. Batching keeps the cost of watching a chain
proportional to time rather than to that chain's launch volume: indexing every asset individually
would cost thousands of dollars a month on a chain at this scale, so only a compact Merkle root and
per-asset proof are committed for most scans, with full indexed storage reserved for assets that
clear into a real pool.

A basic scan is a **reproducibility claim**: one authorized scanner ran the published engine
against public chain state at a pinned block height, and anyone — including a KAY9 competitor —
can rerun the same engine against the same height and get the same answer. It is deliberately kept
in a separate contract from deep and forensic reports, which are a **consensus claim** (multiple
independent auditors signed the same result), so a reader is never able to mistake one kind of
claim for the other.

Because the watchdog does not depend on $KAY9 existing, `DeployWatchdog.s.sol` — the script that
puts it live — contains no token, no price oracle, and no access vault. It is designed to run,
and be verifiable as running, before the token launches at all.

## 3. The audit protocol: locked access, not payment

Deeper analysis — deep and forensic tiers — is gated behind an access lock, not a fee.

**Nobody pays for an audit.** There is no price per audit, no escrow, no treasury share, and no
burn of a requester's KAY9. A requester locks KAY9 in `KAY9AccessVault` for a fixed period (30
days by default), which unlocks a quota of audit requests for that period; the requester keeps the
locked tokens the entire time and receives the full principal back at the end, with no yield, no
APY, and no reward paid on it. What is spent is a quota unit, not money — locking is access, and
the moment a lock paid a return it would become an investment product instead, which this is
designed specifically not to be.

The reasoning: if a token creator handed KAY9 to an auditor and received a score, every good score
would look bought regardless of what the analysis actually found. Under a lock, the requester gives
KAY9 to nobody — there is no recipient for a score to be a payment to.

**Requester neutrality.** Paying nothing and declaring nothing about yourself can change a score.
A requester may declare what kind of party they are (e.g., the token's own creator requesting an
audit of their own token), and that declaration is recorded and shown as *declared*, never
presented as independently verified unless it actually is.

**Quorum.** Three independent auditor identities each run the same analysis engine, pinned to the
same chain height, and sign an EIP-712 attestation. A result publishes only once two of the three
signatures agree; a third, disagreeing signature is recorded as a dispute rather than averaged
away. An unanswered request expires automatically after a fixed SLA window and returns the
requester's quota unit — a request that produces no result costs nothing.

**Append-only, and never presented as current safety.** Every published result — automatic or
requested — is appended to `KAY9Registry` and never overwritten. If a scored asset's risk changes,
a new entry is added; the old one stays. The most recent entry is labeled as exactly that — a
snapshot at a point in time — never as an asset's current, ongoing safety status.

**Permitted language.** KAY9 never describes a scored asset as "verified safe." The only
phrasings a published result uses are *Audit Completed*, *Technical Risk*, and *Monitored* — a
technical scan is a reading, not a guarantee.

| Tier | Cost | Lock period | Allowance |
|---|---|---|---|
| Basic | Free, no wallet, no lock | — | Unlimited, runs in the requester's own browser |
| Deep | Lock target: $100 in KAY9 | 30 days | 4 requests |
| Forensic | Lock target: $500 in KAY9 | 30 days | 1 request (in addition to deep) |

The USD figures are *access targets*, quoted in KAY9 from an on-chain TWAP oracle at the moment a
lock opens and then frozen for the whole period — a later price move never asks the depositor for
more, and never shortens or voids an already-open period.

## 4. Trust model

KAY9's contracts are designed so that the website is never the source of truth. If kay9.io
disappeared entirely, every contract, balance, lock, auction record, access period, and committed
audit result would still be readable directly from Robinhood Chain, and any developer could build
a different interface against the same addresses.

**What can never happen, by contract design, not by policy:**

- No owner function can move a depositor's principal out of `KAY9AccessVault`. Its only owner-facing
  functions point it at an audit hub, set future per-period allowances, or set the length of
  *future* periods — none of them touch a balance, and none of them reach into an already-open
  period.
- `KAY9Token` has no mint function beyond its one-time constructor mint, no owner, no pause, no
  blacklist, no transfer tax, and no upgrade proxy. What is deployed is permanent.
- The Uniswap liquidity position backing the token's trading pool is locked into Uniswap's
  `FeeSplitter` with no withdrawal path — permanent by construction, not by promise.
- `KAY9Registry` never overwrites a prior entry. There is no admin function that deletes or edits a
  published report.

**What requires a 48-hour public delay.** The small set of parameters that can change at all —
adding an auditor, adjusting the audit SLA, adjusting future access-period length or targets —
route through a `TimelockController` with a minimum 48-hour delay between a change being proposed
and it taking effect, so any governance action is publicly visible for two days before it can do
anything.

## 5. The token

`KAY9Token` is a standard, fixed-supply ERC-20 (OpenZeppelin base, with permit and burn
extensions). The constructor mints exactly 1,000,000,000 KAY9 once; nothing can ever mint again.

| Allocation | Amount | Share | Notes |
|---|---|---|---|
| Public fair-launch auction | 455,000,000 | 45.5% | Sold via a Continuous Clearing Auction; the only sale — no presale, no private round |
| Permanent liquidity | 455,000,000 | 45.5% | Migrates into a Uniswap v4 pool and is locked permanently at launch |
| Team | 90,000,000 | 9% | Vested; see below |

**Team vesting**, enforced by immutable calendar timestamps set at deployment (not a relative
duration that could be reinterpreted later):

| Tranche | Amount | Share | Unlocks |
|---|---|---|---|
| 1 | 10,000,000 | 1% | At token launch (TGE) |
| 2 | 40,000,000 | 4% | TGE + 6 calendar months |
| 3 | 40,000,000 | 4% | TGE + 12 calendar months |

**The fair launch** is a Continuous Clearing Auction (CCA) on Uniswap's Liquidity Launcher —
third-party infrastructure already audited by OpenZeppelin, Spearbit, and ABDK, used as deployed
rather than forked. Anyone can bid; there is no allowlist, no minimum, and no privileged buyer.
When the auction graduates, all of the ETH raised funds the permanent liquidity position — none of
it is withdrawable by the team, and unsold tokens are never redirected to the team allocation.
Trading pool fee is a fixed 1% (Uniswap v4, static fee), paid by traders to liquidity providers —
a pool fee, not a token tax, and it cannot be changed after deployment.

## 6. Architecture, in one diagram

```
$KAY9 token (KAY9Token)                        immutable, no admin
KAY9 protocol
  liquidity, vesting, launch vault              immutable or owner-signed once, then permissionless
KAY9 Audit Protocol
  access vault, audit hub, registry, oracle     admin surface limited to a 48h-delayed timelock
Off-chain auditors (three, independent identities, scale-to-zero)
  watchdog engine + audit worker jobs           stateless; replaceable without touching contracts
Website (kay9.io)                               reads the chain directly; not the source of truth
```

Trust decreases reading downward. Everything above the timelock is either immutable or bound by
its own code; nothing below the timelock line can ever ask permission from anything above it.
Turning off every auditor does not touch a balance — open requests simply expire and refund their
quota. Turning off kay9.io does not touch a contract — every function is still callable directly.

## 7. Off-chain components

Three off-chain services do the work the chain itself cannot: the **watchdog engine** (the
analysis logic, run identically by every auditor and pinned to one chain height per run, so
independent operators produce byte-identical reports), the **audit worker** (a stateless job per
auditor — no always-on server, no VPS fleet; it wakes on a schedule, checks for new requests,
analyzes, signs, and exits), and **discovery** (finds new launches and pool events to feed the
free automatic scan). None of the three hold protocol state — deleting all of an operator's local
data changes nothing already committed on-chain; it only costs a re-scan.

The **free basic scan is not a service at all.** It runs entirely in a visitor's own browser
against a public RPC endpoint — no wallet, no KAY9, nobody's permission, and therefore nothing
that can go down.

## 8. Current status

$KAY9 **has not launched.** This is a live protocol design with contracts written and tested, not
a deployed, trading token. Specifically, as of this writing:

- The watchdog's contracts (`KAY9ScanRegistry`) are written and tested but **deployed nowhere
  yet**. Token discovery has been run against live mainnet data (1,459 tokens found in one pass)
  but the always-on scanning job is not yet standing.
- The audit protocol's contracts (`KAY9AccessVault`, `KAY9AuditHub`, `KAY9Registry`, `KAY9Pricing`)
  are written and pass an internal test suite (hundreds of tests including an invariant suite), but
  have **not yet been through a fresh third-party security review** against this version of the
  code, and have **not yet been rehearsed on testnet**.
- $KAY9 itself is **not deployed on any network.** The website renders "not deployed yet" wherever
  it would otherwise show a live figure, because that is the true statement.

KAY9's own launch sequencing deliberately puts the watchdog live *before* the token: discovery,
free automatic scanning, and the permanent scan registry are all designed to work with zero KAY9
in the loop, and the plan is to run them unattended on mainnet for a sustained period, with the
record independently reconstructible by someone outside the project, before the token launches at
all. A product asking to be trusted should be checkable first.

## 9. Roadmap, in outline

1. **Before launch:** finish the rewrite, re-run static analysis and an adversarial security
   review against the current contracts, complete a full testnet rehearsal of both the launch cycle
   and the access-lock cycle, and confirm the operating jurisdiction with professional legal and
   tax review. The watchdog goes live and stays live on mainnet during this phase, with no deadline
   pressure, since no token exists yet.
2. **Launch week:** contracts deploy and are verified publicly; the auction opens for a fixed
   window; migration, liquidity lock, and unsold-supply settlement are all permissionless once the
   owner signs the single launch transaction.
3. **Weeks 1–4:** the pricing oracle binds to the live pool, the access lock and its quorum of
   auditors go live, and the free browser-based basic scan opens to the public.
4. **Months 2–6:** registry integration for external wallets/DEXs/launchpads, continuous monitoring
   of already-scored assets, additional chains (BNB Chain, Solana), and the forensic tier's deeper
   analysis capability.
5. **Months 6–12:** move the auditor set toward genuine operator independence — see §10 below for
   why this matters, stated plainly.

## 10. Known limitations, stated plainly

**The launch auditor set is not three independent operators.** At launch, two of the three signing
identities run inside infrastructure the project owner controls (for cost reasons — three genuinely
independent commercial cloud accounts require a funding method this project does not yet have); only
the third is run by an independent operator. The two-of-three quorum protects against one dishonest
or compromised auditor, but it does **not** protect against a compromise of the owner's own
accounts, since that reaches two of the three. This is stated in the protocol's own security
documentation and on the website, not hidden, and closing it — moving the other two auditors onto
independent infrastructure — is the single highest-priority item on the roadmap.

**The public Robinhood Chain RPC is pruned.** Some historical on-chain lookups an auditor would
want (resolving a token's original deployer, for instance) are unavailable through the free public
endpoint, so those specific signals report as unmeasured rather than clean until an auditor runs
against an archive node.

**No access period can open before the token has a market price.** The pricing oracle requires 30
minutes of clean trading observations after launch before it will quote a lock requirement at all;
until then, every surface says the price is not available rather than showing a placeholder number.

## 11. What KAY9 will never do

Stated explicitly, because a roadmap that could later promise something the contracts are not built
to do would be a liability:

- No presale, no private round, no allocation sold at a better price than the public auction.
- No staking rewards, no yield, no APY on a locked balance. The contracts mint nothing beyond the
  one-time fixed supply, and there is no revenue to pay a reward out of.
- No governance-token claims. The 48-hour timelock is administrative safety, not a vote.
- No additional minting, ever — there is no mint function left to call.
- No withdrawal of the locked liquidity position — the contract holding it has no such path, and
  none can be added after deployment.
- No pay-per-audit, ever, under any name. Locking is access; the principal always comes back.
- No paid "verified" badge. A token's own creator can request an audit of their own token and
  receive a score of 25 out of 100 — the report says exactly who requested it.

## 12. Resources

| | |
|---|---|
| Website | https://kay9.io |
| Public contracts & specification repository | https://github.com/kay9T/kay9-protocol |
| X (Twitter) | https://x.com/kay9_io |
| Telegram — announcements | https://t.me/kay9official |
| Telegram — community | https://t.me/KAY9Pack |

Every figure, constant, and mechanism described in this document is drawn from the protocol's own
implementation documentation in this repository (`ARCHITECTURE.md`, `docs/ACCESS_MODEL.md`,
`docs/AUDITOR_NETWORK.md`, `docs/TOKENOMICS.md`, `docs/ROADMAP.md`), which is the authoritative
source if anything here and the code ever disagree — the code wins.
