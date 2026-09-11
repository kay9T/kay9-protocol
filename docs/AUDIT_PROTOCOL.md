# KAY9 Audit Protocol

This document specifies the audit protocol end to end: how a request becomes a signed, on-chain
result, what that result means, how it is scored, and how anyone can verify it without trusting
kay9.io, the auditors, or this repository.

Three rules shape everything below.

**Nobody pays for an audit.** There is no fee, no price per audit, no escrow, no treasury share and
no burn. Access to the deep and forensic tiers is a lock in `KAY9AccessVault`: the requester
deposits KAY9, keeps it, and takes all of it back at the end of the period. What a request spends
is a quota unit, not money. `docs/ACCESS_MODEL.md` is the specification of that model.

**Who asks cannot change the answer.** The scoring function is deterministic, published here, and
identical for every asset. A token creator requesting an audit of their own token gets exactly the
same treatment as a stranger requesting one of it, because there is nothing an auditor could read
that says otherwise and nothing anybody could have paid. The primary reader is not the creator; it
is the person deciding whether to buy.

**Signals are observations, not accusations.** Every finding describes something visible on-chain
and says what it can and cannot imply. A mint function in the bytecode means the supply *can* be
increased; it does not mean anyone intends to. The engine never asserts intent, and the report says
so in its own disclaimer field.

---

## 1. Participants

| Party | Role | Trust required |
|---|---|---|
| Requester | Holds an access period, names `(chainKey, assetId, tier)` | none |
| Auditors | Three identities; each analyses independently and signs its own conclusion | quorum of `threshold` distinct signers |
| `KAY9AccessVault` | Holds the lock, enforces the quota, returns the principal | code |
| `KAY9AuditHub` | Access check, signature verification, quorum, dispute, expiry | code, deployed and verified |
| `KAY9Registry` | Append-only report history | code |
| `KAY9AuditorRegistry` | Auditor set and threshold | Timelock (48 h) |
| `KAY9Pricing` | KAY9 per USD, used only to size a lock | code plus Chainlink and the pool |

Auditors hold no protocol state. Deleting every auditor's local storage changes nothing that is
already on-chain; it only makes them re-scan. `docs/AUDITOR_NETWORK.md` describes where they run and
what the arrangement does not guarantee.

---

## 2. Access, before anything else happens

A request is authorised by a contract read, not by a website and not by a payment.

### 2.1 Opening a period

```
quoteLock(uint8 tier) -> (uint256 kay9Amount, uint256 usdTargetE8)
lock(uint8 tier, uint256 maxKay9)
lockWithPermit(uint8 tier, uint256 maxKay9, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
```

`quoteLock` reverts `PricingUnavailable(code)` when the oracle cannot be trusted, and `lock`
bubbles that. The requirement is quoted once and then frozen for the period, so a later price move
never asks the depositor for more and never voids a live period. `maxKay9` is slippage protection:
the requirement is denominated in dollars but settled in a moving token, and the caller states the
largest amount they will lock.

| Tier | Lock | Period | Allowance |
|---|---|---|---|
| Basic | none | — | unlimited, and it runs in the visitor's own browser (§2.6) |
| Deep | KAY9 worth about $100 | 30 days | 4 deep audits |
| Forensic | KAY9 worth about $500 | 30 days | 1 forensic **and** 4 deep audits |

### 2.2 Requesting

```
requestAudit(bytes32 chainKey, bytes32 assetId, uint8 tier, uint8 declaredRequesterKind) -> uint256 jobId
```

The first thing the hub does is call `accessVault.consume(msg.sender, tier)`. That call is the whole
authorisation, and it reverts when the caller has no live period, when the period is of a lower tier
than the request, or when that tier's allowance is spent. The website is never consulted, cannot
grant access and cannot be worked around, because it was never in the path: a wallet, a script, a
bot or another contract calling the hub directly gets the identical answer.

The job then records, among other things:

- `requestedBlock` — the chain's own height at request time (read through `ArbSys` on this Orbit
  chain since 2026-09-11; before that it was the parent chain's `block.number`, R01 in
  KAY9-REVIEW.md), recorded for the on-chain audit trail. It is never the analysis pin, because an
  audited asset may live on a different chain — see `requestedAt` below.
- `requestedAt` — the timestamp every auditor pins its analysis to. The chain chooses it, not the
  auditors, and each auditor resolves it to the target chain's own RPC height with a deterministic
  binary search, so there is nothing to negotiate and no clock skew.
- `accessPeriodStartedAt` — the vault period the quota unit came from, so a later restore cannot
  credit a different period.
- `declaredRequesterKind` — 0 unknown, 1 independent, 2 token creator, 3 integration. This is
  metadata the caller states about *itself*, and the hub records it verbatim.

