# The basic scan

The free tier. What it reads, what it refuses to say, and how to check it yourself.

**Under 60% coverage there is no headline.** When less than 60% of the category weight could be
measured, the record carries no headline score or risk band: the engine sets record-level flag bit
20, `LOW_COVERAGE`, and every KAY9 surface draws "Insufficient data" and the measured share instead
of a number. The categories that were measured keep their own numbers. A weighted mean over two
categories once drew "Trust 94 — Low risk" for a token whose holders, liquidity and trading nobody
could read, and the headline is what a reader takes away. The discovery worker does not give such a
scan a one-call `latestScan` summary; it stays in its batch and is provable against the root.

A basic scan is a **reproducibility claim**, not a consensus one. One engine reads one chain at one
pinned block and publishes what it found. Nobody signs it and nobody agreed with it. Its whole
authority is that you can run the same engine against the same block and get the same bytes. That
is a different and weaker claim than a DEEP or FORENSIC report, where three separately operated
auditors independently reach the same result and two of them must agree before anything is
committed. Do not read one as the other; see `docs/AUDIT_PROTOCOL.md` for the signed tiers.

---

## 1. What a basic scan is for

Robinhood Chain produced between 20,000 and 50,000 token launches a day when this was measured,
against roughly 600 a day that reached a real pool (`docs/RESEARCH.md`). Nobody is going to pay for
an audit of a token that will not exist in an hour, and nobody should have to, so the cheapest
useful reading is free and automatic.

The basic scan answers one question: **what can be established about this token by reading the
chain, cheaply, right now?** Contract powers, liquidity, holder concentration, early activity. It
does not answer whether a token is a good investment, whether the team is honest, or whether the
project will still exist next week. No tier of this product answers those.

## 2. The scale reads like a school mark, on purpose — with one exception

Every score is **trust**: 0 is the worst reading the engine can give, 100 is nothing risky found. A
nearly full ring means a trustworthy reading, the same direction every other progress meter a
reader has ever seen already trained them to expect, and that is why every surface that shows a
number also names the axis anyway (`DESIGN.md` §2.1) — a reader should never have to infer which
axis a number is on.

Two things still hold, unchanged by which way the number runs:

- **`overallTrust` is a `uint8` on chain**, on `AuditResult` and on `KAY9ScanRegistry.ScanSummary`,
  read by third parties through `docs/KAY9_INTEGRATION_STANDARD.md`. What the site shows and what
  the chain holds are the same number under the same name — the engine converts internally
  (`toTrustScores` in `services/watchdog/src/engine/scoring.ts`) before either is ever signed.
- **Nothing here may say a token is safe.** A 100 is "nothing risky was found by this engine at
  this block", never a certificate. The permitted phrasings and band labels never use the word
  *safe* or *verified*, and that rule does not bend just because the number is now at the top.

**Missing evidence still never looks clean — it caps trust rather than raising risk.** The
mechanism inverted along with the scale (an unmeasured category is held at or below a ceiling
now, rather than raised to a floor), but the guarantee it exists to protect did not: **unmeasured
is not a perfect score.** A scan that could not read a token's holders does not report full holder
trust; it reports that the dimension was not measured, the confidence figure falls, and the
category's trust score can never exceed the uncertainty ceiling as a result.

## 3. Confidence is a separate number, and it is not a discount

Every scan carries `overallTrust` **and** `confidence`, both 0–100, and they mean different things:

| | Question it answers |
|---|---|
| `overallTrust` | How much risk did the engine find? |
| `confidence` | How much of what it wanted to look at could it actually see? |

A high score with low confidence is **not** reassurance. It means the engine did not find much
because it could not look at much, not that the token is clean. The feed marks those rows, and any
surface showing a score without its confidence is misreporting it.

Confidence falls when the RPC refuses a range, when historical state is pruned, when a token does
not answer a standard call, and when a log window is truncated by the request budget. It never
falls because a token looks suspicious — that is what the score is for.

## 4. What it reads

The engine is `services/watchdog`. Every read is pinned to one block height before anything runs,
so two operators reading the same height see the same chain (`adapters/evm/index.ts`).

**Contract state** (`adapters/evm/core.ts`) — bytecode is fetched and searched for the selectors
that grant power over other people's balances: mint, pause, freeze, blacklist, fee changes,
upgradeable proxies. Ownership is resolved to one of three states, never guessed:

- *known active* — an owner or role holder answered and is a live account
- *proven revoked* — the contract answered, and the answer establishes the power is gone
- *unknown* — `owner()` reverted, is absent, or the role scheme is unrecognised

A dangerous selector with **unknown** authority is not downgraded. The absence of an `owner()`
function is not evidence that nobody can call `mint()`.

**Liquidity** (`adapters/evm/liquidity.ts`) — pools are enumerated from the venue's own
`Initialize` events rather than derived from a guessed pool key, so a pool that is reported is a
pool that exists. Uniswap v4 keeps every pool's tokens inside one PoolManager, so v4 depth is read
through the state view rather than from a per-pool balance.

**Holders** (`adapters/evm/holders.ts`) — folded from Transfer logs and confirmed with balance
reads, bounded by the tier's budget. Pools, the token contract and burn addresses are excluded from
concentration, because they are not people.

