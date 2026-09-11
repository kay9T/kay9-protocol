# KAY9 Watchdog

The watchdog is the part of KAY9 that actually looks at chains. It is two npm workspaces:

- **`services/watchdog`** (`@kay9/watchdog`) — the analysis engine and the chain adapters. A library with a CLI, no network services, no state. It runs in a Node process for an auditor and in the browser for a basic scan.
- **`services/audit-worker`** (`@kay9/audit-worker`) — the auditor job that turns engine output into signed, on-chain attestations, plus the pricing keeper and an optional convenience scan endpoint.

Neither holds protocol state. Delete an auditor's local storage and nothing on-chain changes; that auditor simply re-scans. That is the point: the services are replaceable without touching a contract.

Neither is a paid service either. No requester pays for an audit and no auditor is paid for one; `docs/ACCESS_MODEL.md` explains what a requester locks instead, and why. This document is about what the engine can and cannot see.

Sections 1 to 10 cover the engine and the auditor network — deep and forensic work, signed by a quorum, in response to a request. **Sections 11 and 12 cover the automatic loop**: discovery, free basic scans of whatever the chain launches, and the Merkle-batched record they are committed to. That loop runs before $KAY9 exists and is what makes the site worth visiting without one.

---

## 1. Architecture

```
                         ┌──────────────────────────────────────────┐
                         │  services/watchdog  (@kay9/watchdog)     │
   chainKey + assetId ──►│                                          │
   + tier                │   engine/analyze.ts                      │
                         │     ├── adapters/evm      (viem)         │
                         │     │     bytecode · balances · liquidity│
                         │     │     holders · activity             │
                         │     ├── adapters/solana   (native fetch)  │
                         │     │     mint parse · largest accounts  │
                         │     └── engine/scoring.ts (pure)         │
                         │                                          │
                         │   -> AuditResult + CanonicalReport       │
                         │      + reportHash = keccak256(canonical) │
                         └────────────────┬─────────────────────────┘
                                          │
        ┌─────────────────────────────────┴──────────────────────────────┐
        │        services/audit-worker  (@kay9/audit-worker)             │
        │        one stateless job per auditor; nothing stays awake      │
        │                                                                │
        │  worker.ts   wake → read AuditRequested since cursor           │
        │              → check attestationOf on-chain                    │
        │              → analyse at job.requestedAt                     │
        │              → pin → sign → attest → exit                      │
        │  keeper.ts   KAY9Pricing.poke() once a minute                  │
        │  scan-api.ts optional convenience endpoint, not canonical      │
        │  db.ts       a block cursor; losing it costs a re-scan         │
        └────────────────────────────────────────────────────────────────┘

        ┌────────────────────────────────────────────────────────────────┐
        │        the visitor's browser (apps/web)                        │
        │        the same engine at tier basic, against a public RPC     │
        │        no wallet, no KAY9, no job, no server to fail           │
        └────────────────────────────────────────────────────────────────┘
```

The engine is a pure function of its inputs plus whatever the chain returned. Scoring has no clock and no randomness, and signals are sorted before they are summed, so two runs over the same chain state produce byte-identical reports.

### Design constraints that shaped it

**Nothing the engine scores depends on a third party.** Every risk category is computed from standard JSON-RPC — `eth_call`, `eth_getLogs`, `eth_getCode`, `eth_getBlockByNumber`, `eth_getTransactionReceipt` — which any node implements and any auditor can self-host. There is no block explorer, no indexer and no hosted API in the scoring path, and no explorer is configured by default.

The reason is not hypothetical. The Robinhood mainnet Blockscout instance refused connections outright from the development network throughout this build — not a 500, not a timeout, a refusal before any HTTP status — and it is still refusing. An audit protocol whose reports degrade when someone else's website goes down is not an audit protocol. A block explorer is a convenience built on the same public data the engine already reads; where the engine can derive a fact itself, it does.

**Every data source is still assumed to fail.** An RPC that returns nothing produces `INSUFFICIENT_DATA` plus an uncertainty floor, never a clean result. That rule is unchanged; only the sources it applies to moved from someone else's API to the auditor's own node.

**Missing data raises risk.** An unmeasurable category scores 35, not 0. This is the single most consequential decision in the engine, because the alternative — treating "I could not check" as "nothing wrong" — is how automated scanners mislead people.

**Bounds are stated, not hidden.** Log scans, holder samples and history pages are all bounded by the tier budget, and the bound appears in the report's `notes` and in the signal evidence.

**Three auditors must be able to agree without talking.** A two-of-three quorum is worthless if two honest auditors, running independently, cannot land on the same bytes. That requirement shapes the engine more than any other: it is why every read in a run is pinned to one block, why the deterministic core is recomputed in full by all three rather than divided between them, why the probabilistic layer emits a coarse grid rather than a float, and why the canonical report body records what was observed and never how hard it was to observe it. §2 is that split.

---

## 2. What the engine computes, and who can compute it

Two axes cut across the engine and they are easy to confuse, so they are separated here. The first
is **reproducibility**: whether three independent auditors must land on identical output. The second
is **cost**: whether a signal needs a bounded set of direct contract reads, a full log fold, or an
archive node. The tiers are drawn along the cost axis; the quorum depends on the reproducibility
axis. Neither implies the other.

### 2.1 The deterministic core, recomputed by all three in full

These are pure functions of chain state at a fixed block, so three honest auditors each resolving
`job.requestedAt` to the same height must produce byte-identical output. There is nothing to
negotiate, so nothing is negotiated: each auditor computes the whole core itself and signs only what
it computed.

- token metadata, decimals, total supply, and whether the contract answers at all
- mint, freeze, pause and blacklist capability, derived from bytecode and from the ABI surface
- proxy detection and the implementation slot, admin and owner
- owner and admin privileges, and whether any of them can alter transfers
- transfer-fee logic and whether it is mutable
- liquidity pool discovery, virtual reserves at the current price, and whether the LP position is
  locked or withdrawable
- holder balances, folded from the complete `Transfer` log, and the resulting concentration
- the deployer, the deployment block, and the deployer's other deployments
- the early-buyer window: which addresses bought in the first blocks and what share they took

Recomputing all of that three times over is affordable because the work is bounded, the inputs are
pinned, and the expensive part is log retrieval rather than computation.

### 2.2 The quantised probabilistic layer

Wallet clustering, Sybil scoring, wash-trading likelihood, insider-group detection and creator
fingerprinting are not bit-reproducible even between two honest implementations of the same idea:
they involve thresholds, orderings and floating point, and two correct runs will disagree in the
last digit.

So these signals never emit a raw float. Each emits **a score rounded to the nearest 5, plus a flag
bit**. Rounding to a coarse grid is what lets three independent computations agree on a value
without coordinating on one, while still being three independent computations. Where a heuristic is
genuinely uncertain it sets `INSUFFICIENT_DATA` rather than guessing, and a signal that could not be
measured is reported as unmeasured rather than as clean.

This is also the layer that is proprietary (`docs/AUDITOR_NETWORK.md` §6), which makes one rule
non-negotiable: a heuristic a reader cannot check is never the sole basis of a claim. Every flag the
report raises cites the on-chain facts that support it, and a flag with no evidence array is
invalid.

### 2.3 Which signals belong to which tier

