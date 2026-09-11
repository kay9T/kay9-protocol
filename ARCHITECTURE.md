# KAY9 Architecture

KAY9 is an audit protocol, an automatic watchdog, and — later — a token, on Robinhood Chain. The website at kay9.io is only a window onto the contracts. If kay9.io disappears, every contract, balance, lock, auction record, access period, audit request, committed result and committed scan survives on-chain and any developer can build another interface against the same addresses.

**The order matters and is enforced by the deployment scripts, not by intention.** `DeployWatchdog.s.sol` stands up the auditor set and `KAY9ScanRegistry` with no token and no access vault anywhere in it, so the watchdog can run on mainnet before $KAY9 exists. `Deploy.s.sol` — the token launch — then attaches to that same governance rather than standing up a second auditor registry, and refuses to run if the registry it is pointed at disagrees with the launch about its quorum, its members or its owner. What has to be true before the token launches at all is `docs/LAUNCH_READINESS.md`.

This document is the implementation spec shared by the contracts, the website, and the services. Numbers, addresses and behaviours here are the ones the code must reproduce. Research sources and verification commands are in `docs/RESEARCH.md`.

---

## 1. Trust hierarchy

```
$KAY9 token (KAY9Token)                       immutable, no admin
KAY9 protocol
  ├─ KAY9TeamVesting                           immutable, no admin
  ├─ KAY9Genesis (launch vault)                owner-signed launch, on-chain invariants
  ├─ KAY9LiquidityLock                         permissionless one-way lock into Uniswap FeeSplitter
  ├─ Uniswap Liquidity Launcher + CCA + v4     canonical, audited, not ours
KAY9 Audit Protocol
  ├─ KAY9AccessVault                           holds a depositor's lock; no owner path to principal
  ├─ KAY9AuditHub                              requests, on-chain access check, attestation, quorum
  ├─ KAY9Registry                              append-only report history, cross-chain asset identity
  ├─ KAY9AuditorRegistry                       auditor set + quorum threshold
  └─ TimelockController (48 h) ← owner Safe    the only admin, always delayed
Off-chain auditors (three, scale-to-zero)
  ├─ services/watchdog                         analysis engine + chain adapters (EVM, Solana)
  └─ services/audit-worker                     auditor job: detect → analyse → sign → attest
Website (apps/web)                             UI only, reads chain directly; runs the free basic scan
                                               in the visitor's browser
```

The ordering is deliberate and reads downward as *decreasing* trust. Everything above the timelock
is either immutable or constrained by its own code. The timelock is the only thing that can change
a parameter, and it can change no balance. Everything below it can be switched off entirely without
any value moving: turn off all three auditors and open requests eventually expire and refund their
quota; turn off kay9.io and every contract still answers. Nothing in the lower half of the diagram
is ever asked for permission by anything in the upper half.

Two consequences of that ordering are load-bearing elsewhere in this document. `KAY9AccessVault`
sits above the hub because a depositor's principal must not depend on the hub behaving: the vault
lets the hub move a quota counter and nothing else. And the free basic scan sits in the website's
row rather than in the auditors' row because it is not a service the protocol depends on — it runs
in the visitor's browser against a public RPC, so it has no operator to fail.

---

## 2. Network facts (verified 2026-09-07)

| Item | Value |
|---|---|
| Mainnet chain ID | 4663 |
| Mainnet RPC (public, rate limited) | `https://rpc.mainnet.chain.robinhood.com` |
| Mainnet explorer | `https://robinhoodchain.blockscout.com` (Blockscout; verify with `--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`) |
| Testnet chain ID | 46630 |
| Testnet RPC | `https://rpc.testnet.chain.robinhood.com` |
| Testnet explorer | `https://explorer.testnet.chain.robinhood.com` |
| Testnet faucet | `https://faucet.testnet.chain.robinhood.com` |
| Gas token | ETH |
| Stack | Arbitrum Orbit (Nitro). The EVM's `block.number` follows Ethereum; `ArbSys.arbBlockNumber()` and RPC `eth_blockNumber` expose the chain's own height. Uniswap's `BlockNumberish` uses ArbSys. |
| Block time | The chain's own blocks: ≈ 0.10 s, read by contracts through `ArbSys.arbBlockNumber()`. The EVM's `block.number` is the **parent chain's** height (≈ 12 s) and nothing in KAY9 compares against it. The auction, the strategy and `KAY9Genesis` all read the chain's own clock through Uniswap's `BlockNumberish`. **4 hours ≈ 144,000 blocks.** `docs/RESEARCH.md`. |
| Cancun (EIP-1153) | Supported (Uniswap v4 and launcher run on it) |