```
AuditRequested(jobId, requester, chainKey, assetId, tier, declaredRequesterKind, expiresAt)
```

Note what the event does **not** carry: no amount, no price, no payment. There is nothing in it an
auditor could read that would tell it the request was worth more or less than any other.

### 2.3 Quota is restored when nothing was produced

A request that produces no result costs no quota. When a job is disputed or expires, the hub calls
`accessVault.restore(requester, tier, accessPeriodStartedAt)` and the vault credits the unit back.
Passing the period explicitly is what stops the credit landing in a later period that did not pay
for it: if the depositor has renewed in the meantime, the restore is a silent no-op.

### 2.4 The declaration is recorded, never believed

`declaredRequesterKind = 2` means the requester said it is the token's creator. The registry stores
that, and every surface renders it as **declared and unverified**. The only statement the protocol
will make about it is flag bit 18, `REQUESTER_IS_DEPLOYER`, which the auditors set when they have
established on-chain that the requesting address really is the asset's deployer. A self-declaration
alone never sets it.

Both facts are recorded for the reader's benefit, not the requester's. Knowing that a report was
commissioned by the token's own creator is genuinely useful context. It changes nothing about the
score, because it reaches nothing that computes one.

### 2.5 Ending or continuing a period

`unlock()` returns the whole principal at or after expiry and reads no oracle at all, so an outage
can never trap it. `renew(tier, maxKay9)` is refused before expiry — an early renewal would reset
the allowance inside a period that was already opened once — and at or after expiry requotes and
settles the difference without an unlock-and-relock round trip. `upgrade(maxKay9)` raises a live
deep period to forensic, preserving `deepUsed`.

### 2.6 Free basic scans

Basic scans never touch the chain and never touch this protocol. They run **in the visitor's own
browser** against a public RPC: no wallet, no KAY9, no lock, no job, no on-chain record, and nobody
to ask. That is a deliberate architectural choice rather than a pricing decision. The signals a
basic scan computes are the ones that can be honestly derived from a handful of direct contract
reads (`docs/WATCHDOG.md` §2), and a person should not need anybody's permission to make reads that
any node will serve them.

An optional convenience endpoint may run the same analysis server-side for callers who cannot run it
locally. It is explicitly **not canonical**: no part of the protocol depends on it, no score is
authoritative because it came from there, and it can be switched off without degrading anything.

---

## 3. Attestation, quorum and dispute

```
attest(uint256 jobId, AuditResult result, bytes[] signatures) -> uint256 reportId
```

`reportId` is 0 until a quorum lands. Anyone may call it; what matters is whose signatures it
carries. The hub:

1. checks the job is in `Requested` status;
2. checks `result.chainKey` and `result.assetId` equal the job's;
3. recovers each signature over the EIP-712 digest of `(jobId, result)`;
4. requires each recovered signer to be an active auditor that has not already attested this job;
5. counts the votes for that digest;
6. finalises against the result the moment one digest reaches `auditors.threshold()` votes, writing
   it to `KAY9Registry` via `recordReport` and emitting `AuditFulfilled`.

The ordinary case costs one transaction: the second auditor to finish submits the first one's
agreeing signature together with its own. An auditor that disagrees pays for its own transaction to
say so. That asymmetry is intentional — dissent should be cheap enough to be free of friction, but it
is not the common path. Only an active auditor may submit, for `attest` and `publishWatchdogReport`
alike: `reportURI` is not in the signed struct, so the submitter chooses the pointer the registry
records, and the relay the signatures travel through is public.

### 3.1 Disagreement is a state, not an average

The job becomes `Disputed` the moment agreement is arithmetically impossible, that is when
`bestAgreement + silent < threshold`, where `silent` is counted per **currently active** auditor —
how many of today's auditor set have not attested to this job at all — rather than as
`auditorCount − attestations`. The two differ once the auditor set has rotated mid-job: an
attestation from an auditor since removed still increments `attestations`, and counting the raw
difference could read that as "everyone has spoken" while an active auditor who never voted could
still bring either open position to quorum. With three auditors, a threshold of two and no
rotation, three mutually different results still dispute the job.

- Contradictory scores are **never** averaged. There is no mean, no median and no tie-break that
  invents a number nobody signed. A number three auditors disagree about is not improved by
  arithmetic; it is evidence that the asset is hard to read, and that is what the chain should say.
- The conflicting positions stay readable per auditor through `attestationOf(jobId, auditor)`.
  Anybody can see which auditor said what.
- A disputed job restores the requester's quota unit.

### 3.2 Expiry

```
markExpired(uint256 jobId)
```