| | `basic` | `deep` | `forensic` |
|---|---|---|---|
| What it asks of the reader | nothing: no lock, no wallet, no KAY9 | a live deep access period | a live forensic access period |
| Where it runs | the visitor's own browser, against a public RPC | an auditor, quorum-signed | an auditor, quorum-signed |
| Recorded on-chain | never | request, quota, result, history | request, quota, result, history |
| Bytecode capability scan | yes | yes | yes |
| Proxy slots, owner, paused state | yes | yes | yes |
| ERC-20 / SPL metadata and supply | yes | yes | yes |
| Pool discovery and depth | yes | yes | yes |
| Solana top accounts | yes, one direct read | yes | yes |
| EVM holder fold and concentration | no | yes | yes |
| Transfer log scanning | no | yes | yes |
| Log budget | — | 2,500 logs / 12 requests | 8,000 logs / 40 requests |
| Recent-activity window | — | 3 hours | 24 hours |
| Early-buyer window | — | 30 minutes after deployment | 2 hours |
| Holders sampled from the fold | — | 50 | 100 |
| Creator identity and history | no | yes | yes |
| Wallet clustering | none | shared first sender of this token | plus first native funder lookups |
| Balance-fold getLogs calls | — | 120 | 400 |
| Creation-block receipts | — | 200 | 600 |
| Explorer timeout | — | 8 s | 12 s |

Windows are expressed in seconds and converted to blocks using the chain's block time, so 30 minutes
is 18,000 blocks on Robinhood (0.1 s blocks) and 600 blocks on BNB (3 s blocks).

Tier limits are honest limits. At `basic` the report carries `EVM_ACTIVITY_NOT_SCANNED`, and the
`holder`, `insider`, `trading`, `bot` and `creator` categories sit at the uncertainty floor of 35
with the reason stated. A free scan says what it did not look at; it never scores an unexamined
category as zero.

### 2.4 Why the line falls exactly there

The basic tier is not a teaser for a paid product, because there is no paid product. The line is
drawn by what a single browser tab can honestly finish.

Everything on the basic list is a **bounded set of direct reads** — `eth_call`, `eth_getCode`,
`eth_getStorageAt` at the head block — that completes in a handful of round trips and either answers
or visibly fails. Nobody should need permission to make reads a public node will serve them anyway,
so those signals require no lock, no wallet and no KAY9.

The EVM holder fold sits on the other side of the line for a reason about correctness rather than
billing. The fold is **exact or it is nothing**: a balance set built from a truncated log range is
not a smaller answer, it is a wrong one, because a holder whose only incoming transfer fell outside
the range disappears and every remaining holder then looks larger than they are (§3.4). On Robinhood
mainnet a fold over an active token is 30 to 40 sequential `eth_getLogs` calls (§2.5), so a browser
tab closed, backgrounded or rate-limited halfway through would produce exactly the partial answer
the engine refuses to produce. Putting the fold behind the deep tier means it always runs somewhere
that can finish it, and always reconciles against `totalSupply()` before anything is trusted.

Solana is the instructive exception. `getTokenLargestAccounts` is a single direct read, so top
accounts *are* a basic-tier signal there while EVM concentration is not. The boundary follows the
cost of the measurement on the actual chain, not a marketing tier list.

Running the basic scan in the visitor's browser has one further practical advantage. The public
Robinhood endpoint throttles by source address, and throttles datacentre egress far harder than a
residential connection, so a shared server-side scanner would sit in one rate-limit bucket for every
visitor at once while a browser sits in the visitor's own. That is why the canonical basic scan is
client-side, and why the auditors need their own endpoint rather than the public one.

### 2.5 Two measured facts about the public Robinhood RPC

Both were measured rather than assumed, and both shape the engine.

- **It is pruned.** A historical `eth_getCode` against the public mainnet endpoint answers
  `metadata is not found`. Binary-searching for a contract's deployment block therefore fails on
  that endpoint, and the deployer resolves as unknown with `EVM_ARCHIVE_UNAVAILABLE` raised rather
  than guessed (§3.5). Fixing it means pointing at an archive node, which is an auditor's own
  infrastructure choice and not a dependency on any third party.
- **It caps `eth_getLogs` at 10,000 matched logs per query.** The cap is on matched logs, not on the
  block span, so the usable width of a range depends on how busy the token is rather than on how
  many blocks it covers. Folding the complete `Transfer` history of an active token is therefore
  **30 to 40 sequential calls**, not one. The adaptive chunker in §3.4 exists to discover that width
  in a few probes instead of assuming it, and this call count is the concrete reason the fold is a
  deep-tier signal rather than a basic one.

---

## 3. EVM adapter

`services/watchdog/src/adapters/evm/`. Built on viem. Supports `eip155:4663` (Robinhood mainnet), `eip155:46630` (Robinhood testnet) and `eip155:56` (BNB), and any other EVM chain that is added to the registry with an RPC and a block time. An explorer entry is optional and adds no scored signal.

### 3.1 Bytecode scan (`bytecode.ts`)

Walks the deployed bytecode opcode by opcode, respecting PUSH immediates so that PUSH data is never mistaken for an instruction, and collects every `PUSH4` constant. Solidity dispatchers compare `calldata[0:4]` against `PUSH4` constants, so this closely approximates the contract's public function set. Selectors are computed from signature strings at load time with `toFunctionSelector`, so there is no hand-copied hex to get wrong.

**Can infer:** which capabilities exist in the deployed code — mint, pause/freeze, deny-list, fee setters, upgrade entry points, trading switches and limits, privileged burn or seizure, role-based access control. Also EIP-1167 minimal proxies (and their target), and the presence of `DELEGATECALL` or `SELFDESTRUCT`.

**Cannot infer:** whether any of those functions is reachable, who can call it, whether it is already disabled, or what it actually does. A selector is evidence a capability was compiled in, nothing more. The engine reduces the score for a capability when ownership appears renounced, no role system is present and the contract is not a proxy — and says so in the signal's `detail`.

### 3.2 Proxy detection

Reads the EIP-1967 implementation, admin and beacon slots, plus the pre-1967 OpenZeppelin slot, and combines them with the bytecode findings.

An upgradeable proxy is scored as high severity for a blunt reason: everything else in the report describes the *current* implementation, and an admin can replace it. A minimal proxy is scored low, because the target is fixed — but the report says the logic lives elsewhere and must be reviewed there.

This is not theoretical. Robinhood's canonical L2 WETH at `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` is deployed behind a transparent proxy, and the engine flags it. That is a true positive about a perfectly legitimate contract, which is exactly the kind of thing a reader has to interpret rather than react to.

### 3.3 ERC-20 metadata

`name`, `symbol`, `decimals`, `totalSupply`, with a `bytes32` fallback for MKR-style tokens. `owner()` then `getOwner()`. `paused()` when the selector is present — a token that is paused *right now* is a critical finding, distinct from one that merely can be.

If `totalSupply()` cannot be read, the target is marked `standard: unknown` and flagged: a contract that does not answer the most basic ERC-20 call will break most tooling that touches it.

### 3.4 Balances (`balances.ts`)

