# The two registries

Where KAY9 puts what it has found, and what each record is actually claiming.

There are two, and they are separate contracts on purpose. Which one a record lives in tells you
what kind of claim it is, before you read a single number.

| | `KAY9ScanRegistry` | `KAY9Registry` |
|---|---|---|
| Holds | automatic basic scans, in Merkle batches | signed DEEP and FORENSIC reports |
| The claim is | **reproducibility** — run the engine at this block and get these bytes | **consensus** — independent auditors agreed |
| Who stands behind it | one authorised publisher | 2 of 3 separately operated auditors |
| Written by | `commitScanBatch` | `recordReport`, called by `KAY9AuditHub` |
| Volume | thousands a day | as many as are requested |
| Costs the subject | nothing | nothing |

Collapsing these into one contract would have been cheaper to build and would have destroyed the
distinction a reader most needs. A basic scan is not a weaker audit; it is a different kind of
statement. See `docs/BASIC_SCAN.md` for what the scans contain and `docs/AUDIT_PROTOCOL.md` for how
the signed tiers reach agreement.

---

## 1. Identity: how an asset is named

Both registries key on the same pair, and neither knows anything about a token's name.

```solidity
function assetKey(bytes32 chainKey, bytes32 assetId) public pure returns (bytes32);
```

- **`chainKey`** is `keccak256(caip2)` — `keccak256("eip155:4663")` for Robinhood Chain,
  `keccak256("solana:mainnet")` for Solana. The constants are on `KAY9Registry`:
  `CHAIN_ROBINHOOD`, `CHAIN_ROBINHOOD_TESTNET`, `CHAIN_BNB`, `CHAIN_SOLANA`.
- **`assetId`** is `bytes32(uint256(uint160(token)))` on an EVM chain — `evmAssetId(address)` does
  it — and the raw 32-byte mint on Solana.

Names and symbols are deliberately absent. A name is a string the token hands to anybody who asks
and can change afterwards; paying gas to store a claim the subject controls would be storing the
wrong thing. The website reads them from the token contract in the visitor's browser instead.

Because the chain key travels with every record, both registries can hold results about assets on
chains they do not live on. The registry is on Robinhood Chain; a report about a BNB token is
indexed under the BNB chain key.

## 2. `KAY9ScanRegistry` — commitments to basic scans

### What a batch is

```solidity
function commitScanBatch(
    bytes32 root,
    uint32 count,
    uint32 engineVersion,
    string calldata uri,
    ScanSummary[] calldata summaries
) external returns (uint256 batchId);
```

Every scan in the batch is committed to `root`. Only the ones passed in `summaries` are also
indexed on chain and emit a per-asset `AssetScanned` event.

That split is a measured cost decision, not a shortcut. Writing one asset's headline numbers costs
about 24,700 gas. Robinhood Chain produced 20,000–50,000 launches a day when this was measured
(`docs/RESEARCH.md`), so indexing every scan individually is not a design, it is a bill. Committing
all of them to a root and indexing the ones worth reading directly keeps both the proof and the
economics. `MAX_BATCH` is 500. `count` may not be smaller than the number of indexed summaries —
`CountTooSmall` — because a batch cannot contain fewer scans than it indexes.

### The per-asset event

```solidity
event AssetScanned(
    bytes32 indexed chainKey,
    bytes32 indexed assetId,
    uint256 indexed batchId,
    uint8   overallTrust,
    uint8   confidence,
    uint64  flags,
    uint64  scannedAtBlock
);
```

It is indexed by asset so a reader can follow one token through its scans with `eth_getLogs`,
without an index anybody has to host. This is the event the live feed is built from — the feed is
therefore something anybody can rebuild, not a view onto a KAY9 database.

`scannedAtBlock` is **the chain's own height**, not the number a contract reads in `block.number`.
Robinhood Chain runs two clocks and they are hours apart in nominal value; see `docs/RESEARCH.md`
before comparing this to anything.

`flags` is the `uint64` bitmask defined in `packages/chain/src/flags.ts`. Bit numbers are binding
and shared with the signed reports.

### Latest, and what "latest" means

```solidity
function latestScan(bytes32 chainKey, bytes32 assetId)
    external view returns (bool scanned, uint256 batchId, uint8 overallTrust);
```

Storage keeps only the most recent scan per asset, packed into one slot. The history is the log,
not an array — which is deliberate: the contract holds what a reader needs cheaply, and anybody who
wants the sequence reads `AssetScanned` and gets exactly what KAY9's own feed uses.

`scanned` false means **no scan is on record**, which is not the same as a scan that found nothing.
A caller that renders the absence as a score of zero is reporting something the chain did not say.

### Verifying one scan

```solidity
function verifyScan(uint256 batchId, bytes32 leaf, bytes32[] calldata proof)
    external view returns (bool);
```

This is the function a third party calls to satisfy itself that a scan it was shown really belongs
to a committed batch. The leaf construction is mirrored in `packages/chain/src/scan-batch.ts` and
pinned in tests against a `cast`-computed vector, so the TypeScript and the Solidity cannot drift
apart quietly. Pairs are sorted and leaves are double-hashed, the standard shape.