Permissionless once `requestedAt + slaSeconds` has passed (6 hours by default, bounded to between 1
hour and 30 days). `slaSeconds` here is the job's own — the value in force when it was requested,
frozen on the `Job` struct for the job's whole life, not whatever governance has since set `setSla`
to. Without that freeze, a governance change while jobs are pending would move every pending job's
deadline out from under the `expiresAt` its own `AuditRequested` event already promised. It restores
the quota unit. Expiry is never pausable: governance can pause new requests, but it cannot stop an
attestation, a dispute or an expiry, because a job that has already spent a quota unit must always
be able to reach an end state.

### 3.3 Duplicate protection, and why it is not signer ordering

`attest` blocks duplicates with `attestationOf[jobId][signer]` rather than by requiring the
signatures in a call to ascend by address. The reason is structural: signatures for one job arrive
across more than one transaction, so an ordering rule inside a single call could not prevent the
same auditor signing twice in two calls. The signer list stored on the finalised report is kept
sorted by insertion, so the record is canonical either way.

`publishWatchdogReport` has no such per-job history to consult, so it *does* require signers strictly
ascending by address, and each watchdog digest may be committed only once.

### 3.4 Unsolicited watchdog reports

```
publishWatchdogReport(AuditResult result, bytes[] signatures) -> uint256 reportId
```

A quorum may commit a report against `jobId = 0` with no requester. Nobody asked for it and nobody
paid for it, which is what makes KAY9 a watchdog rather than a vendor. This is how the auditors
raise an alarm about an asset whose state has changed materially since its last report; such a
report sets flag bit 19, `MONITORING_UPDATE`, to say it supersedes an earlier one.

---

## 4. The result committed on-chain

```solidity
struct AuditResult {
    bytes32 chainKey;      // keccak256(bytes(caip2))
    bytes32 assetId;       // EVM: left-padded address. Solana: the 32-byte mint
    uint8   overallTrust;  // 0 = worst observable, 100 = nothing risky observed
    uint8   contractTrust;
    uint8   liquidityTrust;
    uint8   holderTrust;
    uint8   insiderTrust;
    uint8   creatorTrust;
    uint8   tradingTrust;
    uint8   botTrust;
    uint64  flags;         // bitmask, table in section 6
    uint32  engineVersion; // major*1_000_000 + minor*1_000 + patch; 1.0.0 = 1000000
    uint64  analyzedAt;    // unix seconds
    bytes32 reportHash;    // keccak256 of the canonical JSON report body
    string  reportURI;     // ipfs://... or kay9://local/<hash>
}
```

The struct is fixed size on purpose. The chain stores a verdict and a commitment; the evidence lives
off-chain and is bound to that commitment by `reportHash`. `reportURI` only says where a copy can be
fetched, so a hostile gateway can withhold the body but cannot substitute a different one.

Alongside the result, `KAY9Registry` stores the `jobId`, the `requester`, the
`declaredRequesterKind`, the `tier`, the `signers`, `committedAt` and `committedBlock`.

### 4.1 A report is never overwritten

A new audit of the same asset appends a new record. `historyCount` and `history` keep every one of
them in commitment order, so an asset that scored 89 in September and 42 in October has both
records, both signed, both permanent, and a reader can watch risk change over time.

`latest` therefore means **most recent snapshot**, never **current safety**, and every surface that
renders it also renders `committedAt`. `latestSummary`, `latestSummaryForToken` and `scoreHistory`
exist so that a wallet, DEX, launchpad or badge can consume that data with one contract call and no
KAY9-operated API.

### Chain identity

`chainKey = keccak256(bytes(caip2))`. Current values:

| CAIP-2 | chainKey |
|---|---|
| `eip155:4663` | `0x4c583a970094e332eaa480a6f7478093ea9b680af9ffceecda5867d8bb2afb4a` |
| `eip155:46630` | `0xd891e31bdef6f8353b829a6036074e8065f1c3787aad135bb39bba85d0b5a0e3` |
| `eip155:56` | `0x1c2c352ae1aebf62d547610efc671cb0b4e48d82942e8049ebff0a4e92e90530` |
| `solana:mainnet` | `0x992ce2739e02817ca920a77c711559b6d47ff779e1f93d0be19ece4ce4a2a06c` |

New chains are added by convention, not by governance: hash the CAIP-2 string. An auditor that has
no adapter for a chainKey simply cannot serve jobs naming it.

---

## 5. EIP-712

### Domain

```
name              "KAY9AuditHub"
version           "1"
chainId           4663 on mainnet, 46630 on testnet
verifyingContract the KAY9AuditHub address
```

### Type