The RPC-only replacement for an explorer's holders endpoint. Every `Transfer` log between the deployment and the pinned analysis block is folded into a balance map: credit the recipient, debit the sender, and skip the debit when the sender is the zero address so that mints and burns net out the way `totalSupply()` does.

Chunking is adaptive. Providers disagree about how wide an `eth_getLogs` range may be, and the real limit usually depends on how many logs the range contains rather than how many blocks it spans, so the fold starts wide, doubles on success and halves on refusal. That finds the usable width in a few calls instead of assuming one, and it does not make the output provider-dependent: the balance map is a fold over the same set of logs however that set is fetched.

On the public Robinhood mainnet endpoint the measured limit is **10,000 matched logs per query**, which puts a fold over an active token at 30 to 40 sequential calls (§2.5). That is the number the deep and forensic call budgets are sized against.

**The fold is exact or it is nothing.** A balance set built from a truncated range is not a smaller answer, it is a wrong one — a holder whose only incoming transfer fell outside the range disappears, and every remaining holder then looks larger than they are. So the result is reconciled against `totalSupply()`, and anything that does not match returns no balances at all with the reason recorded: `budget-exhausted` when the token has more history than the tier is budgeted to read, `supply-mismatch` when the token moves balances without emitting standard `Transfer` events, which is what a rebasing token looks like from the outside.

Measured against Robinhood mainnet: a token with 16,885 transfers across 37,664 blocks folds to 476 holders that reconcile exactly against total supply.

### 3.5 Creation (`creation.ts`)

Deployment block and deployer, without an index. Code appearing at an address is monotonic, so the deployment block is a binary search over `eth_getCode` — about 26 calls at a height of 56 million. The deploying transaction is then identified inside that one block by matching receipts.

Three cases are reported rather than guessed:

- **Factory deployments.** The receipt names no created address, so the contract is recognised by its constructor's logs instead and the result is marked `indirect`, naming the account that called the factory rather than claiming it deployed the contract directly.
- **Pruned nodes.** Binary-searching historical code needs archive state, and most public RPCs do not keep it — the public Robinhood endpoint answers historical `eth_getCode` with `metadata is not found`. The engine detects this, falls back to the token's first `Transfer` log (logs outlive state), and raises `EVM_ARCHIVE_UNAVAILABLE`. That recovers the early-buyer window, which is the part of the analysis that actually needs the block, and leaves the deployer explicitly unknown. It is fixed by pointing at an archive node — the auditor's own choice, not a dependency on anyone.
- **Redeployed addresses.** A self-destructed and redeployed address breaks monotonicity, so the search finds *a* deployment rather than the first one.

### 3.6 Explorer (`explorer.ts`) — optional enrichment

Blockscout v2 dialect with a thin Etherscan fallback. It is not configured by default and **no score depends on it.** It supplies exactly two things:

- **Source verification status**, the one fact in this engine that no node can serve, because it lives in an explorer's own database rather than on the chain. It is recorded as `info` and scores zero in either direction: the bytecode is read directly regardless, published source is not evidence of honesty, and its absence is not evidence of wrongdoing.
- **Deployer history** — the other contracts an address has deployed. This needs an address-indexed transaction history, which standard JSON-RPC does not expose. Without it the report raises `EVM_CREATOR_HISTORY_UNAVAILABLE` and draws no conclusion about the deployer's past launches in either direction.

An unreachable or unconfigured explorer costs the report those two signals and nothing else.

### 3.7 Liquidity (`liquidity.ts`)

Uniswap v4 keeps every pool inside one PoolManager, so per-pool reserves cannot be read. What is readable through StateView is the active liquidity `L` and the current `sqrtPriceX96`, from which the virtual reserves at the current price follow:

```
amount0 = L * 2^96 / sqrtPriceX96
amount1 = L * sqrtPriceX96 / 2^96
```

Those are the amounts a full-range position with the same `L` would hold. They are the right order of magnitude for a depth check, and the report marks them `approximate: true`.

Pool ids are derived locally: `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`, with currencies sorted and `hooks = address(0)`. The engine probes `(10000, 200)` — the official KAY9 pool configuration — plus `(3000, 60)`, `(500, 10)`, `(100, 1)` and `(30000, 200)`, against both native ETH and wrapped native. That makes the official KAY9 pool discoverable by construction rather than by configuration, and gives generic tokens a reasonable chance of being found too.

Uniswap v2 and v3 style factories are probed when configured (PancakeSwap v2 and v3 are the defaults on BNB; nothing is assumed on Robinhood). For v2 pairs, LP tokens are ERC-20, so the burned fraction is measurable and `UNLOCKED_LIQUIDITY` is meaningful.

**Cannot infer:** liquidity in hooked v4 pools, in fee tiers outside the probe list, on DEXes with a different factory interface, or on venues that are not AMMs at all. Lock state for v3 and v4 positions, which are NFTs — whether one is locked depends on who owns the position token, which this version does not enumerate; the report raises `EVM_LP_LOCK_UNKNOWN` rather than guessing. A token that trades somewhere unprobed gets `EVM_NO_LIQUIDITY_FOUND` with the venue count as evidence, which is a statement about the search, not about the token.

### 3.8 Holder concentration (`holders.ts`)

Top holders from the folded balances, then top-1, top-5 and top-10 shares of *circulating* supply. Burn addresses, the token contract itself, and discovered liquidity pools are excluded from the circulating base and never counted as whales. A pool holding 40 % of supply is liquidity; counting it as concentration would make every healthy launch look captured.

**Cannot infer:** whether a large holder is an exchange, a bridge, a treasury, a vesting contract, or a person. The report names the addresses so the reader can check. It also cannot see beyond the sampled holders, and says how many it sampled.

### 3.9 Activity heuristics (`activity.ts`)

All three work on a bounded slice of `Transfer` logs, fetched in chunks with an explicit request and log budget, and the truncation flag travels into the report.

**Early buyers and snipers.** Addresses that received tokens in the first `windowBlocks` after the first observed transfer, ranked by amount, with pools and the zero address excluded. Raises `SNIPERS` when a small set captured most of the early flow. Buying early is not misconduct; it matters because it tells you who can sell into later buyers, and the signal's `detail` says exactly that.

**Bundled buys.** Transactions that delivered tokens to three or more distinct addresses at once. This is how one actor spreads a position across wallets — and also how airdrop and payroll contracts work. Medium severity, with the transaction hashes as evidence.

**Wash-like round trips.** Pairs `(A, B)` that transferred to each other in both directions inside a short window. This is what wash volume looks like on-chain. It is equally what a market maker rebalancing between its own hot wallets looks like, so the confidence is 0.5 and the pairs are always listed.

**Funding clusters.** Groups holders that share a first funder. At `deep`, the funder is the first address to send that token to the holder within the scanned window. At `forensic`, unresolved holders additionally get a first-native-funder lookup where an explorer is configured, bounded to the top holders; without one, clustering stays at token-funding depth and says so. Shared funding is a strong *structural* signal that wallets are operated together — and exchanges, bridges and airdrop contracts fund thousands of unrelated wallets, so the funder is named rather than assumed to be an insider. When nothing resolves, the signal is `EVM_CLUSTERING_UNRESOLVED`, not "clean".

### 3.10 Creator history

