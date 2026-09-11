# The KAY9 access model

KAY9 does not sell audits. There is no price per audit, no fee, no escrow and no payment split.
Access to the analysis tiers is a **lock**: you deposit KAY9 into `KAY9AccessVault`, you keep it,
and while it sits there you may request a fixed number of audits. At the end of the period you
take all of it back.

This document is the specification of that model. The contract is
`packages/contracts/src/KAY9AccessVault.sol` and its binding interface is in
`docs/CONTRACT_INTERFACES.md`.

## 1. The three tiers

| | Basic scan | Deep audit | Forensic audit |
|---|---|---|---|
| Cost | free | lock KAY9 worth about $100 | lock KAY9 worth about $500 |
| Period | none | 30 days | 30 days |
| Allowance | unlimited, runs in your browser | 4 deep audits | 1 forensic **and** 4 deep audits |
| Runs where | the visitor's own browser against a public RPC | the auditor network | the auditor network |
| Recorded on-chain | no | request, quota, result, history | request, quota, result, history |

Basic scan requires no lock, no wallet and no KAY9. It is not a teaser for the paid product; it is
the part of the analysis that can be honestly computed from a handful of direct contract reads, and
so it should not need anybody's permission. `docs/WATCHDOG.md` §2 lists exactly which signals
qualify and why the rest cannot.

## 2. Why a lock rather than a payment

A per-audit fee has three problems that a lock does not.

**It puts the analyst on the payroll of the analysed.** If a token creator hands over KAY9 and
receives a score, then every good score looks bought, whatever the code actually does. Under a
lock, the person requesting an audit gives KAY9 to nobody. The auditors are not paid by the
requester, so there is nothing for a score to be a payment for.

**It prices the product in the wrong unit.** A fee denominated in KAY9 becomes unusable if KAY9
appreciates, and denominating it in dollars means charging a moving amount of KAY9 for the same
thing. A lock has the same problem in principle and solves it in practice, because the amount is
fixed only for the duration of one period and requoted at renewal.

**It makes the treasury a beneficiary of volume.** Nothing in KAY9 should reward publishing more
audits rather than better ones.

What the lock does instead is bound cost. Analysis at the deep and forensic tiers is genuinely
expensive to run, and an unlimited allowance from one small deposit would be an invitation to
exhaust it. The allowance exists for that reason and no other.

## 3. What the lock is not

- **Not staking.** There is no annual percentage yield, no reward, no emission, no share of fees.
  The vault mints nothing and receives nothing.
- **Not a payment.** No KAY9 leaves the vault except back to the address that deposited it.
- **Not slashable.** There is no penalty mechanism for a depositor. Nothing a depositor does can
  reduce the principal.
- **Not burnable.** The vault never calls `burn`.
- **Not custodial in spirit and not in code.** The contract has no owner function that can move a
  depositor's principal. `setAuditHub`, `setQuota` and `setLockDuration` are the entire owner
  surface, all behind the 48 hour timelock, and none of them touches a balance.

The website says exactly this, in these words: **no APY, no yield, your KAY9 remains yours.**

## 4. How the required amount is fixed

The vault holds a USD target per tier, `$100` and `$500`, stored in `KAY9Pricing.usdTarget` scaled
by 1e8 and changeable only through the timelock. When a period opens, the vault asks the oracle how
much KAY9 that target is worth and takes exactly that amount.

Then it stops asking. The quoted amount is written into the access record as `quotedKay9` and the
oracle is never consulted again for that period. Three consequences, all deliberate:

- If KAY9 doubles the next day, nobody is asked for more, and nobody's period is shortened or
  voided.
- If KAY9 halves the next day, nobody is refunded either. The period was opened at the price of the
  day.
- At renewal the question is asked again, so the amount tracks the token over time without ever
  moving underneath a live period.

The oracle is `KAY9Pricing`, which is a 30 minute TWAP over the official Uniswap v4 pool combined
with a Chainlink ETH/USD feed, with a spot deviation cap, a minimum liquidity floor, an observation
gap check and a feed staleness check. It **fails closed**: when any check does not pass it reverts
rather than returning a number.

That failure mode is the point. A manipulated or stale price would let somebody open a period for
far less KAY9 than it should cost, so `lock`, `renew` and `upgrade` all refuse while the oracle is
untrusted. `unlock` does the opposite and never reads the oracle at all, because an outage must
never be able to trap a depositor's tokens.

## 5. The period

Thirty days, set by `lockDuration`, changeable through the timelock within seven and three hundred
and sixty five days. A live period keeps the length it opened with; a change only affects periods
opened afterwards.

**Renewal is refused before expiry.** This is the one rule in the vault that exists purely to close
an abuse, so it is worth stating why. If a depositor could renew early, they could spend four deep
audits on day one, renew on day two for no extra KAY9, and spend four more. The allowance would be
unbounded for anyone willing to send one extra transaction. Renewal at or after expiry has no such
problem: the period genuinely ended.

Renewal does not require unlocking first. `renew` requotes the requirement and settles the
difference in whichever direction it went, so the depositor stays in the vault across the boundary.

**Upgrading is allowed mid-period**, deep to forensic only. It tops the lock up to the forensic
requirement, leaves the expiry alone and, importantly, carries `deepUsed` across. Deep allowance is
four in both tiers, so upgrading buys the forensic slot and nothing else. Without carrying the used
counter, upgrading would be a way to reset the deep allowance.