```
AuditResult(uint256 jobId,bytes32 chainKey,bytes32 assetId,uint8 overallTrust,uint8 contractTrust,uint8 liquidityTrust,uint8 holderTrust,uint8 insiderTrust,uint8 creatorTrust,uint8 tradingTrust,uint8 botTrust,uint64 flags,uint32 engineVersion,uint64 analyzedAt,bytes32 reportHash)
```

`RESULT_TYPEHASH` is `keccak256` of that string. Note that `jobId` comes **first**, before the
struct's own fields: the digest is over the pair `(jobId, result)`, which binds a signature to one
job and stops a signature being replayed against another. Unsolicited watchdog reports use
`jobId = 0`.

`reportURI` is a field of the `AuditResult` struct — still transmitted, still what the registry
stores — but it is deliberately **not** in the type above and not in the digest below. It says
only where a copy of the report body currently lives; `reportHash`, which is signed, is what binds
that document to the record (KAY9Registry.sol's own doc comment on `AuditResult`). Three auditors
that independently pinned byte-identical content to three different storage backends are not in
disagreement, and treating them as if they were meant genuine, honest quorums could never form
whenever operators' pinning behaviour merely differed — not even failed, just differed (R17 in
KAY9-REVIEW.md).

### Digest

```
structHash = keccak256(abi.encode(RESULT_TYPEHASH, jobId, chainKey, assetId,
                overallTrust, contractTrust, liquidityTrust, holderTrust,
                insiderTrust, creatorTrust, tradingTrust, botTrust,
                flags, engineVersion, analyzedAt, reportHash))

domainSeparator = keccak256(abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KAY9AuditHub"), keccak256("1"), chainId, verifyingContract))

digest = keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash))
```

`KAY9AuditHub.hashResult(jobId, result)` returns exactly this value, so a signer can always
cross-check against the contract before signing.

The TypeScript side is `services/audit-worker/src/eip712.ts`. It computes the digest twice, once by
hand with `encodeAbiParameters` and once through viem's `hashTypedData`, and a test asserts the two
agree; a second test asserts the type string matches the one in `docs/CONTRACT_INTERFACES.md`
character for character.

### What a signature cannot be moved to

| Boundary | What stops it |
|---|---|
| Another chain | `chainId` in the domain separator |
| Another deployment on the same chain | `verifyingContract` in the domain separator |
| Another job | `jobId` is the first field of the signed struct |
| Another asset | `result.chainKey` and `result.assetId` must equal the job's |
| A second vote on the same job | `attestationOf[jobId][signer]` is already set |
| A replayed watchdog report | `watchdogReportCommitted[digest]` is already true |

### Signature rules

- 65-byte ECDSA `(r, s, v)` with `v` in {27, 28}.
- Recovered signers must be active auditors at the time the transaction lands.
- At least `auditors.threshold()` votes on one digest to finalise (2 of 3 at launch).
- Every signature counted toward a quorum covers the **same struct**. Two auditors who reached the
  same conclusion but produced different report bytes have produced different structs and are not
  aggregated; §9.2 explains why that is a solvable problem rather than a fatal one.
- For watchdog reports only, signers must be strictly ascending by address within the call.

---

## 6. Flags

`flags` is a `uint64` bitmask. Bit numbers are consensus-critical and must match the Solidity
constants, `@kay9/chain`, and the engine.

| Bit | Mask | Name | Meaning |
|---|---|---|---|
| 0 | 1 | `MINTABLE` | Supply can be increased |
| 1 | 2 | `FREEZABLE` | Balances can be frozen or transfers paused |
| 2 | 4 | `BLACKLIST` | Address deny-list present |
| 3 | 8 | `MUTABLE_TAX` | Transfer fee can be changed |
| 4 | 16 | `PROXY` | Upgradeable proxy |
| 5 | 32 | `OWNER_PRIVILEGES` | Owner holds non-standard powers |
| 6 | 64 | `LOW_LIQUIDITY` | Liquidity below thresholds |
| 7 | 128 | `UNLOCKED_LIQUIDITY` | Provider position not locked or burned |
| 8 | 256 | `HOLDER_CONCENTRATION` | Top holders exceed concentration thresholds |
| 9 | 512 | `LINKED_WALLETS` | Clustered wallets share a funding source |
| 10 | 1024 | `CREATOR_HISTORY` | Creator linked to prior launches |
| 11 | 2048 | `SNIPERS` | Early-block buyers dominate the float |
| 12 | 4096 | `BUNDLED_BUYS` | Bundled insider buys detected |
| 13 | 8192 | `WASH_TRADING` | Wash-like volume pattern |
| 14 | 16384 | `HONEYPOT_SIGNALS` | Sell restrictions suspected |
| 15 | 32768 | `HIDDEN_TRANSFER_RESTRICTION` | Non-standard transfer logic |
| 16 | 65536 | `UNVERIFIED_SOURCE` | Source not verified on the explorer. Informational: scores zero, and is only present when an explorer is configured |
| 17 | 131072 | `INSUFFICIENT_DATA` | Analysis partial |
| 18 | 262144 | `REQUESTER_IS_DEPLOYER` | The requesting address was established on-chain as the asset's deployer. Informational: scores zero |
| 19 | 524288 | `MONITORING_UPDATE` | This report supersedes an earlier one for the same asset. Informational: scores zero |

