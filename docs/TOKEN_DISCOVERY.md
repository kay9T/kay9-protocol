# Token discovery

How KAY9 finds out that a token exists, without anybody telling it.

Nothing in this document is a plan. Every address, event hash and rate below was measured against
Robinhood Chain mainnet (4663) on **2026-09-08**, and the catalogue the code reads from is
`services/watchdog/src/discovery/sources.ts` (main project; not included here),
which carries the same evidence next to each entry. Re-verify before production: launchpads
redeploy, and a topic0 that no longer appears is a source that has moved.

---

## 1. The finding that shaped the design

The assumption going in was that Robinhood Chain might be quiet, and that a "tokens detected"
counter would embarrassingly read zero. The measurement says the opposite.

| Metric | Measured | Per day |
|---|---|---|
| Blocks | 0.1012 s/block over 10 M blocks | ~854,000 |
| Transactions | 1,589 in 100 blocks | ~13.7 M (~159 tps) |
| ERC-20 `Transfer` logs | 14,572 in 31 s | ~40 M |
| Uniswap v4 pool initialisations | 831 in 1 h; 6,580 in 12 h | ~13,000–20,000 |
| **Token launches, all sources** | dominated by one launchpad | **~20,000–50,000** |
| **Graduations to a real pool** | 684 over 50,000 blocks | **~500–700** |

Re-measured on 2026-09-25 over three hours of chain time, for gate 2 of `docs/LAUNCH_READINESS.md`: 1,133 launches, 552 new v4 pools and 8 graduations, which is roughly 9,000 launches, 4,400 pools and 64 graduations a day. The graduation rate is an order of magnitude below the first estimate; the site quotes this later sample, with its date.

So the product problem is not "is there anything to show". It is **ranking and filtering**. A feed
of every new token is a feed of tens of thousands of bonding-curve tokens a day, almost all of
which never take a second buyer, and a scan queue drained in arrival order would spend its entire
budget on them while the one token that graduated with real money in it waited behind 30,000
others.

Two consequences run through everything else in this document:

1. **Discovery and scanning are separate problems.** Discovery is cheap — a handful of
   `eth_getLogs` calls covers the whole chain. Scanning is not. So KAY9 discovers everything and
   scans in a deliberate order.
2. **A launch count is not an achievement.** No KAY9 surface may present "42,000 tokens detected
   today" as a measure of its own usefulness. It is a measure of how much noise the chain
   produces. The number that means something is how many of them were *worth* looking at.

---

## 2. What counts as a discovery

A token is discovered when a contract KAY9 watches emits an event that means a token exists which
KAY9 has not seen before. Three kinds, and the difference matters:

| Kind | Meaning | Volume |
|---|---|---|
| `launch` | A token now exists, usually on a bonding curve. Nobody may have bought it. | ~20,000–50,000/day |
| `graduation` | A token reached a real pool with real liquidity. | ~500–700/day |
| `pool` | A Uniswap v4 pool was initialised, by a launchpad or by nothing KAY9 recognises. | ~13,000–20,000/day |

**KAY9 does not watch every ERC-20 deployment.** It would be the wrong signal in both directions:
contract creations by an EOA measure ~8,600/day, which *understates* token creation by an order of
magnitude because almost everything here is deployed by a factory through `CREATE2` and is
invisible to a `to == null` scan; while watching every `Transfer` would mean 40 million logs a day
to learn nothing a launch event does not already say.

---

## 3. The sources

Every address below answered `eth_getCode` with bytecode, and every `topic0` was both computed
from its signature and observed in live logs.

### Primary

| Source | Address | Event | Measured/day |
|---|---|---|---|
| **Pons** | `0x7ed598bc…ec7e` | `TokenLaunched` | 42,104 |
| **Pons** | same | `PoolGraduated` | 684 |
| **Uniswap v4 PoolManager** | `0x8366a39C…0951` | `Initialize` | ~16,500 |
| **Liquidity Launcher** | `0x0000ffff…19c0` | `TokenCreated` | 393 |
| **Doppler Airlock** | `0xeb7c0347…0862` | `Create` | 3,116 |
| **LongLauncher** | `0x22e99278…eeed` | `LaunchCreated` | 2,945 |
| Flap.sh | `0x26605f32…eb09` | `TokenCreated` | 85 |
| Klik Finance | `0x16cf6788…0dd7` | `ERC20TokenCreated` | 51 |
| trench.today | `0x77dc6f63…3f9d` | `TokenCreate` | 34 |
| Bags.fm | `0xe8cc4431…cb37` | `TokenCreated` | 34 |

