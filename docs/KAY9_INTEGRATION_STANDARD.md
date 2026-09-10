# The KAY9 Integration Standard

How a wallet, a DEX, a launchpad, an explorer or a bot reads KAY9 risk data.

The whole standard is one sentence: **read the chain**. There is no API key, no rate limit, no
terms of service, no endpoint that can be turned off, and no request that reaches KAY9. Everything
below is a contract call or a log query against Robinhood Chain, and an integration built on it
keeps working whether or not KAY9 is still around to maintain it.

That is not generosity. A risk score that can only be obtained by asking its author is a score you
have to trust; one you read from a public ledger is a score you can check. The second is worth
something and the first is not, so the standard is built the only way it can be.

---

## 1. The two records, and which one you want

| | `KAY9ScanRegistry` | `KAY9Registry` |
|---|---|---|
| Holds | automatic basic scans | deep and forensic reports |
| Claim | **reproducibility** — this is what the published engine computes | **consensus** — two of three auditors signed this |
| Coverage | broad; every token discovery reaches | narrow; only what somebody requested |
| Cost to KAY9 | one transaction per batch | one transaction per report |
| Freshness | minutes to hours after a launch | when it was requested |

Most integrations want the scan registry: it is the one that has heard of the token your user just
pasted in. Reach for the report registry when a token has a deep report and you want the signed,
quorum-backed version.

**Never present one as the other.** A basic scan reads public state cheaply; a deep report is three
independent parties agreeing. Collapsing them into one "KAY9 score" throws away the distinction the
whole protocol exists to make.

---

## 2. The one call most integrations need

```solidity
(bool scanned, uint256 batchId, uint8 overallTrust) =
    scanRegistry.latestScan(chainKey, assetId);
```

- `chainKey` is `keccak256("eip155:4663")` for Robinhood Chain mainnet.
- `assetId` is the token address left-padded to 32 bytes.
- `overallTrust` is 0–100, where **100 is the most trustworthy reading the engine can give and 0 the worst**.

`scanned` exists because an unset `uint8` defaults to 0, the worst possible score. Without it,
"never looked at" and "looked at and found the worst possible reading" are the same answer, and
they are not remotely the same thing.

```solidity
bytes32 chainKey = keccak256("eip155:4663");
bytes32 assetId  = bytes32(uint256(uint160(token)));
```

For deep and forensic reports the equivalent single call is:

```solidity
(bool exists, uint256 reportId, uint8 overallTrust, uint64 flags, uint32 engineVersion, uint64 committedAt)
    = registry.latestSummary(chainKey, assetId);
```

`latestSummaryForToken(chainKey, address)` takes the address directly if you would rather not pad
it yourself.

---

## 3. Rules for displaying it

These are conditions of using the data, and they exist because the failure mode of a risk score is
somebody acting on a number they misread.

**Show the confidence, or show neither.** The scan publishes a score and a separate confidence, and
a high score with low confidence is not reassurance — it means the engine could not see enough. An
integration that renders the score alone converts "we don't know" into "it's fine". Confidence
comes from the `AssetScanned` event, or from the batch document.

**Never render a score as a verdict.** No ticks, no shields, no "KAY9 verified", no green padlock.
The permitted forms are the number, the band, and the flag names. A band is a range, not an
endorsement: `bandFor()` in `@kay9/chain` gives the canonical thresholds and colours.

**Say when it was measured.** Every record carries the block it was pinned to. A score from three
days ago describes the token as it was three days ago, and a token's risk can change in one
transaction. Show the block or the date beside the number.

**Say "not scanned" when it is not scanned.** The honest empty state is "KAY9 has no record of this
token", not a dash, not a zero, and not a hidden widget. On a chain producing tens of thousands of
launches a day, most tokens a user pastes in will be unscanned, and that is information.

**Never imply KAY9 approves of anything.** KAY9 does not call a token safe, has no allow-list, and
takes nothing from anybody in exchange for a score. An integration that suggests otherwise is
misrepresenting it.

---

## 4. Following a token over time

Scans are never overwritten. The history is the log, indexed per asset:

```
AssetScanned(bytes32 indexed chainKey, bytes32 indexed assetId, uint256 indexed batchId,
             uint8 overallTrust, uint8 confidence, uint64 flags, uint64 scannedAtBlock)
```