Canonical addresses on mainnet 4663 (all confirmed to have code on-chain):

| Contract | Address |
|---|---|
| Uniswap v4 PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` |
| Uniswap v4 PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Uniswap v4 StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |
| Uniswap v4 Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| Universal Router (modified fork, extra `minHopPriceX36` field) | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| LiquidityLauncher v3.2.0 | `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` |
| LBPStrategy v3.1.1 | `0x05d552391067389EE44fec3924157ed33F976000` |
| InitializerHook v3.1.1 (`authorized()` = LBPStrategy, flags `0x2000` = beforeInitialize only) | `0xD462a559337859369EF271814851A18F496ba000` |
| ContinuousClearingAuctionFactory v2.1.0 | `0x000000001F26a0044BaA66024e7b6599c61963F8` (protocolFeeController = `address(0)` → **0 % protocol fee on the raise**) |
| CCALens v2.0.0 | `0xc3C65F5453A3674aDb693cbdA3C842545cD30f53` |
| FeeSplitter (40 % native → UERC20BeneficiaryVault; 60 % native + 100 % token → CompoundingClaimRecipient) | `0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf` |
| FeeSplitter (100 % native + 100 % token → Compounding) | `0x222D6d4f1ce59b0d48D5505114eC8Addc90A4359` |
| UERC20BeneficiaryVault (nativeFallback `0x2aC03e14…82F8`, tokenFallback `0xdead`) | `0xd35E9CA72F64C7F93BE30fad67524323396B36D7` |
| CompoundingClaimRecipient (minLiquidityIncrease 1e20) | `0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a` |
| Chainlink ETH/USD proxy (8 decimals, heartbeat 86400 s, 0.5 % deviation) — display only: the launch page and `Launch.s.sol` use it to show implied FDV in USD; nothing in the access path reads it | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |
| WETH (L2) | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |
| Deterministic CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Safe 1.4.1 singleton / proxy factory | present; Safe{Wallet} supports Robinhood Chain |

Testnet 46630 has PoolManager, PositionManager, CCA factory, Permit2 and Multicall3 at the same addresses, but **no LiquidityLauncher, no LBPStrategy, no FeeSplitter and no Chainlink feed**. Testnet rehearsal therefore deploys pinned copies of the launcher stack (`docs/DEPLOYMENT.md`); the missing feed only affects the USD display of FDV.

---

## 3. Token and allocation

`KAY9Token` — OpenZeppelin ERC20 + ERC20Permit + ERC20Burnable. 18 decimals. Constructor mints exactly 1,000,000,000 × 10¹⁸ to `KAY9Genesis` (the deployer of the token) and nothing else can ever mint. No owner, no pause, no blacklist, no fees, no hooks, no proxy. `burn` only destroys the caller's own tokens (used by the genesis dust policy; the audit protocol never burns anybody's KAY9).

| Allocation | Amount | Share | Holder after genesis |
|---|---|---|---|
| Public fair auction | 455,000,000 | 45.5 % | CCA auction contract (during auction) |
| Permanent liquidity reserve | 455,000,000 | 45.5 % | LBPStrategy (until migration) → Uniswap v4 pool |
| Team | 90,000,000 | 9 % | `KAY9TeamVesting` |

Team schedule enforced by `KAY9TeamVesting` (immutable timestamps set at deployment, computed as exact UTC calendar dates in `docs/DEPLOYMENT.md`; not "180 days"):

| Tranche | Amount | Unlock |
|---|---|---|
| 1 | 10,000,000 (1 %) | TGE |
| 2 | 40,000,000 (4 %) | TGE + 6 calendar months |
| 3 | 40,000,000 (4 %) | TGE + 12 calendar months |

`release()` is permissionless and sends whatever is unlocked to the beneficiary. The beneficiary may hand the role to another address (`transferBeneficiary`), nothing else is mutable.

---

## 4. Genesis and fair launch

### 4.1 KAY9Genesis

Deploys the token and the vesting contract in its constructor, holds the 910 M launch allocation, and is the only path by which those tokens leave. Its owner is the project owner's Safe. Owner powers are limited to calling `launch(LaunchParams)` and, if a launch fails, `relaunch` after a 48 h delay. There is no withdraw.

`launch()` executes `LiquidityLauncher.multicall([permit2 approve path, depositToken(910M), distributeToken(LBPStrategy, 910M, configData)])` after enforcing on-chain:

- `strategy == LBPStrategy` canonical address (immutable in Genesis)
- `MigratorParameters.token == KAY9`, `currency == address(0)` (native ETH)
- `reservedTokenAmountForLP == 455,000,000e18`, distribution amount `== 910,000,000e18`
- `poolParameters.fee == 10000` (1 %), `tickSpacing == 200`, `hook == InitializerHook` (the canonical `0xD462…`, re-validated in the Genesis constructor: live code, ERC-165 `IInitializerHook`, `authorized() == LBPStrategy`, and address flags exactly `beforeInitialize`)
- `positionRecipient == KAY9LiquidityLock`, `recipient == Genesis`
- `positionDefinitions == [full range, weight 1e7]`
- `lpAllocationSchedule == [{0, 1e7}]` (100 % of raised ETH to liquidity)
- `AuctionParameters.currency == 0`, `tokensRecipient == Genesis`, `fundsRecipient == address(1)` (sentinel → strategy), `validationHook == 0` (no whitelist), `endBlock - startBlock` within `[MIN_DURATION_BLOCKS, MAX_DURATION_BLOCKS]`, `claimBlock >= endBlock`, `migrationBlock > endBlock`
- `floorPrice`, `tickSpacing`, `requiredCurrencyRaised`, `auctionStepsData` are owner-supplied deployment parameters, echoed in the `LaunchConfigured` event so the site can display implied FDV before and after.

Because every trust-relevant field is asserted by the contract, the owner's remaining discretion is only pricing and timing, which the website displays.

### 4.2 Lifecycle

1. **Auction** (CCA v2.1.0, native ETH, 455 M KAY9, 4 h ≈ 144,000 blocks on the chain's own clock, emission schedule from the Uniswap SDK's convex default). Anyone bids with `submitBid`; the Uniswap web app auctions tab also lists it.
2. **Graduation** requires `currencyRaised ≥ requiredCurrencyRaised` (deployment parameter, default = clearing the full auction supply at the floor price).
3. **Migration**: anyone calls `LBPStrategy.migrate(auction)` after `migrationBlock`. The strategy sweeps the ETH, initializes the v4 pool `(ETH, KAY9, fee 10000, tickSpacing 200, InitializerHook)` at the clearing price, mints one full-range position with 100 % of the ETH and up to 455 M KAY9, and transfers the LP NFT to `KAY9LiquidityLock`. Leftover ETH dust and unused reserve KAY9 go to Genesis.
4. **Lock**: anyone calls `KAY9LiquidityLock.lock(tokenId)`. The lock registers the owner's creator-fee address as beneficiary in `UERC20BeneficiaryVault` (possible only while the lock owns the NFT) and then transfers the NFT to FeeSplitter `0xeFF1…`, where it is irrecoverable. Fees: 40 % of native-side fees to the beneficiary NFT holder (owner Safe), 60 % native and 100 % KAY9-side fees compound back into the position via the CompoundingClaimRecipient.
5. **Unsold and leftover KAY9**: anyone calls `KAY9Genesis.settle()`. It sweeps unsold tokens from the auction (`sweepUnsoldTokens`, Genesis is `tokensRecipient`), adds them plus any returned reserve as a **single-sided KAY9 position at KAY9 prices above the current one** (range `[minUsableTick, currentTick - tickSpacing]`; native ETH is `currency0` and KAY9 is `currency1`, so a currency1-only range sits *below* the current tick, which is where KAY9 is more expensive) and locks that NFT through `KAY9LiquidityLock` as well. Amounts below `DUST_THRESHOLD` (1,000 KAY9) are burned instead. Unsold tokens can never become a team allocation.
6. **Failure paths**: if the auction does not graduate, bidders refund themselves via `exitBid`, the auction returns 455 M to Genesis, migration recovery returns the 455 M reserve to Genesis, and the owner may `relaunch` after 48 h with new pricing (same invariants). If the auction graduates but migration fails (practically impossible with a static-fee pool and a standard token), Genesis receives the ETH and reserve; `recover()` is permissionless and mints the full-range position itself at the auction's final clearing price and locks it. Because only the strategy may initialize the hooked pool, recovery rebuilds into the **hookless** pool `(ETH, KAY9, 10000, 200, 0x0)` and refuses to proceed unless that pool is either uninitialized or already sitting exactly at the auction's clearing price; `poolKey()` then reports the recovery pool. ETH never becomes withdrawable by the owner.

### 4.3 Official pool fee

The official KAY9 pool is Uniswap v4, static LP fee `10000` pips = **1 %**, tick spacing 200. This is a pool fee paid by traders to liquidity providers, not a token tax. Uniswap v4 supports any static fee ≤ 100 %, so 1 % is fully supported on Robinhood Chain; nothing is silently replaced.

---

## 5. Audit protocol

Nobody pays for an audit. There is no fee, no price per audit, no escrow, no treasury share and no
burn of a requester's KAY9. Access to the deep and forensic tiers is a **lock** in
`KAY9AccessVault`, and what a request spends is a quota unit, not money. The full specification of
that model is `docs/ACCESS_MODEL.md`; the auditor arrangement is `docs/AUDITOR_NETWORK.md`. This
section is the shape the contracts implement.

### 5.1 Contracts

**KAY9ScanRegistry** — the permanent record of automatic basic scans, committed in Merkle batches.
Deliberately a separate contract from `KAY9Registry`, because the two carry different claims: a
basic scan is a **reproducibility** claim (one authorised scanner ran the published engine on
public state, and anyone can recompute it), while a deep or forensic report is a **consensus**
claim (two of three independent auditors signed the same result). Putting both in one contract
would let a reader mistake one for the other, and the product depends on that distinction being
legible.

- `commitScanBatch(root, count, engineVersion, uri, summaries)` — a scanner or any auditor may
  commit. Every scan in the batch is committed to `root` and provable with `verifyScan`; only
  `summaries` additionally gets a storage write and an `AssetScanned` event. That split is a
  measured cost decision: indexing an asset costs about 24,700 gas against roughly 146,000 for the
  batch however large it is, so indexing everything on a chain producing tens of thousands of
  launches a day would cost thousands of dollars a month. `docs/WATCHDOG.md` §11.1 and §12.
- `latestScan(chainKey, assetId)` returns `scanned` alongside the score, because an unset `uint8`
  defaults to 0, the worst reading the engine can give, and "never looked at" must not be
  indistinguishable from it.
- Nothing can alter or remove a committed batch. De-authorising a scanner stops it committing again
  and changes nothing it already committed.
- Batching is in the design from the first day rather than added later, so the cost of watching a
  chain scales with time rather than with that chain's activity. A batch of one is legal.

**KAY9AuditorRegistry** — the set of auditor addresses with `threshold` (2 of 3 at launch). Owner =
TimelockController. `addAuditor` and threshold changes are timelocked (48 h); `removeAuditor` also
goes through the timelock but exists so a compromised key can be dropped, and it lowers the
threshold rather than leaving it unsatisfiable. `1 <= threshold <= auditorCount` always holds.

**KAY9AccessVault** — holds a depositor's KAY9 for one access period and returns all of it
afterwards.

- `requirementOf(tier)` is the KAY9 amount a tier locks: 5,000 KAY9 for deep and 10,000 KAY9 for
  forensic at deployment, changed only by `setRequirement` through the timelock (§6). There is no
  oracle: the number is stored, not quoted.
- `lock(tier, maxKay9)` (or `lockWithPermit`) copies `requirementOf[tier]` into the access record
  as `lockedKay9` and takes exactly that amount. The requirement is frozen for the period: a later
  `setRequirement` never asks the depositor for more and never shortens or voids a live period.
- `renew(tier, maxKay9)` is refused before `expiresAt`. That single rule is what stops the quota
  being farmed: an early renewal would reset the allowance inside a period that was already opened
  once, so four deep audits on day one plus a renewal on day two would buy four more for nothing.
  At or after expiry the period genuinely ended, so `renew` reads the current requirement and
  settles the difference in whichever direction it went, without an unlock-and-relock round trip.
- `upgrade(maxKay9)` raises a live deep period to forensic. It tops the lock up, leaves the expiry
  alone and **preserves `deepUsed`**, because deep allowance is four in both tiers and upgrading
  should buy the forensic slot and nothing else.
- `unlock()` returns exactly `lockedKay9` at or after expiry and reads nothing else, so no
  configuration change and no external dependency can ever trap a depositor's tokens.
- `consume(account, tier)` and `restore(account, tier, periodStartedAt)` are callable only by the
  configured hub, move a counter and never a balance. `consume` returns the period it debited so a
  later `restore` cannot credit a period that did not pay for it. A hub that `setAuditHub` has
  replaced keeps the right to `restore` and loses everything else, so a job left pending across a
  hub migration can still expire or dispute and hand its unit back.
- A requirement can never be zero: `setRequirement` is bounded on chain (`InvalidRequirement`), so
  a record with no principal — the vault's spelling of "no record" — cannot be created.

| Tier | Lock | Period | Deep allowance | Forensic allowance |
|---|---|---|---|---|
| Basic | free, no lock, no wallet | — | unlimited, in the visitor's browser | — |
| Deep (1) | 5,000 KAY9 | 30 days | 4 | 0 |
| Forensic (2) | 10,000 KAY9 | 30 days | 4 | 1 |

**KAY9AuditHub** — `requestAudit(chainKey, assetId, tier, declaredRequesterKind)` calls
`accessVault.consume(msg.sender, tier)` first, and that call is the whole authorisation: it reverts
when the caller has no live period, when the period is of a lower tier than the request, or when the
tier's allowance is spent. The job records `requestedBlock` and the vault period the unit came from,
and emits `AuditRequested`. `attest(jobId, result, signatures[])` accepts one or more 65-byte ECDSA
signatures over the EIP-712 digest of `(jobId, result)`; every recovered signer must be an active
auditor that has not already attested this job, and the submitter must be an active auditor too. A
digest reaching `auditors.threshold()` votes finalises the job and appends the record to
`KAY9Registry`. `markExpired(jobId)` is permissionless once the SLA (6 hours by default) has elapsed.
`publishWatchdogReport(result, signatures[])` commits a quorum-signed report with no job and no
requester, again from an auditor. No KAY9 changes hands anywhere in this contract.

**KAY9Registry** — `recordReport` (hub only) appends to `reports[]` and to `history[assetKey]`;
nothing is ever overwritten. Alongside the result it stores `jobId`, `requester`,
`declaredRequesterKind`, `tier`, the signer list, `committedAt` and `committedBlock`. Chain keys:
`keccak256("eip155:4663")`, `keccak256("eip155:56")`, `keccak256("solana:mainnet")`, extensible by
convention (CAIP-2 string hashed). Asset IDs: EVM `bytes32(uint256(uint160(address)))`, Solana the
32-byte mint key. `latestSummary` and `scoreHistory` exist so that a wallet, DEX, launchpad or badge
can consume KAY9 risk data with one call and no off-chain API.

`AuditResult` (on-chain, fixed size, no report body):

```
bytes32 chainKey; bytes32 assetId;
uint8 overallTrust; uint8 contractTrust; uint8 liquidityTrust; uint8 holderTrust;
uint8 insiderTrust; uint8 creatorTrust; uint8 tradingTrust; uint8 botTrust;   // 0 (worst) … 100 (trustworthy)
uint64 flags;            // bitmask, definitions in AUDIT_PROTOCOL.md
uint32 engineVersion;
uint64 analyzedAt;       // unix seconds
bytes32 reportHash;      // keccak256 of the canonical JSON report
string reportURI;        // ipfs://… or ar://…; integrity verified by reportHash
```

### 5.2 Lifecycle of an access period and an audit

1. **Read the requirement.** The caller reads `accessVault.requirementOf(tier)`. It is a stored
   number, not a quote, and the website shows it from that read rather than hardcoding it.
2. **Lock.** `approve` then `lock(tier, maxKay9)`, or `lockWithPermit` in one transaction. `maxKay9`
   is the caller's bound against a `setRequirement` executing between the read and the transaction.
   `AccessLocked` records the tier, the principal, the period and the allowances.
3. **Request.** `requestAudit(chainKey, assetId, tier, declaredRequesterKind)`. The hub consumes one
   quota unit through the vault and records `requestedBlock` on the job. `declaredRequesterKind` is
   metadata the caller states about itself; the hub records it verbatim, which is why every surface
   renders it as declared.
4. **Analysis.** All three auditors independently analyse the asset as of `job.requestedAt` — a
   moment the chain chose, not the auditors, resolved to that asset's own chain height with a
   deterministic binary search every auditor runs identically. `job.requestedBlock` is the chain's
   own height at request time (read through ArbSys since 2026-09-11) and is kept for the audit
   trail; the auditors still pin by the timestamp because it means the same thing on every chain an
   asset can live on. Each auditor then signs an EIP-712 `AuditResult`.
5. **Quorum.** The second auditor to finish submits both agreeing signatures in one `attest`
   transaction; a disagreeing auditor pays for its own. Only an active auditor may submit either
   call, because `reportURI` is not in the signed struct and the submitter chooses it. The first
   digest to reach the threshold finalises the job and `KAY9Registry.recordReport` appends the
   record.
6. **Dispute or expiry.** The job becomes `Disputed` the moment agreement is arithmetically out of
   reach, and `Expired` when anyone calls `markExpired` after the SLA. Both restore the quota unit
   to the period it came from, so a request that produced no result costs nothing. Contradictory
   results are never averaged.
7. **Renew or unlock.** At or after `expiresAt` the depositor either takes the whole principal back
   with `unlock`, or `renew`s at the current requirement and keeps going. A live deep period can become
   forensic at any point with `upgrade`.
8. **Monitoring.** Between requests the auditors sweep assets that already have a report and, when a
   delta is material, publish through `publishWatchdogReport`. Nobody asked and nobody paid, which
   is what makes KAY9 a watchdog rather than a vendor. Because the registry appends, the result is a
   score history rather than a single verdict: `latest` means most recent snapshot, never current
   safety.
9. **Beta, before there is a token to lock (R24, KAY9-REVIEW.md).** `requestAudit` cannot run before
   `setAccessVault` — there is no KAY9 to lock — so `services/audit-worker/src/beta-api.ts` serves a
   free, walletless `POST /submit` that records a real person's ask in a shared queue, and
   `beta.ts`'s bounded weekly pass works it: skip anything `KAY9Registry.latest` already shows a
   report for, analyse and publish the rest through the same `publishWatchdogReport` path monitoring
   uses. `docs/ACCESS_MODEL.md` §8.1.

### 5.3 What money does and does not do here

There is no path by which value flows from a requester to an auditor, to the treasury, or to a burn
address. That is a design decision with a reason: if a token creator hands over KAY9 and receives a
score, every good score looks bought whatever the code actually does. Under a lock, the requester
gives KAY9 to nobody, so there is nothing for a score to be a payment for. The allowance exists only
to bound the cost of running genuinely expensive analysis, not to price it.

---

## 6. The lock requirement (a fixed amount of KAY9)

The amount a tier locks is a number of KAY9 stored in the vault, `requirementOf[tier]`, not a
dollar target and not a quote: `requirementOf[TIER_DEEP] = 5_000e18` and
`requirementOf[TIER_FORENSIC] = 10_000e18` at deployment.

- **Changing it.** `setRequirement(tier, kay9)` is an owner function behind the 48 h
  TimelockController, like every other owner function on the vault. The contract bounds it:
  `MIN_REQUIREMENT` is 1 KAY9, `MAX_REQUIREMENT` is 10,000,000 KAY9 (1 % of supply), and after
  the change the forensic requirement must be at least the deep one; anything else reverts
  `InvalidRequirement`. `RequirementConfigured(tier, kay9)` is emitted.
- **What a change reaches.** Only periods opened or renewed after it. `lock` copies the
  requirement into the record; `renew` (after expiry) reads the current one and settles the
  difference; `upgrade` tops a live deep period up to the current forensic requirement; `unlock`
  returns exactly `lockedKay9` and reads nothing else. A live period is never asked for more and
  never shortened.
- **No oracle.** There is no TWAP, no ETH/USD feed and no off-chain process in the access path. A USD-
  denominated lock would have needed a price feed that somebody funds forever, and every new lock
  would have depended on that feed being alive. The trade-off is accepted knowingly: the dollar
  value of a lock moves with the token's price until the owner adjusts the number, and because
  the adjustment goes through the timelock it is public for two days before it applies.

---

## 7. Off-chain services

**services/watchdog** — library: `analyze(chainKey, assetId, tier)` → canonical JSON report + `AuditResult`. Adapters: `evm` (viem; Robinhood 4663, BNB 56; standard JSON-RPC only — holder balances are folded from `Transfer` logs and the deployment is located by binary search over `eth_getCode`, so no block explorer or indexer sits in the scoring path), `solana` (`@solana/kit`; mint/freeze authority, top holders, LP state). Every chain read in a run is pinned to one block height, recorded as `analyzedAtBlock`, so independent operators produce byte-identical reports. Signals are probabilistic; every finding carries `evidence` and a confidence, and the engine never claims intent.

**services/watchdog, discovery** — `runDiscoveryPass` reads launch and pool-creation events from ten verified sources on Robinhood Chain and returns an ordered scan queue plus the cursors it reached. It holds no state: losing every cursor costs a replay, not the record. `runScanPass` drains that queue in priority order — graduations before the launch firehose, oldest first inside a band — scans each token with the same engine at the basic tier, and commits what succeeded in Merkle batches. **A scan that could not read the chain is never committed as a score**; it is counted as a failure and left in the queue. `docs/TOKEN_DISCOVERY.md` and `docs/WATCHDOG.md` §11.

**services/discovery-worker** — the scheduled job that actually runs the above unattended: a real chain reader, a real batch-document publisher (Merkle root and per-asset proofs, keyed by root), a real `KAY9ScanRegistry.commitScanBatch` committer with the same simulate-before-broadcast discipline as the auditor's attest path, and a cursor that holds a source back — rather than losing a token to an advanced cursor — for any scan still unresolved, bounded so a permanently unreadable token cannot stall a source forever. Written, tested, **not deployed**. `services/discovery-worker/deploy/README.md`.

**services/audit-worker** — one stateless job per auditor, on a scale-to-zero footing: it wakes on a
schedule (or on an optional nudge), reads `AuditRequested` logs since its cursor, runs the engine
pinned to `job.requestedAt`, pins the report (IPFS via a configured pinning endpoint, or a local
content-addressed store in development), signs the EIP-712 `AuditResult` and attests. There is no
always-on process and no VPS fleet; when nobody has requested an audit, nothing runs. The nudge is
a latency optimisation and never a correctness requirement: turn
kay9.io off and every request is still served on the next scheduled wake. Its `beta`/`beta-api`
commands are the pre-token substitute for `requestAudit` (point 9 above); `beta` reuses the same
sign/gossip/collect/broadcast quorum logic monitoring's `publishWatchdogReport` path already relies
on (`src/watchdog-report.ts`), rather than a second copy of it.

Before signing, an auditor checks `attestationOf(jobId, self)` **on-chain** rather than in its own
storage, so a lost cursor, a duplicate event, a retry, a cold start or a second concurrent
invocation cannot produce two attestations.

The free basic scan is not a service. It runs in the visitor's browser against a public RPC, needs
no wallet, no KAY9 and nobody's permission, and is therefore not something that can go down. An
optional convenience endpoint may serve the same analysis for callers that cannot run it locally;
it is explicitly not canonical and no part of the protocol depends on it.

Neither service holds protocol state; they can be replaced without touching contracts. Deleting
every auditor's local state changes nothing that is already on-chain; it only costs a re-scan.

---

## 8. Website

Next.js 16 (App Router, React 19), Tailwind v4, wagmi 3 + viem 2, TanStack Query. All reads go straight to Robinhood Chain RPC (public by default, overridable by env). No backend database, and no server-side scan in the critical path.

A wallet is needed only where a transaction is: bidding on `/launch`, and locking, renewing, upgrading, unlocking or requesting an audit on `/audit`. The **basic scan needs none of it** — no wallet, no KAY9, no lock — because it runs in the visitor's own browser against a public RPC. Everything else on the site is a contract read: an asset's latest summary, its score history, an access period's remaining allowance, a job's status.

Two rules the site cannot break, because they are the ones a UI is most likely to get wrong. It never renders a score without its `committedAt`, since `latest` is the most recent snapshot and not current safety. And before the auction has produced a price it says the lock requirement is not available yet, and explains why, rather than showing a placeholder figure. Design per `DESIGN.md`.

---

## 9. Repository

```
apps/web                 Next.js site
packages/contracts       Foundry project (src, test, script)
packages/chain           TS: chain definitions, addresses, ABIs (generated), helpers
services/watchdog        analysis engine + adapters + token discovery
services/audit-worker    auditor job + optional convenience scan endpoint
services/discovery-worker  discovery-to-commit job: scans and batches new launches unattended
docs/                    protocol documentation
```

---

## 10. Admin surface (complete list)

| Contract | Admin | Power | Delay |
|---|---|---|---|
| KAY9Token | none | — | — |
| KAY9Registry | none | — | — (binding to its hub is immutable; see `docs/REGISTRY_UPGRADE.md`) |
| KAY9TeamVesting | beneficiary | change beneficiary | none |
| KAY9Genesis | owner Safe | `launch` (once), `relaunch` after failure | 48 h for relaunch |
| KAY9LiquidityLock | none | — | — |
| KAY9AuditorRegistry | Timelock | add auditor, set threshold | 48 h; remove is immediate via Timelock proposer-executor |
| KAY9ScanRegistry | Timelock | authorise or de-authorise a scanner | 48 h |
| KAY9AccessVault | Timelock | `setRequirement`, `setQuota`, `setLockDuration`, `setAuditHub` | 48 h |
| KAY9AuditHub | Timelock | SLA, pause new requests (attestations, disputes and expiries are never pausable) | 48 h |
| TimelockController | owner Safe (proposer/executor), Timelock itself (admin) | schedule/execute | 48 h min delay |

**No owner function can move a depositor's principal.** The vault's four setters point it at a hub,
set the KAY9 amount future periods lock, set the per-period allowances, and set the length of future
periods. None of them touches a balance,
and there is no function on `KAY9AccessVault` — timelocked, owner-only or otherwise — that sends a
depositor's KAY9 to any address other than the depositor. `setRequirement`, `setQuota` and
`setLockDuration` do not reach into live periods either, because the locked amount, the allowances
and the expiry are copied into the access record when the period opens. The tests assert this directly rather than by inspection.

The hub's administrative surface lost its treasury setter along with the payment model: there is no
recipient to configure because there is no money to send. Pausing is limited to *new requests*
precisely so that governance cannot strand a job that has already spent a quota unit — a paused hub
still accepts attestations, still disputes, and still expires jobs back into their quota.