Deployer resolved from RPC (see 3.5). Its prior deployments need an address index, so that part runs only where an explorer is configured: three or more prior deployments is a medium signal, ten or more is high. Where no index is available the count is not guessed and `EVM_CREATOR_HISTORY_UNAVAILABLE` is raised instead.

**Cannot infer, yet:** whether the liquidity of those prior launches survived. Doing that properly means running the liquidity scan against every prior deployment, which is unbounded work at request time. The signal says explicitly that this was not verified and lists the prior contracts so a reader can check them.

---

## 4. Solana adapter

`services/watchdog/src/adapters/solana/`. RPC through native `fetch` with finalized commitment, per-request timeouts and a 2 MB response cap; account data parsed directly from the base64 bytes, which keeps the parser fixture-testable and independent of any client's decoding layer.

### Mint parsing

The 82-byte SPL mint layout (mint authority option and key, supply, decimals, initialized, freeze authority option and key), plus Token-2022 extensions: account type discriminator at byte 165, then TLV records from byte 166.

Decoded extensions and what they mean:

| Extension | Signal | Why it matters |
|---|---|---|
| `TransferFeeConfig` | `MUTABLE_TAX` | A fee is withheld on every transfer. If a fee config authority remains, the rate can change after purchase |
| `MintCloseAuthority` | `OWNER_PRIVILEGES` | The mint can be closed at zero supply |
| `DefaultAccountState` = Frozen | `FREEZABLE`, critical | Every new holder account starts frozen. Buyers cannot sell until thawed |
| `NonTransferable` | `HONEYPOT_SIGNALS`, critical | Soulbound: it cannot be transferred at all |
| `PermanentDelegate` | `OWNER_PRIVILEGES`, critical | One address can move or burn any balance without consent |
| `TransferHook` | `HIDDEN_TRANSFER_RESTRICTION` | Every transfer calls an external program that can reject it |
| `Pausable` | `FREEZABLE` | Transfers can be stopped; critical if currently paused |

A live mint authority raises `MINTABLE`, a live freeze authority raises `FREEZABLE`, and revoked authorities produce explicit "revoked" signals rather than silence.

### Holders

`getTokenLargestAccounts`, converted to shares of supply.

Holder amounts are validated before concentration is computed: duplicate accounts, malformed or negative
amounts, totals above supply and zero supply produce insufficient-data findings. These are account
shares, not wallet shares; an owner can hold several accounts and a pool or exchange can be large.

### Pool state and creation history (engine 1.3)

