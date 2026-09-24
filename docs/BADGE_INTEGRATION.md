# Showing a KAY9 record on your own site

The badge, what it is allowed to say, and how to read the registries directly if you would rather
build your own.

The badge is a **live** component, not a picture. That is the single decision everything else here
follows from: a static "audited" image keeps saying 88 after a later report says 43, and a stale
reassurance is exactly the failure this product exists to catch.

---

## 1. What you may and may not claim

**Never** show a headline number for a record with flag bit 20 (`LOW_COVERAGE`) set, or for a
report whose `measuredWeight` is under 0.6. Show "Insufficient data" instead; `isHeadlineWithheld`
and `isCoverageTooLow` in `@kay9/chain` implement both checks.

These are not style preferences. They are the terms of using KAY9's name.

**Permitted phrasings, exactly:**

- KAY9 Audit Completed
- KAY9 Technical Risk
- KAY9 Monitored

**Never:**

- "KAY9 Verified", "KAY9 Verified Safe", "KAY9 Approved", "Audited and safe", or any wording that
  reads as a guarantee.
- A score presented without the date it was taken. A record describes one past block, not the
  token now.
- A score presented without its confidence, or with an unmeasured dimension rendered as zero.
  Unmeasured is not low risk.
- Any suggestion that a KAY9 record is investment advice.

**Also never:** re-hosting a score as an image, a cached JSON blob, or a number you refresh
nightly. If you cannot show a live reading, show a link instead. A number you cached is a claim you
are making, not one KAY9 made.

## 2. Higher is more trustworthy — but still name the axis

Scores are **trust**: 100 is the most trustworthy reading, 0 the worst. If you render your own
meter, a fuller bar means *more* trustworthy, matching every other progress bar a reader has ever
seen — but you must still name the axis beside the number, "Trust 92/100" rather than "92/100",
because a reader should never have to guess which axis a number is on. See `docs/BASIC_SCAN.md` §2.

Bands, from `packages/chain/src/bands.ts`:

| Band | Range | Colour token | Label |
|---|---|---|---|
| Green | 76–100 | `--ok` | Low risk |
| Amber | 41–75 | `--warn` | Elevated risk |
| Red | 0–40 | `--danger` | High risk |

Colour is never the only channel. Each band ships with an icon and a word.

## 3. The iframe embed

The simplest integration. One element, no JavaScript of yours, always current.

```html
<iframe
  src="https://kay9.io/badge/embed?chain=robinhood&asset=0xYourTokenAddress"
  title="KAY9 technical risk"
  width="320"
  height="76"
  style="border:0;max-width:100%"
  loading="lazy"
></iframe>
```

**Parameters**

| Name | Values | Notes |
|---|---|---|
| `chain` | `robinhood`, `bnb`, `solana` | The slug, not a chain id. `BADGE_CHAINS` in `components/badge/LiveBadge.tsx` is the source of truth. |
| `asset` | address, or a base58 mint on Solana | Case is preserved for base58, because base58 uses case as part of the identity. |
| `locale` | any of the thirteen | Optional. Falls back to English. |

The target arrives in the query string rather than the path because the site is a static export and
an unbounded set of token addresses cannot be prerendered as paths.

The badge fills its frame in standalone mode, so give the iframe the width you want and let the
content adapt. It respects the viewer's light/dark theme and reads right-to-left in the RTL
locales, with the address itself kept left-to-right.

**What it renders:** the score, the band in words, and the date the record was committed, linking
through to the full record on kay9.io. **What it renders when there is no record:** it says there is
no record. It does not show a zero, because "nobody has looked" and "we looked and found the worst
possible reading" are different statements and only one of them is true.

## 4. Reading the registries yourself

If you would rather build your own display, read the chain. There is no KAY9 API in the path and
nothing below needs a key.

Addresses per chain are in `packages/chain/deployments/`. **An empty file there means not
deployed** — which is not the same as deployed and empty, and your integration should say so rather
than showing zeroes.

### Identity

Both registries key on `(chainKey, assetId)`:

- `chainKey` is `keccak256(caip2)` — e.g. `keccak256("eip155:4663")`. Constants are on
  `KAY9Registry`: `CHAIN_ROBINHOOD`, `CHAIN_ROBINHOOD_TESTNET`, `CHAIN_BNB`, `CHAIN_SOLANA`.
- `assetId` is `bytes32(uint256(uint160(token)))` on EVM — `evmAssetId(address)` does it — and the
  raw 32-byte mint on Solana.

### A signed report

```solidity
// KAY9Registry
function latestSummary(bytes32 chainKey, bytes32 assetId) external view;
function latestSummaryForToken(bytes32 chainKey, address token) external view;
function historyCount(bytes32 chainKey, bytes32 assetId) external view returns (uint256);
```

`latestSummaryForToken` exists for callers holding a token address who should not have to know the
encoding. `historyCount` returning zero is the cheapest honest answer to "has this been audited".

### A basic scan

```solidity
// KAY9ScanRegistry
function latestScan(bytes32 chainKey, bytes32 assetId)
    external view returns (bool scanned, uint256 batchId, uint8 overallTrust);
function verifyScan(uint256 batchId, bytes32 leaf, bytes32[] calldata proof)
    external view returns (bool);
```

**Do not present a basic scan as an audit.** A scan is a reproducibility claim from one publisher;
a report is a consensus claim from independent auditors. If your badge shows both, label which one
the reader is looking at. `docs/KAY9_REGISTRY.md` sets out the difference in full.

To prove a scan you were shown belongs to a committed batch, rebuild the leaf and call
`verifyScan`. The leaf construction is mirrored in `packages/chain/src/scan-batch.ts`.

## 5. States you have to handle

A badge that shows four states and silently collapses the rest into "no report" is misinforming
people. These are different facts:

| State | What it means | What it must not look like |
|---|---|---|
| Loading | The read has not returned | A score of 0, or "no report" |
| No record | Nobody has looked at this asset | A clean result |
| RPC unreachable | You could not ask | No record |
| Stale | The record is old | Current |
| Unmeasured dimension | The engine could not read it | A 100 |
| Basic scan on record | One publisher committed to a reading | An audit |
| Signed report on record | Auditors agreed | A safety guarantee |

`freshnessOf` in `apps/web/src/components/LiveValue.tsx` is how the site draws that distinction if
you want the same behaviour.

## 6. Framing and embedding

The badge route sets headers that permit embedding on third-party origins — that is the point of it.
If your CSP restricts frames, allow `https://kay9.io`.

The embed makes its own RPC reads from the viewer's browser. It sends nothing to KAY9 about your
visitors, sets no cookie, and needs no wallet.

## 7. Checking a record before you rely on it

If your product will show a KAY9 number to other people, satisfy yourself about it first:

1. For a **scan**: reproduce it. Run the engine at the recorded `scannedAtBlock` and compare
   canonical bytes — not scores, bytes. `docs/BASIC_SCAN.md` §8 has the command.
2. For a **report**: read the signer set on the record. The claim is "these operators agreed", and
   the claim is only worth what their independence is worth. `docs/AUDITOR_NETWORK.md` says who
   they are and where their code runs.
3. Mind the clock. `scannedAtBlock` is the chain's own height, **not** the number a contract sees in
   `block.number`. Robinhood Chain runs two clocks and they differ by orders of magnitude in
   nominal value. See `docs/RESEARCH.md` before comparing heights to anything.

## 8. Related documents

| Document | What it covers |
|---|---|
| `docs/KAY9_INTEGRATION_STANDARD.md` | The binding integration spec, including flag bit numbers |
| `docs/KAY9_REGISTRY.md` | Both registries and what each record claims |
| `docs/BASIC_SCAN.md` | What a basic scan reads, and how to reproduce one |
| `docs/AUDIT_PROTOCOL.md` | The signed tiers and the 2-of-3 quorum |
| `DESIGN.md` | The design system, including the rule about naming the risk axis |