`INSUFFICIENT_DATA` deserves emphasis. It is set whenever any data source the engine wanted was
unavailable, and it is the single most important flag on the list, because it tells the reader that
the absence of other flags proves nothing. A report with `flags = 131072` and high scores has not
found an asset to be safe; it has found nothing at all.

**Bits 18 and 19 score zero, and it matters that they do.** Bit 18 is context about who asked, and
letting it move a number in either direction would be exactly the failure the access model exists to
prevent: a creator-requested audit must not score worse for being creator-requested, and it must
certainly not score better. Bit 19 is context about *when*, telling a reader that this snapshot
replaced an earlier one — useful for reading a history, irrelevant to the risk of the asset at the
block that was analysed.

---

## 7. Scoring

The scoring function lives in `services/watchdog/src/engine/scoring.ts`. It is pure, deterministic,
and takes only the signal list as input: no clock, no randomness, no requester, and signals are
sorted by their code before they are summed so that the arrival order of data cannot change a score.

### 7.1 Method

Every signal carries a category, a point value (0..100) and a confidence (0..1). Internally, points
accumulate as *risk* — the same "how much was found" arithmetic regardless of which way the
published number runs — and are converted to the published *trust* score in one last step, so
nothing above that step needs to know the scale flipped:

```
categoryRisk   = clamp(round(sum over signals in that category of points * confidence), 0, 100)
overallRisk    = clamp(round(sum over categories of weight * categoryRisk), 0, 100)
overallRisk    = max(overallRisk, 60)  if any scoring signal is high severity
overallRisk    = max(overallRisk, 80)  if any scoring signal is critical severity

# The one conversion, in engine/scoring.ts's toTrustScores — everything published is this:
publishedTrust = 100 - risk
```

Category weights, summing to exactly 1:

| Category | Weight | What it measures |
|---|---|---|
| `contract` | 0.30 | Powers the deployed code grants: minting, pausing, deny-lists, mutable fees, upgradeability, privileged balance movement, source verification |
| `liquidity` | 0.20 | Depth of the discovered pools on the quote side, and whether the provider position is locked or burned |
| `holder` | 0.15 | Concentration of circulating supply, with pools, burn addresses and the token contract excluded |
| `insider` | 0.10 | Wallets sharing a funding source, and transfers funding several recipients at once |
| `creator` | 0.10 | The deployer address and the deployment pattern in its sampled history |
| `trading` | 0.08 | Round-trip transfer patterns, and whether the asset trades at all |
| `bot` | 0.07 | How much of the earliest distribution a small set of addresses captured |

The requester is not an input to any of them, and no field derived from the requester is available
to the function at all.

### 7.2 Missing data caps trust

A category whose data could not be gathered is held internally at the **uncertainty floor of 35
risk** — never at zero risk — and `INSUFFICIENT_DATA` is raised, which publishes as a **ceiling of
65 trust**: an unmeasured category can never read as more than moderately trustworthy, however clean
what little was measured looked. The floor never lowers a measured risk value (equivalently, the
ceiling never lowers a measured trust value): if the measured reading is already worse than the
floor/ceiling, it stands.

Report confidence is reported separately:

```
coverage         = (7 - unmeasurableCategories) / 7
signalConfidence = mean confidence of the signals that scored points (1 if none)
confidence       = round(0.6 * coverage + 0.4 * signalConfidence, 3)
```

### 7.3 Interpreting a score

Scores are trust, not a quality rating. `100` means nothing risky was observed; `0` means the worst
observable state. They are not a recommendation, and two assets with the same score can be risky for
entirely different reasons — which is why the flags and the report body matter more than the number.

They are also a statement about one block. A score describes the asset as it was at
`analyzedAtBlock`, and an upgradeable contract can be made to behave differently five minutes later.
The permitted phrasings are **KAY9 Audit Completed**, **KAY9 Technical Risk** and **KAY9 Monitored**.
Nothing in this protocol may be described as verified safe.

---

## 8. The report body