Deep and forensic scans obtain at most eight candidate addresses from the public
[DEX Screener token-pairs index](https://docs.dexscreener.com/api/reference). Index balances and prices
are ignored. Every candidate is checked against the actual program owner, Anchor discriminator,
layout, mint pair and vault accounts. Index failure or missing candidates never establishes that
liquidity is absent. Basic scans do not query this index.

- [Raydium CPMM](https://github.com/raydium-io/raydium-cp-swap/blob/master/programs/cp-swap/src/states/pool.rs):
  decode vault references and pool status; subtract accrued protocol, fund and creator fees from
  raw vault amounts to obtain constant-product reserves. Other Raydium programs remain unsupported.
- [Orca Whirlpool](https://github.com/orca-so/whirlpools/blob/main/programs/whirlpool/src/state/whirlpool.rs):
  decode vault references, active liquidity and square-root price. Report vault balances separately
  from executable depth; LP fees, tick traversal, transfer restrictions and withdrawal rights are
  not resolved by those balances.

Liquidity coverage remains partial: no USD valuation, LP-lock verification or executable trade quote
is claimed. The report retains the liquidity uncertainty floor, including when holders cannot be read.

Creation lookup pages signatures with a before cursor (two pages for deep, four for forensic,
1,000 signatures per page), then reads at most twelve of the oldest sampled transactions. It requires
a successful initializeMint/initializeMint2 instruction from the mint's actual token program,
including inner CPI instructions. The report records the fee payer and initial mint authority as
transaction facts; neither establishes creator identity or a history of prior projects. A pruned
history or exhausted budget returns unknown rather than attributing creation to the oldest transfer.
Engine 1.4 adds bounded trading heuristics as described below; full activity coverage remains unmeasured.

### Browser scans and consensus

The same basic adapter runs through the browser-safe export, using native fetch and atob without
Node globals or a backend endpoint. Mint parsing rejects non-mint accounts, invalid authority tags,
uninitialized mints, malformed TLVs and unsupported owners. Revoked optional extension authorities
do not trigger live-privilege findings. Unknown extension semantics retain contract uncertainty.

Engine 1.4 adds archive capture and replay. An explicit historical pin requires an exact stored
snapshot; replay performs no network reads and records both its slot and canonical snapshotHash.
The audit worker loads an exact timestamp/slot export from SOLANA_SNAPSHOT_DIR. Missing exports
still fail rather than substituting current balances. Current-bank capture, immutable file layout,
CLI commands and the archive trust assumptions are in [SOLANA_ARCHIVE.md](SOLANA_ARCHIVE.md).

### Trading, quotes and associated launches (engine 1.4)

Deep scans inspect up to two supported pools and 24 transactions; forensic scans inspect up to four
pools and 64 transactions. Signatures are deduplicated. Classification requires a known pool swap
instruction and opposing token/quote balance changes for one signer. Multi-pool routes and ambiguous
owners are omitted. Repeated buy/sell round trips, same-slot activity and early sampled buy volume
produce explicitly probabilistic findings; an incomplete sample always retains its uncertainty floor.

Raydium CPMM sell models use the actual fee config and integer rounding, including creator fees on
input or output. Reports show quotes for 0.1% and 1% of current supply, in raw quote-token units,
with price impact including fees. Restricted/fee-bearing token extensions, unavailable configs,
disabled or unopened pools are not quoted. These are curve calculations, not simulated or executed
transactions. Orca tick traversal and executable quotes remain outside this path.

LP checks compare Raydium pool accounting with outstanding LP mint supply. The difference includes
the protocol's 100 unminted initial LP units and any direct LP burns. No claim is made about the
ownership or locking of outstanding LP tokens. Sources:
[Raydium fee math](https://github.com/raydium-io/raydium-cp-swap/blob/master/programs/cp-swap/src/curve/calculator.rs),
[initial liquidity](https://github.com/raydium-io/raydium-cp-swap/blob/master/programs/cp-swap/src/instructions/initialize.rs).

Associated-launch lookup inspects up to 24/48 transactions of the initial mint authority and reads
up to eight other mints initialized with that same authority. It reports their current mint/freeze
permissions and restrictive extensions. Shared launchpad authorities do not establish project
identity, and retained permissions are not treated as a history of fraud or failed launches.

The Solana adapter is deliberately narrower than the EVM one and says so in every report it produces. A partial adapter that admits its gaps is useful; one that quietly scores the gaps as zero is not.

---

## 5. Cross-chain plan

Chain identity is CAIP-2 hashed to `bytes32`, so adding a chain is a convention, not a governance action. What each new chain needs:

1. an entry in the chain registry (`src/chain/chains.ts`) with an RPC and a block time; an explorer API is optional and adds no scored signal;
2. for EVM chains, nothing else — the EVM adapter works as-is, with liquidity coverage improving as factory addresses are configured;
3. for non-EVM chains, a new adapter implementing the same `AdapterOutput` contract: a target, a signal list, an observations blob and notes.

The scoring layer is chain-agnostic. It never sees an address; it sees signals with categories, points and confidences. That is what makes a Solana report and an EVM report directly comparable, and it is why a new adapter cannot accidentally change how existing chains are scored.

Order of work, as coverage is worth more than breadth: deepen Solana (AMM state decoding, creator resolution via a bounded indexer), then Base and Arbitrum (same adapter, more factories), then non-EVM chains as demand appears.

---

## 6. Running the engine

```bash
npm install
npm run build -w services/watchdog

# Scan an asset
npx kay9-watchdog scan robinhood 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73 --tier basic
npx kay9-watchdog scan robinhood 0xToken --tier deep --json
npx kay9-watchdog scan solana So11111111111111111111111111111111111111112

# Re-hash a report body to check it against an on-chain reportHash
npx kay9-watchdog hash ./report.json

# List known chains and their aliases
npx kay9-watchdog chains
```

As a library:

```ts
import { analyze, decodeFlags, hashReport } from '@kay9/watchdog';

const { result, report, reportHash, canonicalJson } = await analyze({
  chainKey: 'eip155:4663',
  assetId: '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73',
  tier: 'deep',
});

console.log(result.overallTrust, decodeFlags(result.flags));
console.log(hashReport(report).reportHash === reportHash); // true
```

`analyze` accepts injection points — `transport`, `fetchImpl`, `solanaRpc`, and a fixed `now` — which is how the test suite runs the whole pipeline against fixtures with no network.

Environment: `ROBINHOOD_RPC_URL`, `ROBINHOOD_TESTNET_RPC_URL`, `BNB_RPC_URL`, `SOLANA_RPC_URL`, `LOW_LIQUIDITY_NATIVE`, `LOG_LEVEL`.

Optional, and unset by default: `ROBINHOOD_EXPLORER_API`, `ROBINHOOD_TESTNET_EXPLORER_API`, `BNB_EXPLORER_API`, `BLOCKSCOUT_API_KEY`. Setting one adds source-verification status and deployer history. Nothing else changes, and no score moves.

### 6.1 Reproducibility and the analysis block

Every chain read in a run is pinned to a single block height, recorded in the report as `analyzedAtBlock` and returned in `observations.atBlock`. Without that pin a scan is not reproducible: on a chain producing ten blocks a second, a twenty-second scan would read supply, reserves and balances from two hundred different chain states and present the mixture as one observation. Two honest auditors would then sign different results for the same job and the quorum could never form, since agreement is counted per exact result digest.

The height is chosen in this order:

1. `options.atBlock`, passed by the caller. Used only when the caller already has a value in the
   target chain's own RPC height domain — the audit worker's monitoring sweep does this with an
   epoch-grid block it converged on independently (§9.1 of `docs/AUDITOR_NETWORK.md`), and only
   for an asset on the hub's own chain. Never the job's on-chain `requestedBlock`: it is a height on
   the hub chain (the chain's own, via ArbSys, since 2026-09-11; the parent chain's `block.number`
   before that, R01 in KAY9-REVIEW.md) and the asset may live elsewhere.
2. `options.atTimestamp`, resolved to the highest block at or before that time. The worker passes
   the job's `requestedAt` for every requested audit, on the hub's own chain or any other, since a
   timestamp is the only value `KAY9AuditHub` records that means the same thing on every chain; every
   auditor applies the same deterministic binary search and lands on the same block without
   coordinating.
3. The chain head, for ad-hoc CLI scans where reproducibility across machines is not required.

For the same reason, the canonical report records only what was observed, never how hard it was to observe it. Request counts, adaptive chunk widths, retry counts and transient RPC error strings are deliberately kept out of the hashed body and logged at debug level instead: they describe one auditor's network luck rather than the chain, and two auditors that reach the same balances by a different number of calls must still sign identical bytes.

---

## 7. Running an auditor

An auditor is a **stateless job**, not a daemon. It wakes, reads the chain, analyses, signs, submits
and exits. The requirement it is built to is scale-to-zero: when nobody has requested an audit, the
audit infrastructure should cost nothing and run nothing. There is no VPS fleet, no full node to
maintain and no always-on process anywhere in the design. `docs/AUDITOR_NETWORK.md` §4 specifies the
deployment; this section is how to run one.

It needs a signing key that is an active auditor, an RPC, the hub address, a little ETH for gas, and
an IPFS pinning credential.

```bash
npm run build -w services/audit-worker

export AUDITOR_PRIVATE_KEY=0x...        # never commit this; a platform secret store in production
export AUDIT_HUB_ADDRESS=0x...
export PRICING_ADDRESS=0x...
export ROBINHOOD_RPC_URL=https://...    # a dedicated archive endpoint, not the public one

node services/audit-worker/dist/index.js --once        # one pass, then exit: the production shape
node services/audit-worker/dist/index.js --once --dry-run   # everything except broadcasting
node services/audit-worker/dist/index.js               # long-running loop, for local development
```

`--dry-run` runs the entire pipeline — read, analyse, pin, sign, verify — and stops before
`writeContract`. It is the right way to rehearse against mainnet.

**The RPC should be an archive node.** Two things need historical state: pinning reads to the job's
request block rather than to the head, and locating a contract's deployment by binary search. The
public Robinhood endpoint is pruned and answers a historical `eth_getCode` with `metadata is not
found` (§2.5), so an auditor on it will find that pinned reads fail and that deployers resolve as
`EVM_ARCHIVE_UNAVAILABLE`. Logs are retained either way, so holder balances still fold correctly and
the early-buyer window still positions itself from the token's first `Transfer`.

This is a requirement on the auditor's own infrastructure, deliberately. The engine will not reach
for a third-party index to paper over a node that cannot answer.

### 7.1 How a job reaches an auditor

There is no third-party blockchain webhook service for Robinhood Chain, so the trigger is a
**scheduled poll plus an optional nudge**.

- **The poll is the guarantee.** Each auditor wakes on a schedule, reads `AuditRequested` logs since
  its cursor, and processes anything it has not already signed. At a five minute cadence against a
  six hour service level, a missed nudge costs latency and nothing else. Polling one `eth_getLogs`
  range costs one RPC call per wake.
- **The nudge is a latency optimisation.** After a request confirms, the browser may call a small
  trigger endpoint per auditor. That endpoint takes a job id, verifies the job on-chain itself, and
  starts the analysis. It trusts nothing the caller says: an invented job id finds no job and does
  nothing, and a replayed nudge for a job already signed is a no-op.

The nudge is never required for correctness. Turn kay9.io off and every request is still served,
just up to one poll interval later.

### 7.2 Idempotence, and why the check is on-chain

Two triggers for the same job must not produce two attestations. Before signing, an auditor checks
`attestationOf(jobId, self)` **on-chain**; if it is already set, the job is done for that auditor. A
transaction that reverts with `AlreadyAttested` is treated as success.

The check is on-chain rather than in the worker's own storage precisely so that a lost cursor, a
duplicate event, a retry, a cold start or a second concurrent invocation cannot double-sign. A
stateless job that can be invoked twice concurrently has no local truth to consult; the chain is the
only place that knows.

### 7.3 State

`DATA_DIR/worker.sqlite` holds the last processed block. `DATA_DIR/reports/<hash>.json` holds report
bodies the auditor has produced, because an auditor must be able to serve the body it signed.

None of it is protocol state. Deleting it makes the auditor re-scan from `AUDIT_HUB_START_BLOCK`, or
from `head - COLD_START_LOOKBACK_BLOCKS` if that is unset, and re-derive everything. Losing the
cursor costs a re-scan, never a wrong answer.

### 7.4 Pinning

With `IPFS_PIN_URL` set, the auditor POSTs the canonical JSON and expects `{cid}` back; a URL ending
in `pinJSONToIPFS` is treated as Pinata and wrapped accordingly. `IPFS_PIN_TOKEN` becomes a bearer
token. The resulting `reportURI` is `ipfs://<cid>`.

Without it, the report is written to a local content-addressed directory and `reportURI` is
`kay9://local/<reportHash>`. That is fully functional for development and for an auditor that serves
bodies itself, and it is honest about what it is.

A copy is always kept locally even when remote pinning succeeds. If remote pinning fails, the
auditor falls back to local rather than dropping the report, because losing the body would make an
otherwise valid quorum result unverifiable.

Because the report body is canonical bytes (`docs/AUDIT_PROTOCOL.md` §8.2), two auditors that agree
pin the same content and therefore derive the same content identifier independently. A reader can
fetch the body from any of them and check it against the one hash on-chain.

### 7.5 Sharing signatures

Two agreeing signatures in one `attest` transaction is the ordinary path, so auditors need some way
to see each other's signatures. Whatever carries them is the weakest thing in the system to depend
on, deliberately: it holds no authority, cannot forge a signature, cannot suppress one that reaches
an auditor another way, and holds nothing the chain depends on. An auditor that cannot see a peer's
signature simply attests alone, which costs one extra transaction and changes no outcome.

### 7.6 The keeper

Every `POKE_INTERVAL_MS` (120 s by default; the contract tolerates a 300 s gap) the keeper logs
`pricingStatus()` and the account balance, and calls `poke()` if
the observation ring has not yet seen the current block. The call is simulated first; a revert means
another keeper already observed this block, which is a no-op and is logged at debug level, not as an
incident.

Running more than one keeper is safe and is the point. The pool observation ring is what keeps
access locks quotable, and it should not depend on one process staying up. If every keeper stops,
`quoteLock` reverts and new locks are refused; **`unlock` keeps working regardless**, because it
reads no oracle.

Measured on the 2026-09-11 testnet rehearsal: with `maxObservationGap` at 300 s and the window at
30 minutes, a keeper outage of a little over five minutes made every `lock`, `renew`, `upgrade` and
`quoteLock` revert `PricingUnavailable(3)` within nine minutes of the last poke, and the ring needed
about thirty minutes of uninterrupted pokes afterwards before the gap aged out of the window and
quotes came back. Treat the keeper as part of the access model's uptime, run two of them, and alert
on a gap over 120 s rather than on `available` flipping, which is the symptom half an hour later.

### 7.7 The basic scan runs in the browser

The canonical basic scan is not served by an auditor at all. It is the same engine, at tier `basic`,
running in the visitor's own browser against a public RPC: no wallet, no KAY9, no job, no on-chain
record, and no server that can be down. §2.4 explains why the tier boundary falls where it does and
why client-side is the right place for it.

An optional convenience endpoint can run the same analysis server-side for callers that cannot run
it locally:

```
GET  /health
POST /scan   { "chain": "robinhood" | "bnb" | "solana" | "<caip2>", "address": "0x..." | "<mint>" }
```

Response: `{ result, report, reportHash, engineVersion, engineVersionCode, tier, disclaimer }`, with
`bigint` fields as decimal strings. Per-IP rate limiting (10 requests per minute by default,
honouring `x-forwarded-for` behind a proxy), a 60-second cache keyed by chain and asset, and CORS
restricted to `SCAN_ALLOWED_ORIGINS` plus any localhost origin. A failing analysis returns 422 with
a reason, never a 500 and never a fabricated clean result.

It is **not canonical** and nothing depends on it. No score is authoritative because it came from
there, and switching it off degrades nothing: the browser scan still works, and every tier that is
recorded on-chain goes through the quorum instead.

### 7.8 Three auditors locally, with Docker

`docker-compose.yml` at the repository root runs three independent auditors against a configurable
RPC, each with its own key and its own volume. That is a **rehearsal rig**, not the production
shape: in production each auditor is a scheduled serverless job on a separate platform
(`docs/AUDITOR_NETWORK.md` §4.3), because three containers on one host share one failure domain and
one operator, which is exactly what a quorum is supposed to avoid.

```bash
cp .env.example .env     # fill in AUDITOR_1/2/3_PRIVATE_KEY and the contract addresses
docker compose up --build
DRY_RUN=1 docker compose up --build   # rehearse without spending gas
```

No key is baked into any image. The image contains only the two service workspaces, so it can be
built and audited without the website or the contracts package.

---

## 8. Continuous monitoring

An audit is a snapshot of one block. Risk moves, so the registry keeps every snapshot and the
auditors keep looking.

A scheduled sweep, on the same scale-to-zero footing as everything else, walks assets that already
have a report and runs a cheap delta check:

- has the owner or admin changed
- has the proxy implementation changed
- has the LP position moved, or become withdrawable
- has a top holder's share crossed a threshold
- has the deployer moved funds

Every one of those is a direct read, which is why the sweep is affordable to run repeatedly over a
growing set of assets. Nothing in it needs a log fold.

When a delta is material, the auditors run a full analysis and publish it through
`publishWatchdogReport`: a quorum-signed report with no job and no requester. Nobody paid for it and
nobody asked, which is what makes KAY9 a watchdog rather than a vendor. A report that supersedes an
earlier one for the same asset sets flag bit 19, `MONITORING_UPDATE`, which scores zero — it is
context about *when*, not about the asset.

Because `KAY9Registry` appends and never overwrites, the result is a genuine history rather than a
verdict. An asset that scored 89 in September and 42 in October has both records, both signed, both
permanent, and `scoreHistory` returns the pair of arrays a risk-over-time chart needs. Two rules
follow and neither is optional: no surface may render a score without its `committedAt`, and no
surface may describe an old audit as current safety. The permitted phrasings are **KAY9 Audit
Completed**, **KAY9 Technical Risk** and **KAY9 Monitored**.

---

## 9. Limits

Stated plainly, because a scanner that hides its limits is worse than no scanner.

- **Static analysis finds capabilities, not intent or reachability.** A selector in the bytecode
  proves the capability was compiled in. Nothing more.
- **No transaction simulation.** The engine does not attempt a buy and a sell, so `HONEYPOT_SIGNALS`
  is a structural inference from the combination of controls present, at confidence 0.45, not a
  demonstrated sell block.
- **Liquidity coverage is broad on v4 and partial elsewhere.** A token's Uniswap v4 pools are
  enumerated from the `PoolManager`'s own `Initialize` events, so a pool is found whatever fee,
  tick spacing or hook it carries — which matters, because on Robinhood Chain a launch pool's fee
  is a launch tax and 810000 with a tick spacing of 19988 was measured on a real one. Configured v2
  and v3 factories are still probed by fee tier, and other venue types are invisible. v3/v4
  position lock state is not enumerated.

  When the enumeration cannot run — a throttled endpoint, or a token older than the log lookback —
  an empty pool list is reported as **unmeasured**, never as an absence of liquidity. A guess that
  missed is not evidence about the asset. See `docs/SCORE_CALIBRATION.md` §2.1 for the scan that
  established this.
- **Deployer history depends on an explorer.** Enumerating the other contracts an address has
  deployed requires an address-indexed transaction history that JSON-RPC does not expose. This is
  the only scored signal with an external dependency, and its absence lowers confidence rather than
  inventing a clean history.
- **Deployer identity depends on an archive node.** On a pruned RPC the deployment block still
  resolves from logs, but the deployer does not. That is an auditor configuration choice, not a
  third-party dependency.
- **Log scans are bounded and truncation is visible.** A busy token's window will be truncated; the
  report says so and the affected signals lose confidence.
- **Wallet clustering sees funding, not identity.** Shared funders are structural evidence.
  Exchanges and airdrop contracts fund unrelated wallets, so a cluster names its funder and lets the
  reader judge.
- **The probabilistic layer is not reproducible to the digit, only to the grid.** Rounding to the
  nearest 5 is what makes independent agreement possible (§2.2); it also means those scores carry
  less resolution than the number of digits suggests. Read the flags and the evidence, not the
  fifth-of-a-decile.
- **Solana is narrower than EVM.** Mint state, top accounts, two AMM layouts and bounded mint initialization
  lookup are implemented. Executable trade verification, creator reputation and activity outside the bounded sample remain unmeasured.
- **Basic-tier reports know less, and say so.** They do no log folding at all, so five of the seven
  categories sit at the uncertainty floor. A basic scan with no flags has not found an asset to be
  clean; it has looked at the part of the asset it could read in a browser.
- **The quorum protects against one dishonest auditor, not two.** And at launch two of the three
  auditor identities run inside accounts the project owner controls
  (`docs/AUDITOR_NETWORK.md` §4.3), so it does not protect against a compromise of the owner's own
  accounts. `docs/SECURITY.md` carries this as a named limitation rather than a footnote.
- **A report is a snapshot.** An upgradeable contract can invalidate one minutes after it is
  committed. `analyzedAt` and `committedAt` are on-chain precisely so a reader can see how stale a
  verdict is.

---

## 10. Roadmap

### V1.1 — coverage

Uniswap v3 and v4 position ownership enumeration, so `UNLOCKED_LIQUIDITY` becomes measurable for
concentrated liquidity. Creator-history liquidity checks (did the prior launches' pools survive?),
run against a bounded set of prior deployments. Extend Solana beyond Raydium CPMM and Orca Whirlpool
state decoding to executable depth and historical snapshots. A
read-only transaction simulation path (`eth_call` with state overrides) to turn the honeypot
heuristic into a demonstrated result rather than an inference.

### V1.2 — monitoring depth

The delta sweep in §8 checks a fixed list of direct reads. The work here is widening it without
making it expensive: which further properties can be watched with one read each, how often an asset
should be re-swept as its report ages, and report diffing between successive audits of the same
asset so a reader sees what changed rather than re-reading a full report.

### V1.3 — report permanence

A pinned body that nobody serves is a broken link with a valid hash. Arweave alongside IPFS, and a
public archive of report bodies, so verification does not depend on any single auditor staying
online. The hash on-chain is already the thing that matters; this is about the body remaining
fetchable.

### V2 — auditor independence and set growth

The honest weak point is not the analysis, it is who runs it. `docs/AUDITOR_NETWORK.md` §4.3 states
the launch configuration plainly: auditors A and B sit inside accounts the project owner controls,
because opening accounts on three genuinely independent commercial clouds requires a payment card
this project does not have. The work is moving B and C onto independent platforms as soon as either
a funding method exists or independent operators volunteer, and then growing the set past three
through the timelock. `docs/ROADMAP.md` carries this as a phase rather than an aspiration.

**Not on this roadmap: staking, slashing, or any yield on locked KAY9.** Bonding auditors was
considered and is not planned, for a reason worth writing down. Slashing works for objectively
checkable offences — a `reportHash` that does not match its body, a score that does not follow from
the report's own signals under the published function, a signature over a result whose asset does
not match the job — and does not work for bad judgement, which is most of what could go wrong in
risk analysis. A slashing mechanism that appears to cover disagreement it cannot actually adjudicate
is worse than a named auditor set, because it invites trust it has not earned. Meanwhile the access
lock pays no yield and never will (`docs/ACCESS_MODEL.md` §3), so there is no bond to build on and
nothing that would tempt anyone to describe a lock as an investment. Reputation, a public dispute
state, and a governable auditor set carry that weight instead.

---

## 11. The automatic scan loop

Sections 1 to 10 describe the engine and the auditor network — deep and forensic work, signed by a
quorum, in response to a request. This section is the other half, and it is the half that runs
before $KAY9 exists: nobody asks for it, nobody pays for it, and it covers the whole chain.

```
        discovery pass                    scan pass
   ┌─────────────────────┐         ┌──────────────────────┐
   │ read launch and     │  queue  │ scan in priority     │  batch   ┌──────────────────┐
   │ Initialize events   ├────────▶│ order, commit only   ├─────────▶│ KAY9ScanRegistry │
   │ from ten sources    │         │ what was readable    │  + root  └──────────────────┘
   └─────────────────────┘         └──────────────────────┘
        every 5 minutes                  continuous            batch document, content-addressed
```

Discovery is cheap and scanning is not, so they are separate passes with separate budgets. A
discovery pass that finds 1,400 tokens does not oblige the scanner to scan 1,400 tokens today: it
fills a queue drained in priority order, and the tokens nobody has bought wait behind the ones
people can. The sources, the decoding rules and the priority bands are in
[`docs/TOKEN_DISCOVERY.md`](TOKEN_DISCOVERY.md).

### 11.1 Which scans get indexed on-chain

`commitScanBatch(root, count, engineVersion, uri, summaries)` takes the batch's size and the subset
to index separately. **Everything in the batch is committed to `root` and provable against it**;
`summaries` is what additionally gets a storage write and an `AssetScanned` event, which is what
`latestScan` reads.

The policy, in order:

1. **Always index a graduation.** A token that reached a real pool is one somebody can buy.
2. **Always index a score of 60 or above**, on any token, however new.
3. **Always index a re-scan whose score changed band.** A score that moved is the most useful thing
   the record holds.
4. **Always index anything on KAY9's own launch path**, $KAY9 included. A watchdog that quietly
   omitted its own token would be worth nothing.
5. **Otherwise commit to the root only.**

Rule 5 covers the tens of thousands of bonding-curve launches a day that nobody has bought. They
are scanned, committed, published in the batch document and provable by anyone — they simply do not
occupy a storage slot until one of rules 1 to 4 applies, which is when somebody starts caring.

**What a reader must not conclude.** "Not indexed" is not "low risk". A token with no `latestScan`
entry renders as *not scanned on chain*, with a link to the batch document if one covers it. The
index is a convenience; the root is the record.

### 11.2 Re-scanning

A basic scan ages the moment it is written, so re-scans are event-driven rather than periodic:

| Trigger | Why |
|---|---|
| A graduation for a token already scanned | Its liquidity just changed completely. |
| A new pool for a token already scanned | Same. |
| An ownership or admin change | The powers the score was about just moved. |
| A large transfer relative to float | Distribution changed. |
| Nothing for 30 days | A floor, so a quiet token is not silently stale. |

Re-scans append. `AssetScanned` is indexed per asset, so one token's whole history is a single log
query, and a score that moved from 20 to 80 stays visible for good.

### 11.3 What this loop refuses to say

- **No "tokens protected" figure**, and no percentage of anything: nothing on chain supports one.
- **No launch counter as an achievement.** 42,000 launches a day is a fact about the chain.
- **No score without its confidence.** Rendering the number alone turns "we could not see enough"
  into reassurance.
- **No score where the scan failed.** Enforced in code, not by discipline: `runScanPass` puts only
  successful scans into a batch, and a test asserts that an unreadable token is never committed
  with a score.

### 11.4 Watchlists and alerts, and why they are designed for rather than built

A watchlist is the obvious next thing: follow a token, be told when its score moves. It is
deliberately not in the launch-readiness gates, and the design is written down now so that building
it later does not require changing anything underneath.

**It needs nothing new on chain.** `AssetScanned` is indexed per asset and `ReportRecorded` per
asset, so "tell me when this token's score changes" is a log subscription anybody can run — KAY9
included, and equally a wallet that would rather not depend on KAY9 for it. The reason to build it
is convenience, not capability, and that is the right reason to defer it.

**A watchlist must not become an account.** The moment KAY9 stores "which tokens does this person
watch" it holds something worth stealing, worth subpoenaing and worth monetising, and it acquires a
database whose loss would be a loss to the user. So the design is: the list lives in the browser,
and an alert is a subscription the user configures against their own channel. If a server-side list
is ever needed for push delivery, it stores an address and a token list and nothing else — no
email, no name, no history of what was looked at.

**An alert is a change, not a verdict.** The events worth sending are "the score moved band",
"a new report supersedes the one you were shown", "ownership or the proxy implementation changed",
"liquidity moved". Each names what changed and links to both records. None of them says sell, and
none of them is a recommendation — for the same reason the score is never rendered as a verdict.

**What would gate it.** Nothing about the record. It waits on there being enough continuous scan
history for a change to mean something, which is the same 30 days gate 1 asks for.

---

## 12. What it costs to run

Every input below was measured on Robinhood Chain mainnet on **2026-09-08**. Where a figure is an
extrapolation from a measurement, it says so.

| Quantity | Measured | How |
|---|---|---|
| RPC calls per basic scan | **84** (48 `eth_call`, 29 `eth_getLogs`, 4 `eth_getStorageAt`, 3 other) | wrapped transport, one graduated token |
| Wall clock per basic scan | **32.3 s** | same run, public RPC, serialised |
| RPC calls per discovery pass | **10** | one filtered query per source |
| Gas, batch indexing nothing | **145,867** | `ScanBatchGasTest` |
| Gas, per indexed asset | **≈24,700** | marginal across batches of 50-500 |
| Gas price | **0.3086 gwei** | `eth_gasPrice` |
| ETH | **$2,479.20** | the Chainlink ETH/USD feed on this chain |

A scan's cost is dominated by folding `Transfer` logs into balances — 29 log queries and half a
minute. A quieter token costs less; this one was chosen because it had traded.

### 12.1 On-chain cost, indexing every scan

| Scans/day | Batches | Gas/day | USD/day | USD/month |
|---|---|---|---|---|
| 0 | 0 | 0 | $0.00 | $0.00 |
| 100 | 1 | 2.04 M | $1.56 | $47 |
| 1,000 | 2 | 24.7 M | $18.90 | $567 |
| 10,000 | 20 | 247 M | $189 | **$5,670** |

### 12.2 On-chain cost, indexing what people can actually buy

About 6 % of what this chain launches reaches a real pool — 600 graduations against 20,000-50,000
launches a day. Indexing that fraction and committing the rest to the root only:

| Scans/day | Indexed | Batches | Gas/day | USD/day | USD/month |
|---|---|---|---|---|---|
| 100 | 6 | 1 | 0.29 M | $0.23 | **$7** |
| 1,000 | 60 | 1 | 1.63 M | $1.25 | **$37** |
| 10,000 | 600 | 2 | 15.1 M | $11.55 | **$347** |

Every scan is committed and provable in both tables. The only difference is whether an asset gets
the one-call `latestScan` read — and it is a factor of sixteen at the top end.

### 12.3 RPC and compute

| Scans/day | RPC calls/day | Scan-seconds/day | What that needs |
|---|---|---|---|
| 0 (discovery only) | ~2,900 | 0 | free tier, scale to zero |
| 100 | ~11,300 | 54 min | free tier, scale to zero |
| 1,000 | ~87,000 | 9 h | one always-on worker, dedicated RPC |
| 10,000 | ~843,000 | **90 h** | 4+ concurrent workers, dedicated RPC, and a re-measured scan |

**10,000 scans a day is not reachable on the public endpoint**, and the last row is a statement of
what would have to change rather than a plan. The public RPC refuses three `eth_getLogs` calls
issued back to back, and 90 scan-hours a day needs at least four concurrent workers, each with its
own rate-limit budget.

### 12.4 Everything else

Discovery, the queue and the cursors need no database (§5 of `docs/TOKEN_DISCOVERY.md` explains why
that is a requirement rather than a preference), so the fixed hosting is one container that scales
to zero plus a static site. Both sit inside the free grants at the volumes in the first three rows.
Figures in `docs/DEPLOYMENT.md` (main project; not included here).

---

## 13. Development

```bash
# watchdog
cd services/watchdog
npm install
npm test          # canonicalisation, flags, scoring, bytecode, EVM fixtures,
                  # Solana fixtures, and a live Robinhood smoke test that skips offline
npm run build

# audit-worker
cd services/audit-worker
npm install
npm test          # EIP-712 digest, quorum assembly and election, sqlite idempotency,
                  # scan API rate limiting and CORS, relay round trip, worker pipeline
npm run build
```

The live smoke test probes `eth_chainId` against the Robinhood RPC and skips itself if the chain is unreachable, so the suite passes offline. `KAY9_SKIP_LIVE=1` forces the skip.

Worker tests point the engine at a dead RPC on purpose: that is a supported degradation path and it produces a stable `AuditResult` to sign, aggregate and submit without touching a real chain.

### Note on `@kay9/chain`

The chain registry, protocol ABIs and EIP-1967 slot constants in `services/watchdog/src/chain/` and `services/audit-worker/src/abis.ts` are written locally from `docs/CONTRACT_INTERFACES.md` because `@kay9/chain` did not exist when these services were built. They are marked with migration notes. The values have been cross-checked against `@kay9/chain` as it now stands — chain keys, tier codes and flag semantics agree — and the local copies should be replaced by imports once that package is stable. Note one naming difference to avoid when migrating: `@kay9/chain` exports `FLAG_BITS` as bit *masks* (`MINTABLE: 1n`), whereas the watchdog's `FLAG_BITS` are bit *indices* (`MINTABLE: 0`), with `flagMask()` producing the mask.