## 6. Quota is enforced on the chain

`KAY9AuditHub.requestAudit` calls `accessVault.consume(msg.sender, tier)` and that call is what
decides whether the request happens. It reverts when the caller has no live period, when the period
is of a lower tier than the request, and when the tier's allowance for the period is spent.

The website is not consulted, cannot grant access, and cannot be worked around, because it was
never in the path. A wallet, a script, a bot or another contract calling the hub directly gets the
same answer as a visitor clicking a button on kay9.io. Quota used and quota remaining are public
reads on the vault, so anybody can verify them.

A request that produces no result costs no quota. When a job is disputed or expires, the hub calls
`accessVault.restore` with the period the unit came from, and the vault credits it back. Passing the
period explicitly is what stops a credit landing in a later period that did not pay for it: if the
depositor has renewed in the meantime, the restore is a silent no-op.

## 7. What the owner can and cannot change

| Parameter | Who | Delay | Affects live periods |
|---|---|---|---|
| USD target per tier | owner via timelock | 48 h | no |
| Audits allowed per period | owner via timelock | 48 h | no |
| Period length | owner via timelock | 48 h | no |
| Which hub may move quota | owner via timelock | 48 h | quota only, never principal; the replaced hub keeps `restore` so its pending jobs still refund |
| A depositor's principal | **nobody** | — | — |

The last row is the one that matters. There is no function, timelocked or otherwise, that sends a
depositor's KAY9 to any address other than the depositor. The tests assert this directly rather
than by inspection.

## 8. Before the token exists

Everything above needs a KAY9 price, and there is no price before the launch auction has produced
one and the oracle has thirty minutes of observations. Until then `quoteLock` reverts, and the
website must say so rather than invent a number.

The prelaunch surface is therefore: basic scan works, the access tiers are described with their USD
targets and their allowances, and where the required KAY9 amount would go the page says the price
is not available yet and explains that a locked amount is quoted from a manipulation-resistant
price that does not exist before trading does. No placeholder figures, no fake charts, no
countdown-to-buy.

### 8.1 Deep and forensic audits in beta, without a lock

A tier nobody can reach is a tier nobody can check, so deep and forensic analysis is available
before the token — through a different door, and labelled as such.

**How.** `KAY9AuditHub.publishWatchdogReport` is permissionless, consumes no quota and needs no
access record: it takes a result and two of three auditor signatures, verifies them against
`KAY9AuditorRegistry` on chain, and appends the report to `KAY9Registry`. That path exists for
continuous monitoring — a quorum publishing an unsolicited report about an asset nobody asked
about — and a beta deep audit is exactly that: unsolicited, unpaid, requested by nobody on chain.

**What makes it possible at all.** The hub deploys with no access vault. `KAY9Registry` binds to
its hub immutably, so the hub has to be the final one from the first deployment; but the vault
holds KAY9 and cannot exist before the token does. So the hub accepts a zero vault, `requestAudit`
refuses with `AccessVaultNotSet` until governance sets one, and `publishWatchdogReport` works from
day one. At TGE the timelock calls `setAccessVault` once — it cannot be called twice, so the
binding is as permanent as an immutable would have been — and requests open.

**What a beta report is and is not.**

| | Beta report | Requested audit, after TGE |
|---|---|---|
| Engine | identical | identical |
| Signatures | two of three auditors | two of three auditors |
| On-chain, permanent, in `KAY9Registry` | yes | yes |
| Consumes quota | no | yes |
| Requester on chain | `address(0)` | the requester |
| `tier` field | `0` | 1 or 2 |
| Who chose the asset | whoever submitted it to the beta queue, first-come order | whoever asked |

**Submitting a candidate (R24, KAY9-REVIEW.md).** A real person can ask, without a wallet or KAY9:
`services/audit-worker/src/beta-api.ts` serves a free `POST /submit {chain, asset, tier}` that
records the ask in a shared, first-come queue (`beta-store.ts`) — no lock, no quota, no on-chain
trace of the submission itself. `services/audit-worker/src/beta.ts`'s bounded `beta` pass then
works the queue: it skips anything `KAY9Registry.latest` already shows a report for, and processes
a handful of the oldest still-unserved candidates per run — the schedule (weekly, by default) is
the rate limit, not a persisted counter. The engine, the signatures and the publish path are
identical to what this section already described; only *what gets looked at* changed, from pure
auditor discretion to a real, if unpaid and no-guarantee, line. See
`services/audit-worker/deploy/README.md`'s "Beta" section for the operational detail.

The last row is still the honest limit: there is no queue position to *buy*, nothing here promises
a place, and a full queue or an exhausted per-run budget can leave a real ask unanswered for a
week or more. That is a real limitation of the beta, not a feature of it.

**Rules for the surface.** Every beta report is labelled BETA wherever it appears. No KAY9 balance,
lock, quota or countdown is shown, because none exists — a fake balance would be the single most
dishonest thing this site could render. The report itself carries `jobId = 0`, `requester = 0` and
`tier = 0` on chain, so an integration can tell a beta report from a requested one without asking
KAY9 anything.

**What beta is for.** Proving the deep and forensic engines produce something worth locking KAY9
for, before anybody is asked to lock any. If they do not, that is worth finding out before the
token exists rather than after.