The off-chain report is JSON with a stable schema (`schemaVersion: 3`). Schema 2 added
`analyzedAtBlock`; reports at schema 1 describe a range of chain states rather than one, so their
hashes are not reproducible and must not be compared against later schemas. Schema 3 added the
`requester` object. Top-level fields:

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | number | 3 |
| `engineVersion` | string | e.g. `"1.0.0"` |
| `engineVersionCode` | number | the `uint32` written on-chain |
| `tier` | string | `basic` / `deep` / `forensic` |
| `analyzedAt` | number | unix seconds; for a job this is the job's own `requestedAt` |
| `analyzedAtBlock` | number | block height every chain read was pinned to; absent on chain families without block numbers |
| `chain` | object | `caip2`, `chainKeyHash`, `family`, `name`, `chainId?` |
| `target` | object | `chain`, `address`, `assetId`, and `name` / `symbol` / `decimals` / `totalSupply` / `standard` when readable |
| `requester` | object | `jobId`, `address`, `declaredKind`, `declaredKindVerified`. Absent for unsolicited watchdog reports, which have no requester |
| `scores` | object | the eight risk numbers |
| `confidence` | number | 0..1 |
| `flags` | array | `{code, bit, title, severity, confidence, evidence[], signals[]}` per raised flag, ordered by bit |
| `signals` | array | every signal considered, including ones that scored nothing, ordered by code |
| `observations` | object | raw per-module output: bytecode scan, metadata, proxy slots, pinned block, balances, creation, explorer state, liquidity, concentration, activity, clusters. Records what was observed, never how many requests it took: retry counts and transient errors would differ between auditors and break the hash |
| `methodology` | object | the scoring description, the weight table, the floors, and notes |
| `notes` | array | degraded sources, bounds that were hit, tier limits |
| `disclaimer` | string | the standing disclaimer text |

Each signal is `{code, category, title, severity, points, confidence, flag?, evidence[], detail,
affects?}`, and each evidence entry is `{kind, label, value, source, url?}`. `detail` is written to
state what the observation can and cannot imply.

### 8.1 The report says who asked

`requester.declaredKind` is the value the requester passed to `requestAudit`, reproduced from the
chain rather than from anything the requester told an auditor off-chain.
`requester.declaredKindVerified` is true only when the auditors established on-chain that the
requesting address is the asset's deployer, which is the same condition that sets flag bit 18.

So a creator-commissioned report says, in its own body and on its own face, that the creator
commissioned it, and says whether that claim was checked. It does not say that this changed
anything, because it did not: the requester never reaches the scoring function (§7).

### 8.2 Canonical JSON and `reportHash`

`reportHash = keccak256(utf8Bytes(canonicalize(report)))`.

`canonicalize` is a small, deliberately restricted subset of RFC 8785:

- object keys sorted ascending by UTF-16 code unit;
- no insignificant whitespace;
- `undefined` properties dropped, `undefined` array entries become `null`;
- `bigint` serialised as a decimal **string**, never as a JSON number, so `uint64` and `uint256`
  values survive a round trip;
- only finite numbers; `-0` normalises to `0`;
- `Date` rejected — timestamps in reports are unix seconds.

The implementation is `services/watchdog/src/canonical.ts` and is covered by its own test file,
including the property that re-canonicalising a parsed canonical string is a fixed point.

Canonical bytes are what let three independent auditors agree without coordinating: identical input
produces an identical body, an identical hash, and an identical IPFS content identifier from all
three.

### 8.3 Verifying integrity

```bash
# 1. Read the committed result
cast call $REGISTRY "latest(bytes32,bytes32)((bool,(uint256,address,uint8,uint8,(bytes32,bytes32,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint64,uint32,uint64,bytes32,string),address[],uint64,uint64)))" \
  $CHAIN_KEY $ASSET_ID --rpc-url $RPC

# 2. Fetch the body named by reportURI, then re-hash it
kay9-watchdog hash ./report.json
# -> must equal result.reportHash, byte for byte
```

If the hashes differ, the body is not the one the auditors signed. Reject it. No amount of
plausible-looking JSON substitutes for that check.

You can also re-run the analysis yourself. The engine is deterministic given its inputs, and the
inputs are all recorded in the report: re-run it at the same `analyzedAt` and the same
`analyzedAtBlock` and it reproduces the report byte for byte, including `observations` and the hash.
Reading a *different* block will legitimately give a different report, because the chain has moved
on — the pin is what makes the two comparable at all.

---

## 9. Auditor mechanics

### 9.1 The loop

```
scheduled wake (or optional nudge)  ->  read AuditRequested since cursor
   ->  check attestationOf(jobId, self) on-chain  ->  analyse at job.requestedAt
   ->  pin report  ->  build AuditResult  ->  sign EIP-712  ->  verify own signature
   ->  publish signature  ->  attest (alone, or with an agreeing peer's signature)
```