Filtering on `chainKey` and `assetId` gives one token's whole history in a single `eth_getLogs`
call — no replay of every batch ever committed. A score that moved from 80 to 20 is the single most
useful thing this data can tell a user, and it only exists because both readings are kept.

The equivalent for deep reports is `scoreHistory(chainKey, assetId, offset, limit)`, which returns
parallel arrays of timestamps and scores.

**Render a score history as a step chart, never as a line between points.** A sloping line implies
the score passed through intermediate values it never held. It held the old value until a new
measurement replaced it.

---

## 5. Verifying a scan yourself

You do not have to take the registry's word for a score, and the point of the batching is that you
do not have to take KAY9's word for the batch either.

1. Read the batch: `getBatch(batchId)` returns the Merkle `root`, the `count`, the `engineVersion`,
   the `scanner`, and a content-addressed `uri`.
2. Fetch the document at `uri`. It lists every scan in the batch in leaf order, with each leaf and
   its proof.
3. Recompute the leaf from the published fields:

   ```
   leaf = keccak256(keccak256(abi.encode(
       chainKey, assetId, overallTrust, confidence, flags,
       engineVersion, scannedAtBlock, reportHash
   )))
   ```

   Double-hashed so a leaf cannot be confused with an internal node. Internal nodes hash **sorted
   pairs**, so proofs carry no direction flags.
4. Check it on chain: `verifyScan(batchId, leaf, proof)`.

`@kay9/chain` implements all of this — `scanLeaf`, `buildScanBatch`, `verifyScanProof`, and
`checkScanBatchDocument`, which recomputes a whole document against its own root and tells you what
disagrees. The TypeScript and the Solidity are pinned against the same test vector, computed
independently, so they cannot drift.

**What the contract cannot check, and you can.** `commitScanBatch` publishes both the root and the
per-asset summaries, but it does not verify the summaries are the batch's leaves — that would mean
rebuilding the tree on-chain, which costs more than the record is worth. So a scanner that
published summaries its own root does not support is caught by the first person who runs step 3,
and the evidence stays on-chain permanently. Be that person occasionally.

---

## 6. Reading the whole feed

```
ScanBatchCommitted(uint256 indexed batchId, bytes32 indexed root, uint32 count,
                   uint32 engineVersion, string uri, address indexed scanner)
```

Every scan KAY9 has ever committed is reachable from these events plus the documents they point at.
An index rebuilt that way is byte-identical to KAY9's own, which is the property that matters:
**there is no proprietary database anywhere in this system**, and if there were, none of the above
would be checkable.

---

## 7. Rate limits and etiquette

The public RPC refuses three `eth_getLogs` calls issued back to back and caps a query at 10,000
matched logs. If you are building an index rather than answering one user's question:

- Batch your JSON-RPC calls. A batch of 100 succeeds where a loop of 100 is throttled.
- Chunk log queries to about 250,000 blocks and shrink during bursts.
- Use a dedicated endpoint. The public one is fine for a wallet asking about one token and not
  fine for a crawler.

`services/watchdog/src/discovery/logs.ts` is the reference implementation of all three, and is
MIT-licensed like everything else here.

---

## 8. Optional: making your own token easier to audit

If you are on the other side of this — a project that wants an automated audit to reach a fairer
conclusion — implement `IKAY9Auditable`
([`packages/contracts/src/interfaces/IKAY9Auditable.sol`](../src/interfaces/IKAY9Auditable.sol)).

It lets a token declare its controller, name the addresses that hold supply for a stated reason (a
vesting contract is not a whale), point at its documentation, and state its timelock delay.

**It is not a certification and it does not improve a score.** Nothing returned from it is trusted:
every value is checked against the chain, and a claim that disagrees with what the chain shows is
reported as a false claim — which is worse for the token than saying nothing would have been. What
it does is turn signals the engine currently has to mark *unmeasured* into ones it can measure,
which usually lowers uncertainty rather than risk.

---

## 9. Addresses

Contract addresses are in [`packages/chain/deployments/<chainId>.json`](../deployments)
and are exported by `@kay9/chain`:

```ts
import { getAddresses, abis } from '@kay9/chain';
const { KAY9ScanRegistry, KAY9Registry } = getAddresses(4663).kay9;
```

Until the registries are deployed those entries are the zero address, and `getAddresses().deployed`
is false. An integration should render that as "not live yet" rather than as a token with no
scans — the two are different claims and only one of them is true.