### The trust boundary, stated plainly

The indexed `summaries` are **trusted from the publisher**. The contract does not prove each
summary against the root on chain, because doing so would cost more than the summaries save and
would defeat the batching that makes this affordable at all.

So:

- A batch root is a **commitment**. It cannot be changed afterwards, and any scan can be proven to
  belong to it.
- An indexed summary is the **publisher's assertion** about one asset in that batch.
- Neither is agreement by anybody else. That is what `KAY9Registry` is for.

An authorised publisher that indexed a summary inconsistent with its own root would be publishing
evidence against itself, permanently. That is the design's actual defence, and it is a different
thing from a proof.

## 3. `KAY9Registry` — signed reports

### Appended, never overwritten

`recordReport` is callable only by the bound `KAY9AuditHub`, which binds it immutably at
deployment. Reports are appended. `latest` means *most recent snapshot*, never *current safety* —
a token can become dangerous one block after a clean report, which is what monitoring is for.

Each record carries the `AuditResult`, the `ReportMeta`, and the **signer set** that attested to
it. The signers are part of the record because the claim being made is "these operators agreed",
and a claim about who agreed is worthless without their names.

### Reading it

```solidity
function reportCount()      external view returns (uint256);
function getReport(uint256 reportId)  external view returns (ReportRecord memory);
function getReports(uint256 offset, uint256 limit) external view returns (ReportRecord[] memory);

function historyCount(bytes32 chainKey, bytes32 assetId) external view returns (uint256);
function history(bytes32 chainKey, bytes32 assetId, uint256 offset, uint256 limit) external view;
function latest(bytes32 chainKey, bytes32 assetId) external view returns (bool exists, ReportRecord memory);
function latestSummary(bytes32 chainKey, bytes32 assetId) external view;
function latestSummaryForToken(bytes32 chainKey, address token) external view;
function scoreHistory(bytes32 chainKey, bytes32 assetId, uint256 offset, uint256 limit) external view;
```

`historyCount` returning zero is the cheapest honest answer to "has this been audited" — one word
from the chain rather than a report body nobody is going to read. It is what the live feed's
deep-report filter asks.

`scoreHistory` returns two parallel arrays rather than an array of structs, because the read behind
a risk-over-time chart wants numbers and not report bodies.

`latestSummaryForToken` takes an `address` instead of an `assetId` for callers that have a token
address in hand and should not have to know the encoding.

### Requester neutrality

Paying nothing and declaring nothing can change a score. A requester's self-declaration of who they
are is recorded as **declared and unverified** unless flag bit 18 is set. `declaredRequesterKind`
on the record is exactly that: what somebody said about themselves, stored as a claim rather than
as a fact. An unsolicited watchdog report has requester `address(0)` and tier `0`, because nobody
asked for it.

## 4. Deployment order, and why the registries come first

The registries and the audit hub deploy **before** the token. That is a product decision with a
contract consequence: `KAY9AuditHub.accessVault` is not immutable, so the hub can exist before
`KAY9AccessVault` does. Until a vault is set, `requestAudit` reverts with `AccessVaultNotSet` while
`publishWatchdogReport` works normally — which is what makes an unsolicited pre-token report
possible. `setAccessVault` is callable once (`AccessVaultAlreadySet`).

The registry binds its hub immutably. The hub does not bind its vault immutably. The asymmetry is
deliberate and is the whole reason the product can be useful before the token exists.

## 5. Reading the registries without KAY9

Everything above is a public contract call or an event. To rebuild the feed:

1. Read `AssetScanned` logs from `KAY9ScanRegistry` over whatever window you want. Mind the
   10,000-matched-log cap and the ~250,000-block safe chunk size documented in `docs/RESEARCH.md`.
2. Read `ReportRecorded` logs from `KAY9Registry` for the signed side.
3. Join them on `(chainKey, assetId)`.

Addresses for each deployed chain live in `packages/chain/deployments/`. An empty file there means
**not deployed** — which is a different statement from "deployed and empty", and the site is
required to say so rather than showing zeroes.

## 6. What neither registry claims

- Neither says a token is safe. The permitted phrasings are "KAY9 Audit Completed",
  "KAY9 Technical Risk" and "KAY9 Monitored".
- Neither describes a token *now*. Every record belongs to the block it was taken at.
- A missing record is not a clean record. No entry means nobody looked, not that nothing was found.
- Scores are **trust**: 100 is the most trustworthy reading, 0 the worst, and an unmeasured
  dimension is never a 100.

## 7. Related documents

| Document | What it covers |
|---|---|
| `docs/BASIC_SCAN.md` | What a basic scan reads, and how to reproduce one |
| `docs/AUDIT_PROTOCOL.md` | The signed tiers and the 2-of-3 quorum |
| `docs/CONTRACT_INTERFACES.md` | The binding ABI spec — change it before changing code |
| `docs/KAY9_INTEGRATION_STANDARD.md` | Reading these registries from another product |
| `docs/BADGE_INTEGRATION.md` | Showing a record on your own site |
| `docs/ACCESS_MODEL.md` | How access to the signed tiers is granted |