Each auditor is a stateless job: it wakes, reads, analyses, signs, submits and exits. Its only
durable state is a cursor recording the last block it scanned, and losing that cursor costs a
re-scan, not a wrong answer.

The idempotence check is deliberately **on-chain** rather than in the auditor's own storage. A lost
cursor, a duplicate event, a retry, a cold start or a second concurrent invocation must not be able
to produce two attestations, and only the chain knows for certain whether this auditor has already
taken a position. A transaction that reverts with `AlreadyAttested` is treated as success.

### 9.2 Why three independent analyses can agree

A two-of-three quorum only means something if two honest auditors, running separately, reach the
same answer without talking to each other. Most risk analysis is not naturally like that, so the
protocol makes agreement structural:

- **The moment is chosen by the chain.** Every auditor analyses the asset as of `job.requestedAt`,
  written into the job by the hub when the request landed, and resolves it to the target chain's own
  RPC height the same deterministic way. All three read the same historical state.
- **The deterministic core is recomputed by all three, in full.** Bytecode capabilities, proxy
  slots, ownership, transfer-fee logic, pool discovery and reserves, holder balances folded from the
  complete `Transfer` log, the deployer and the deployment block, and the early-buyer window are
  pure functions of chain state at a fixed block.
- **The probabilistic layer is quantised.** Wallet clustering, Sybil scoring, wash-trading
  likelihood, insider-group detection and creator fingerprinting are not bit-reproducible even
  between honest implementations, so each emits a score rounded to the nearest 5 and a flag bit,
  never a raw float. A coarse grid lets three independent computations agree on a value without
  coordinating on one, while still being three independent computations.
- **The report body is canonical bytes** (§8.2), so agreement on the verdict is agreement on the
  hash.

Nothing is signed by an auditor that the auditor did not compute. `docs/AUDITOR_NETWORK.md` §2 is
the full treatment.

### 9.3 Submission

Any auditor or relay may broadcast. The ordinary path is one transaction carrying two agreeing
signatures; the second signature is redundant work if a peer already landed it, so an auditor
re-reads the job before broadcasting and treats a job that is no longer `Requested` as done. A
disagreeing auditor broadcasts its own signature alone, which is what turns a disagreement into a
public `Disputed` state rather than into silence.

---

## 10. Using the protocol directly

Everything below works against the deployed contracts with no website involved. Set `RPC`, `HUB`,
`VAULT`, `REGISTRY`, `PRICING`, `KAY9` and `AUDITORS` to the deployed addresses.

### Open an access period

```bash
# What does a deep access lock require right now, and is pricing available at all?
cast call $VAULT   "quoteLock(uint8)(uint256,uint256)" 1 --rpc-url $RPC
cast call $PRICING "pricingStatus()((bool,uint256,uint256,uint256,uint64,uint32,uint64,uint64,uint128,uint8))" --rpc-url $RPC

# Lock, accepting at most 5% over the quote
REQ=$(cast call $VAULT "quoteLock(uint8)(uint256,uint256)" 1 --rpc-url $RPC | head -1)
MAX=$(python3 -c "print(int($REQ) * 105 // 100)")
cast send $KAY9  "approve(address,uint256)" $VAULT $MAX --rpc-url $RPC --private-key $PK
cast send $VAULT "lock(uint8,uint256)" 1 $MAX --rpc-url $RPC --private-key $PK

# What do I hold, and what is left?
cast call $VAULT "accessOf(address)((uint8,uint64,uint64,uint32,uint32,uint32,uint32,uint256,uint256,uint256))" $ME --rpc-url $RPC
cast call $VAULT "deepRemaining(address)(uint32)" $ME --rpc-url $RPC
cast call $VAULT "canRequest(address,uint8)(bool)" $ME 1 --rpc-url $RPC
```

### Request an audit

```bash
CHAIN_KEY=$(cast keccak "eip155:4663")
ASSET_ID=$(cast call $REGISTRY "evmAssetId(address)(bytes32)" 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 --rpc-url $RPC)

# tier 1 = deep, declaredRequesterKind 1 = independent
cast send $HUB "requestAudit(bytes32,bytes32,uint8,uint8)" $CHAIN_KEY $ASSET_ID 1 1 \
  --rpc-url $RPC --private-key $PK
```

### Follow the job

```bash
cast call $HUB "getJob(uint256)((address,bytes32,bytes32,uint8,uint8,uint64,uint64,uint64,uint8,uint8,uint256))" 1 --rpc-url $RPC
# status: 0 None, 1 Requested, 2 Fulfilled, 3 Disputed, 4 Expired

cast call $HUB "bestAgreement(uint256)(uint8)" 1 --rpc-url $RPC
cast call $HUB "attestationOf(uint256,address)(bytes32)" 1 $SOME_AUDITOR --rpc-url $RPC
cast call $HUB "jobExpiresAt(uint256)(uint64)" 1 --rpc-url $RPC
```