### Dormant

Virtuals, hood.fun, LaunchHood, Ape.store and Clanker all hold code but emitted nothing in the
measurement window. They are recorded as dormant rather than omitted, because a quiet launchpad
today is not a quiet one next week, and "we looked and it was quiet" is a more honest record than
an unexplained gap. Nothing subscribes to them until one is seen to emit, so a dormant address
costs no requests.

### Two things a reader has to know

**The Liquidity Launcher is KAY9's own launch path.** `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0`
is byte-for-byte the `liquidityLauncher` in this project's address book, and third-party indexers
surface it as a launchpad entry contract. So **$KAY9 will appear in KAY9's own discovery feed**,
and it must. A watchdog that quietly omitted its own token would be worth nothing, and the scan
priority explicitly refuses to de-rank that source.

**The Uniswap `Initialize` topic layout is a trap.** `topics[1]` is the **poolId**, not a currency;
`topics[2]` and `topics[3]` are currency0 and currency1, and the data words follow as `fee`,
`tickSpacing`, `hooks`, `sqrtPriceX96`, `tick`. Reading `topics[1]` as a currency produces pairs
where currency0 sorts above currency1, which Uniswap v4 cannot produce — that impossibility is the
tell, and there is a test for it.

---

## 4. Decoding, and refusing to decode

Several of these events had their argument names and types recovered from a public signature
database rather than from the project's own ABI. The `topic0` hashes are exact keccak values and
were observed live; the field layout beyond the indexed addresses is the part that could be wrong.

So the adapters read only what an event's shape guarantees — an indexed address is an indexed
address — and return nothing rather than a guess. Concretely:

- A topic is only read as an address if its upper 24 nibbles are zero. A 32-byte poolId therefore
  cannot become a contract address.
- A data word past the end of the data is `undefined`, never `0`. A truncated event loses its
  optional fields and keeps its token.
- An adapter **never throws** on a log it cannot understand. On a chain where anyone can deploy
  anything, logs that do not match the signature they appear to are normal; one of those must cost
  a skipped log, not a stalled discovery pass. Skips are counted and reported, so a source that
  has silently changed its events shows up as a climbing skip count rather than as a feed that
  quietly went empty.

A discovery is deliberately thin: chain, token address, source, kind, block, and whatever optional
fields the event guaranteed. Everything about whether the token is any good comes from the basic
scan, which reads the chain itself. Mixing the two would let a decode become a risk claim.

---

## 5. Reading logs from an RPC that refuses naive questions

Three measured limits, all re-verified 2026-09-08:

1. **A 10,000 matched-log ceiling.** `eth_getLogs` refuses with "logs matched by query exceeds
   limit of 10000". The busiest feed puts ~9,300 matches in 300,000 blocks, so the starting chunk
   is **250,000 blocks** and shrinks during bursts. The ceiling is not applied uniformly — a
   topic-only query with no `address` filter returned 14,873 without complaint — so 10,000 is
   treated as the hard budget regardless.
2. **Wide ranges time out.** A 10,000,000-block query on a rare topic answered `log query timed
   out`. An earlier note in `docs/RESEARCH.md` said such spans succeed. It has been corrected;
   nothing relies on it.
3. **Three calls back to back are refused** with `Too Many Requests`, while JSON-RPC *batch*
   requests succeeded reliably at 100 items. Log queries are therefore serialised with a gap, and
   a rate limit is treated as "wait", not as an error to surface.

`logs.ts` (main project; not included here) is the only place that talks to
`eth_getLogs` for discovery, and it:

- **shrinks before the ceiling, not after** — a chunk that comes back with ≥9,000 logs halves the
  next one, because a chunk near the cap is a chunk about to breach it;
- **stops on a rate limit** rather than pushing through and getting the key throttled;
- **reports the last block it actually covered**, never the end of the range it was asked for. A
  cursor can therefore only ever be behind. A token discovered twice is deduplicated by address; a
  token missed silently is gone.