**Early activity** (`adapters/evm/activity.ts`) — who acquired tokens in the first blocks. The
distinction that matters here is between a *purchase* and a *movement*: a transfer out of a known
pool is a purchase, a transfer out of the zero address is issuance, and anything else is a movement
whose meaning a Transfer log does not establish. When no pool address is known, the engine reports
that early buying could not be measured rather than treating every transfer as a buy.

## 5. Bounds, and why they are printed

Every window is bounded, because this runs against a public RPC that refuses a query matching more
than 10,000 logs and rate-limits three calls in a row (`docs/RESEARCH.md`).

A bounded sample is fine. A bounded sample that **hides its bounds** is not, because a reader will
take silence for absence. So a transfer window reports:

- `coveredToBlock` — the last block the sample actually accounts for
- `missingRanges` — exactly which blocks are not covered, and therefore which blocks nothing may be
  concluded about
- `truncated` — whether the budget ran out before the window was covered

Truncation is deterministic. Logs are deduplicated and sorted **before** the sample is cut, so the
surviving set is a function of the blocks read and not of the order a provider happened to answer
in. Two honest operators on two endpoints get the same sample; if they did not, they would compute
different findings and hash different report bytes.

A failed chunk is recorded as missing rather than stepped over. "The request failed" and "nothing
happened here" are different facts and the report keeps them apart.

## 6. Where a scan comes from

Three routes, same engine:

1. **In your browser.** `/audit` runs the engine client-side against the public RPC. Nothing is sent
   to KAY9, nothing is stored, and no wallet is needed. What you get is a reading, not a record —
   it is not committed anywhere and not citable.
2. **The scan API.** `services/audit-worker` exposes the same engine over HTTP with a short cache.
   Results are cached per chain and per asset, with the asset's identity preserved exactly:
   hex addresses are case-folded, base58 mints are not, because base58 uses case as part of the
   identity.
3. **The watchdog, automatically.** Discovery finds new assets, the engine scans them, and the
   results are committed to `KAY9ScanRegistry` in Merkle batches. This is the route that produces a
   permanent public record — see §7 and `docs/TOKEN_DISCOVERY.md`.

## 7. What gets committed, and what a commitment proves

`KAY9ScanRegistry` (`packages/contracts/src/KAY9ScanRegistry.sol`) is deliberately separate from
`KAY9Registry`, because the two hold different kinds of claim. See `docs/KAY9_REGISTRY.md` for the
registry side.

A batch commits:

- a **Merkle root** over every scan in the batch,
- a **count**,
- an **engine version**,
- a **URI** for the batch body,
- and an *indexed subset* of `ScanSummary` structs.

The economics are the reason for that last split. Writing an asset's headline numbers on chain
costs about 24,700 gas; a chain producing tens of thousands of launches a day makes indexing all of
them absurd. So every scan in the batch is committed to the root, and the ones worth reading
directly on chain are also indexed. `MAX_BATCH` is 500.

**What a commitment proves:** that the publisher committed to these exact scan results at this
block, and that any individual scan can be shown to belong to the batch by a Merkle proof against
the root.

**What it does not prove:** that the results are correct, or that anybody other than the publisher
agrees with them. The registry trusts its authorised publisher for the indexed summaries — a
deliberate, documented trade-off, not an oversight. If you need agreement rather than commitment,
that is what the signed tiers are for.

## 8. Checking a scan yourself

The point of a reproducibility claim is that you can test it.

1. Take the scan's `scannedAtBlock`. This is the chain's own height — Robinhood Chain runs
   **two clocks** and this is not the number a contract sees in `block.number`
   (`docs/RESEARCH.md`).
2. Run the engine at that block: `npm run scan -w @kay9/watchdog -- --chain robinhood --asset <address> --at-block <n>`.
3. Compare the canonical report bytes, byte for byte. Not the score — the bytes. Two runs that
   agree on a score but disagree on the body are not reproducing anything.
4. Verify the leaf against the on-chain root with the batch's Merkle proof. The leaf construction
   is mirrored in `packages/chain/src/scan-batch.ts` and pinned against a `cast`-computed vector,
   so the TypeScript and the Solidity cannot drift apart silently.

If step 3 disagrees, the engine has a determinism bug and it is a defect worth reporting. If step 4
disagrees, the published batch does not contain the scan it claims to.

## 9. What a basic scan will never say

- That a token is safe, verified, approved, or endorsed. The permitted phrasings are
  "KAY9 Audit Completed", "KAY9 Technical Risk" and "KAY9 Monitored".
- That a high score means you should buy something. Nothing here is investment advice.
- That the absence of a finding is the absence of a problem. It is the absence of a finding within
  a stated bound, at a stated block, by one engine.
- That a score describes the token *now*. Every score belongs to the block it was taken at. A token
  can become dangerous one block after a clean scan, which is what monitoring exists for.

## 10. Related documents

| Document | What it covers |
|---|---|
| `docs/KAY9_REGISTRY.md` | The two registries, what each one stores, and how to read them |
| `docs/AUDIT_PROTOCOL.md` | The signed DEEP and FORENSIC tiers and the 2-of-3 quorum |
| `docs/AUDITOR_NETWORK.md` | Who the auditors are and where their code runs |
| `docs/TOKEN_DISCOVERY.md` | How new assets are found before they are scanned |
| `docs/SCORE_CALIBRATION.md` | How the scores were calibrated, and against what |
| `docs/BADGE_INTEGRATION.md` | Displaying a result on somebody else's site |
| `docs/RESEARCH.md` | The measured chain facts every bound here is derived from |