### Read the result

```bash
# One call, for a wallet, DEX, launchpad or badge
cast call $REGISTRY "latestSummary(bytes32,bytes32)(bool,uint256,uint8,uint64,uint32,uint64)" \
  $CHAIN_KEY $ASSET_ID --rpc-url $RPC

# Risk over time
cast call $REGISTRY "historyCount(bytes32,bytes32)(uint256)" $CHAIN_KEY $ASSET_ID --rpc-url $RPC
cast call $REGISTRY "scoreHistory(bytes32,bytes32,uint256,uint256)(uint64[],uint8[])" \
  $CHAIN_KEY $ASSET_ID 0 100 --rpc-url $RPC
```

Then fetch `reportURI`, run `kay9-watchdog hash report.json`, and compare with `reportHash`. Render
`committedAt` with anything you render from `latestSummary`; a score without its date is a claim
about the present that nobody made.

### Expire a job nobody answered

```bash
cast call $HUB "slaSeconds()(uint64)" --rpc-url $RPC
cast send $HUB "markExpired(uint256)" 1 --rpc-url $RPC --private-key $PK
```

Permissionless after the SLA. The requester's quota unit goes back to the period it came from.

### Close or continue an access period

```bash
cast send $VAULT "unlock()"  --rpc-url $RPC --private-key $PK           # whole principal back
cast send $VAULT "renew(uint8,uint256)" 1 $MAX --rpc-url $RPC --private-key $PK
cast send $VAULT "upgrade(uint256)" $FORENSIC_MAX --rpc-url $RPC --private-key $PK
```

### Auditor: check the digest before signing

```bash
cast call $HUB "hashResult(uint256,(bytes32,bytes32,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint64,uint32,uint64,bytes32,string))(bytes32)" \
  1 "($CHAIN_KEY,$ASSET_ID,62,71,40,55,35,35,12,0,131153,1000000,1780000000,$REPORT_HASH,ipfs://bafy...)" \
  --rpc-url $RPC
```

That value must equal what the local signer computed. `services/audit-worker` verifies its own
signature with `verifyTypedData` before publishing it, precisely so that a bad signature never
reaches a peer and wastes another auditor's gas.

### Attest

```bash
cast send $HUB "attest(uint256,(bytes32,bytes32,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint8,uint64,uint32,uint64,bytes32,string),bytes[])" \
  1 "($CHAIN_KEY,$ASSET_ID,62,71,40,55,35,35,12,0,131153,1000000,1780000000,$REPORT_HASH,ipfs://bafy...)" \
  "[$SIG_A,$SIG_B]" \
  --rpc-url $RPC --private-key $PK
```

Two agreeing signatures in one call is the ordinary path. One signature alone is a valid vote and is
how a disagreeing auditor records its position.

### Inspect the auditor set

```bash
cast call $AUDITORS "auditors()(address[])" --rpc-url $RPC
cast call $AUDITORS "threshold()(uint8)" --rpc-url $RPC
cast call $AUDITORS "isAuditor(address)(bool)" $SOME_ADDRESS --rpc-url $RPC
```

---

## 11. What the protocol does not promise

- **Not a guarantee.** A high score means the engine observed nothing risky in the sources it could
  reach at one block. Assets change; an upgradeable contract can be made to behave differently five
  minutes after a report is committed. `KAY9 Audit Completed` and `KAY9 Technical Risk` are the
  permitted phrasings; `KAY9 Verified Safe` is not, anywhere, ever.
- **Not investment advice.** A trust score is a description of observable properties, not a
  recommendation to buy, sell or hold anything.
- **Not a substitute for reading the code.** Static bytecode analysis finds capabilities, not
  intent, and cannot tell whether a function is reachable, guarded, or already renounced in some
  path the engine did not model.
- **Not exhaustive.** Liquidity is probed at known venues only. Holder concentration is sampled. Log
  scans are bounded. Every bound is stated in the report's `notes`.
- **Not a claim of intent.** A report describes what the code can do and what the wallets did. It
  does not accuse anyone of fraud, and language asserting criminality is out of scope for the
  engine's output.
- **Not proof against a dishonest majority.** The threshold protects against a single dishonest
  auditor, not against two of the three. At launch two of the three auditor identities run inside
  accounts the project owner controls, which `docs/AUDITOR_NETWORK.md` §4.3 states plainly and
  `docs/SECURITY.md` carries as a named limitation.
- **Not censorship-proof at the report layer.** Auditors can decline to analyse an asset. They
  cannot alter a committed result, and anyone can run the engine themselves and publish a competing
  report through a quorum they assemble.