### Which clock

Every block number in discovery is **the chain's own height** — what `eth_blockNumber` returns and
an explorer shows, advancing about every 0.1 s. That is what `eth_getLogs` ranges are expressed in.

It is **not** the `block.number` a contract reads on this chain, which is the parent chain's and
advances about every 12 s. The two differ by a factor of about 120. The auction and, since
2026-09-11, every KAY9 contract read the chain's own height through `ArbSys`; the one revision that
compared a launch window against `block.number` produced an auction that was over before its first
bid. See `docs/RESEARCH.md`.

---

## 6. Scan priority

Every discovery is scanned. The order is not arrival.

| Band | Value | Why |
|---|---|---|
| Graduated to a live pool | 100 | Real liquidity, real exposure. A few hundred a day. |
| KAY9's own launch path | 90 | Includes $KAY9. Never quietly de-ranked. |
| Pool created through a known hook | 80 | Attributable to a launchpad. |
| Pool created outside any known launchpad | 70 | Unusual, therefore interesting. |
| Quoted against a stablecoin or tokenised equity | 60 | A different kind of thing from another ETH memecoin. |
| Low-volume source | 50 | A few dozen a day; more likely deliberate. |
| Bonding-curve launch, not yet graduated | 10 | The firehose. Scanned, just not first. |

Inside a band, **oldest first**. Newest-first would starve anything that arrived during a burst,
and a token nobody ever gets round to is worse than one scanned late.

**Priority is a claim about attention, never about risk.** A low priority means "fewer people are
exposed to this yet", not "this is safe". Nothing in the product may render priority as a score,
and a queued token shows as `DETECTED` — not as anything reassuring. There is a test that the
reason strings contain no verdict words.

Priority is a pure function of the discovery, so two independent scanners drain their queues in the
same order and a disagreement between them is a real disagreement rather than a scheduling
artefact.

---

## 7. No database as the source of truth

`runDiscoveryPass` holds no state. It takes the cursors it was given and returns the cursors it
reached; the caller stores those wherever it likes.

This is the requirement that KAY9's record be rebuildable from the chain and immutable storage
alone. An engine that owned a database would quietly become the source of truth, and the one thing
this product may never say is "trust our index". Losing every cursor costs time, not truth:
discovery replays from any block, and a token seen twice is deduplicated by address.

The scan record itself lives on-chain in
[`KAY9ScanRegistry`](../src/KAY9ScanRegistry.sol), committed in Merkle batches,
with the batch document content-addressed. Anyone can rebuild the whole feed from those two things
and never ask kay9.io for anything.

---

## 8. What is not established

Recorded so that nobody later mistakes a gap for a fact.

- **Argument names and non-indexed layouts** for Doppler, LongLauncher, Flap.sh, Klik, trench.today
  and Bags.fm come from a public signature database, not from each project's ABI. The topic0s are
  exact and observed; the field layouts are not relied on.
- **Whether "pools.trade" is a Uniswap brand or a third-party front-end** over the Liquidity
  Launcher. The address identity is certain; the naming is not.
- **Whether HoodScan (`hood-chain.com`) exposes a Blockscout REST API.** Reachable and
  Blockscout-derived, but undocumented on its landing page and untested.
- **The full PONS token address.** The launchpad site truncates it and the pruned RPC cannot serve
  the historical lookup.
- **Pons' own documentation** was not fetched; every Pons fact here is from on-chain verification,
  which is the stronger evidence anyway.

---

## 9. Cost

Discovery is the cheap half. One pass over every source is roughly 10–15 `eth_getLogs` calls, and
at a five-minute interval that is ~4,000 calls a day, which fits inside a free RPC tier with room
to spare. Serialising them with a 250 ms gap keeps a pass under ten seconds.

The scanning that follows is what costs, and it scales with how much of the queue is drained
rather than with how much the chain produced. Figures per scan volume are in
`docs/DEPLOYMENT.md` (main project; not included here).

**A dedicated RPC is required before this runs continuously.** The public endpoint refuses three
log queries in a row; it is adequate for a five-minute discovery pass and not for draining a scan
queue.
