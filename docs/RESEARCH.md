# Research log (verified 2026-09-07)

Everything below was checked against live RPC calls or the upstream source at the stated commits. Re-run the commands before any production deployment; addresses change when Uniswap redeploys.

## Robinhood Chain

- Chain ID 4663 (`cast chain-id -r https://rpc.mainnet.chain.robinhood.com` → 4663); testnet 46630.
- **Two different block numbers, and the auction reads the chain's own.** Measured on testnet and
  mainnet on 2026-09-11 (and, for the earlier row, on testnet on 2026-09-08):

  | Quantity | How to read it | Testnet 2026-09-11 | Mainnet 2026-09-11 | Cadence |
  |---|---|---|---|---|
  | The chain's own height | `eth_blockNumber`, `ArbSys.arbBlockNumber()` at `0x…64`, any explorer | 117,236,896 | 59,983,529 | ≈ 0.1012 s |
  | What a contract sees as `block.number` | `Multicall3.getBlockNumber()` at `0xcA11bde05977b3631167028862bE2a173976CA11` | 11,679,667 | 25,951,849 | ≈ 12–13 s |

  Robinhood Chain is an Arbitrum Orbit chain, so `block.number` inside a contract is the **parent
  chain's** height, while `ArbSys.arbBlockNumber()` is the chain's own. Uniswap's Continuous
  Clearing Auction v2.1.0 and the LBP strategy read the clock through `BlockNumberish`, which
  uses ArbSys wherever the precompile answers — so **every block figure in a launch (start, end,
  claim, migration) is on the chain's own clock: 24 h ≈ 864,000 blocks, and `KAY9Genesis` bounds a
  window at 36,000–864,000 blocks (one hour to one day).** Since 2026-09-11 `KAY9Genesis` reads
  that same clock through the same helper (`chainBlockNumber()`), as do the block fields recorded
  by `KAY9AuditHub`, `KAY9Registry` and `KAY9ScanRegistry`.

  **How this was established, and how it was got wrong twice.** A note dated 2026-09-07 said the
  auction used the chain's own clock; a note dated 2026-09-08 "corrected" it after measuring
  `Multicall3.getBlockNumber()`, concluded that every window must be derived at 12 s per block, and
  rewrote `KAY9Genesis`'s bounds to 300–7,200 blocks. That measurement was real and irrelevant:
  `block.number` is not the number the auction compares against. The 2026-09-11 testnet
  rehearsal proved it: a launch derived at 12 s per block
  (`KAY9Genesis` `0x28d6BfaACa136dBAC8db37ac424e700bdA19015c`, auction
  `0x1C3023A5D5C6aA45CFBdCb34bd9B10C81c6A7D96`, window 11,679,656–11,679,956) was over before its
  first bid — `submitBid` reverted `AuctionIsOver()` at chain height 117,236,896 — while
  `launchState()` answered `1` (AuctionLive), and would have gone on answering it until the parent
  chain reached block 11,679,956, decades away, which also made `markFailed()` and any relaunch
  unreachable. Neither a unit test nor a mainnet fork could see this: both run on an EVM where the
  two clocks are whatever the test makes them. The fork suite now pins `block.number` to a
  parent-chain-like height and moves only the ArbSys mock, so a vault that read `block.number`
  anywhere would fail it.

  The verification that settles it, runnable by anyone:

  ```bash
  cast call 0x0000000000000000000000000000000000000064 "arbBlockNumber()(uint256)" -r https://rpc.mainnet.chain.robinhood.com
  cast call 0xcA11bde05977b3631167028862bE2a173976CA11 "getBlockNumber()(uint256)" -r https://rpc.mainnet.chain.robinhood.com
  # the first is what the auction reads; KAY9Genesis.chainBlockNumber() must equal it.
  ```

  100 ms rather than the measured 101.2 ms in `Launch.s.sol` is deliberate: the floor makes a
  derived window slightly *longer* in wall-clock terms than requested, never shorter.
- Explorer: Blockscout at `robinhoodchain.blockscout.com` (mainnet) and `explorer.testnet.chain.robinhood.com` (testnet). Foundry verification per `docs.robinhood.com/chain/deploy-smart-contracts`: `--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`.
- Public RPC is rate limited; production should use QuickNode/Dwellir/ArrowRPC endpoints. It throttles datacentre egress harder than residential, so a fold that fails from a container can complete from a laptop.
- **The public mainnet RPC is pruned.** A historical `eth_getCode` answers `metadata is not found` rather than returning code or an empty result: `cast code <token> --block <old block> -r https://rpc.mainnet.chain.robinhood.com`. Binary-searching for a deployment block therefore fails there, and the analysis engine falls back to the token's first `Transfer` log and reports the deployer as unmeasured. Auditors need an archive endpoint; this is an infrastructure choice, not a third-party dependency.
- **`eth_getLogs` is capped at 10,000 matched logs per query** on the same endpoint. The cap is on matched logs, not on the block span, so the usable range width depends on how busy the token is: `cast logs --from-block <a> --to-block <b> --address <token> "Transfer(address,address,uint256)" -r https://rpc.mainnet.chain.robinhood.com`, widening until it refuses. Folding the complete `Transfer` history of an active token is 30 to 40 sequential calls, which is why the holder fold is a deep-tier signal and not something a browser tab is asked to finish.
- **The cap is not applied uniformly, and wide ranges now time out.** Re-measured 2026-09-08: a topic-only query with no `address` filter returned 14,873 logs without complaint, while address-plus-topic queries refuse above 10,000. Separately, a 10,000,000-block query on a *rare* topic answered `log query timed out`. An earlier version of this file recorded that 10-million-block spans succeed; that no longer holds, and nothing in the codebase relies on it. The safe chunk for the busiest single feed is **≈250,000 blocks (~7 h of chain time)**, shrinking during bursts. `services/watchdog/src/discovery/logs.ts` implements exactly this and is the only place that talks to `eth_getLogs` for discovery.
- **The public mainnet RPC intermittently duplicates its CORS header, and browsers reject that.**
  Measured from the deployed site on 2026-09-08: a browser-side basic scan of one token made ~84
  requests and 10 of them failed with `The 'Access-Control-Allow-Origin' header contains multiple
  values '*,*', but only one is allowed`. It is intermittent rather than deterministic — 20
  consecutive plain `fetch` calls from the same page all succeeded, and `curl` never sees the
  duplicate at all, so it is almost certainly one node or edge behind the load balancer adding a
  header something upstream already added. The scan survives it because a refused read is scored
  as unmeasured rather than as a clean result, so the cost is a lower `confidence` rather than a
  wrong number — but it is a real argument for a dedicated endpoint on the browser path, not only
  on the scanner path.
- **Three `eth_getLogs` calls back to back are refused** with `Too Many Requests`, and a per-item loop of 90 `cast tx` calls returned one result before being throttled. JSON-RPC **batch** requests succeeded reliably at 100 items. So: batch every read, serialise log queries with a gap, and treat a rate limit as "wait", not as an error to surface.
- Robinhood protocol contracts (`docs.robinhood.com/chain/protocol-contracts`): L2 WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73`, L2 Multicall (Arbitrum style) `0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1`, Multicall3 `0xcA11bde05977b3631167028862bE2a173976CA11` (code present), Permit2 `0x000000000022D473030F116dDEE9F6B43aC78BA3`, deterministic CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` (code present), CreateX `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` (code present).
- Safe 1.4.1 singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` and proxy factory `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` have code; Safe{Wallet} announced day-one support.

## Token launch activity (measured 2026-09-08)

The chain is busy, and this is the measurement the whole discovery design rests on. Full working
in `docs/TOKEN_DISCOVERY.md`; the source catalogue with every address and topic0 is
`services/watchdog/src/discovery/sources.ts`.

| Metric | Measurement | Per day |
|---|---|---|
| Blocks | 0.1012 s/block over 10 M blocks | ~854,000 |
| Transactions | 1,589 in 100 blocks | ~13.7 M (~159 tps) |
| ERC-20 `Transfer` logs | 14,572 in 31 s | ~40 M |
| Uniswap v4 `Initialize` | 831 in 1 h; 6,580 in 12 h | ~13,000-20,000 |
| Token launches, all launchpads | dominated by one source | **~20,000-50,000** |
| Graduations to a real pool | 684 measured over 50,000 blocks | **~500-700** |
| Contract creations by EOA (`to == null`) | 1 in 100 blocks | ~8,600 |

The last row is a trap: almost every token here is deployed by a factory via `CREATE`/`CREATE2`
and is therefore invisible to a `to == null` scan. True contract creation is nearer 100,000/day.
**Do not size a scanner off the `to == null` number.**

- **Pons** (`0x7ed598bcef8bd9edd8c97a195c6d13f40801ec7e`) is a bonding-curve launchpad and by a wide
  margin the busiest source: ~16,000-42,000 `TokenLaunched` a day against ~600 `PoolGraduated`.
  Every address and topic0 was verified twice — computed from the signature and observed in live
  logs. Quote assets are **not** only ETH: USDG and the tokenised equities AAPL, GLD, SGOV and
  SPCX all appear as the pair side, so nothing may assume an ETH pair.
- **Uniswap v4 `Initialize`** at the `PoolManager` is how a pool created by nothing KAY9 recognises
  still gets seen. topic0 `0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438`.
  `topics[1]` is the **poolId**, not a currency — `topics[2]`/`topics[3]` are currency0/currency1.
  Mis-indexing that produces pairs where currency0 sorts above currency1, which v4 cannot produce
  and is the tell that a decode is wrong. Observed LP fees include 81 % and the dynamic-fee flag
  `0x800000`, used as launch taxes, so nothing may assume a standard fee tier.
- Eight further launch mechanisms have live code and measurable traffic (Doppler Airlock ~3,100/day,
  LongLauncher ~2,900/day, then Flap.sh, Klik, trench.today and Bags.fm in the tens). Five more
  hold code but emitted nothing in the measurement window; they are recorded as dormant rather
  than omitted.
- **`0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` — the `liquidityLauncher` in this project's own
  address book — is indexed by third parties as a launchpad entry contract.** KAY9's own launch
  goes through it, so **KAY9 will appear in its own discovery feed**, and it must: a watchdog that
  quietly omitted its own token would be worth nothing.
- **There is no official Robinhood token list, subgraph or indexer API.** `docs.robinhood.com/chain/`
  describes the chain and an ecosystem partner table and never mentions a launchpad or a token
  list. Everything above is reproducible from the public RPC alone.
- Mainnet Blockscout (`robinhoodchain.blockscout.com`) remains unreachable from here (HTTP 000).
  `explorer.testnet.chain.robinhood.com` answers 200. A third-party explorer, HoodScan
  (`hood-chain.com`), answers 200 and has a "New Tokens" view; whether it exposes a
  Blockscout-compatible REST API is **unverified**.

**What this changes.** The engineering risk was assumed to be an empty chain with nothing to watch.
It is the opposite. A "tokens detected today" counter would read in the tens of thousands, so the
product problem is ranking and filtering, not data availability, and a feed in arrival order would
spend its entire scan budget on tokens nobody ever bought. See `docs/TOKEN_DISCOVERY.md`.

## Chainlink

*Retired 2026-09-11: the lock is denominated in KAY9; no oracle in the access path. Kept as
research. The launch script may still read this feed to print implied FDV in USD, which is
display-only.*

- `docs.chain.link` feed directory for Robinhood: ETH/USD proxy `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` (aggregator `0x6091E64eb7138EEF066a80FD3A0d7427B91f2721`), 8 decimals, heartbeat 86,400 s, deviation 0.5 %, feed category "low", SVR-shared path. Live call returned `description() = "ETH / USD"`, answer 2479.20 USD, `updatedAt` 17 minutes old.
- No feed on testnet 46630 (no code at the proxy address) → testnet uses `MockV3Aggregator`.
- Because the heartbeat is 24 h, `maxFeedAge` must be ≥ 86,400 s; default 90,000 s.

## Uniswap on Robinhood

- v4 deployments page (`developers.uniswap.org/docs/protocols/v4/deployments`, Robinhood section): PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`, PositionManager `0x58daec3116aae6d93017baaea7749052e8a04fa7`, PositionDescriptor `0x9639443158e8c5efa35bd45287bf2effd3d8dc06`, Quoter `0x8dc178efb8111bb0973dd9d722ebeff267c98f94`, StateView `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b`, UniversalRouter `0x8876789976decbfcbbbe364623c63652db8c0904`, ReservesLens `0x0000001b173C3bbF3984D417d8614E3eed34865B`. The Robinhood Universal Router is a modified fork (extra `minHopPriceX36` in the v4 swap struct) so stock SDK swap calldata reverts; the site links to the Uniswap app for swaps rather than building swap calldata.
- Liquidity Launchpad deployments page + `Uniswap/liquidity-launcher` README (main, 2026-09): LiquidityLauncher v3.2.0 `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` (commit `dd8769cd…`), LBPStrategy v3.1.1 `0x05d552391067389EE44fec3924157ed33F976000` (commit `5ef0262b…`; `src/strategies/lbp/LBPStrategy.sol`, `MigratorParams.sol`, `PositionPlanner.sol` are byte-identical between that commit and main), CCA factory v2.1.0 `0x000000001F26a0044BaA66024e7b6599c61963F8` (commit `7d7602d2…`, "bug fix for Arbitrum and Orbit chains" = blocknumberish), CCALens `0xc3C65F5453A3674aDb693cbdA3C842545cD30f53`, FeeSplitters `0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf` and `0x222D6d4f1ce59b0d48D5505114eC8Addc90A4359`, UERC20BeneficiaryVault `0xd35E9CA72F64C7F93BE30fad67524323396B36D7`, CompoundingClaimRecipient `0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a`, TokenSplitter `0x4F5E3FBb9745358A92Da5674305FAb8D2B8a73cE`, InstantLaunchStrategy `0x23f8209572b4a1C2AD88A42749E830791Fb027f1` / `0xAD44D55E7f8337C3cE113fBb591486E85be104b2`.
- Live reads: `LBPStrategy.positionManager()` = `0x58da…`, `poolManager()` = `0x8366…`, `initializerFactory()` = `0x0000…63F8` (the v2.1.0 CCA factory). `CCAFactory.protocolFeeController()` = `0x0` → `ProtocolFeeLib.getProtocolFeeAmount` returns 0: no protocol fee on the raise today.
- `FeeSplitter(0xeFF1…).getSplits()` = `[(vault 0xd35E…, native 4000 bps, token 0, callback), (compounding 0xf952…, native 6000, token 10000, callback)]`. `FeeSplitter(0x222D…)` = `[(compounding, 10000, 10000, callback)]`. `UERC20BeneficiaryVault.nativeFallback()` = `0x2aC03e14Cfe755426DaAEe0a4994184Ce81482F8`, `tokenFallback()` = `0x…dEaD`. For a non-UERC20 token (KAY9 has no `graffiti()`), an unregistered position's 40 % native share would flush to the native fallback; therefore `KAY9LiquidityLock` registers the beneficiary while it owns the NFT (PositionManager mints with plain `_mint`, no receiver callback, so the lock holds the NFT until `lock()` is called).
- LBPStrategy mechanics (source): `positionRecipient` receives minted LP NFTs directly; `recipient` receives leftover currency and unused reserve; `tokensRecipient` (CCA) receives unsold via `sweepUnsoldTokens()` callable only by that recipient; `fundsRecipient` must be the strategy (`address(1)` sentinel → strategy); `migrationBlock > endBlock`; `lpAllocationSchedule` brackets in mps (1e7 = 100 %); full-range position sentinel `(MIN_TICK, MAX_TICK)`; hookless static-fee pools fall back to the strategy-hooked key if the hookless pool is already initialized (resolve the pool key from the `Migrated` event). v4 static LP fee max is 100 % (`LPFeeLibrary.MAX_LP_FEE = 1_000_000`), so `fee = 10000` (1 %) with `tickSpacing = 200` is valid.
- InitializerHook v3.1.1 at `0xD462a559337859369EF271814851A18F496ba000` (mainnet): code present, `authorized()` = LBPStrategy `0x05d5…6000`, `supportsInterface(IInitializerHook)` = true, address flag bits `0x2000` = BEFORE_INITIALIZE only. Used as the official pool hook so the pool key cannot be pre-initialized by a third party (which would otherwise make `LBPStrategy.initializeDistribution` revert with `InvalidHook` and strand the launch allocation). Not deployed on testnet 46630.
- CCA mechanics (source, main `6c9e559`): prices are Q96 raw-currency-per-raw-token; ticks are additive multiples of `tickSpacing` (Q96); `floorPrice ≥ 2^32 + 1`; `MAX_BID_PRICE` derived from supply; steps packed as `uint64` = `mps(24) | blockDelta(40)`; `requiredCurrencyRaised` graduation; non-graduated auctions refund bidders and return the full supply to `tokensRecipient`; `lbpInitializationParams()` reverts `NotGraduated` when not graduated; `sweepCurrency()` is restricted to `fundsRecipient`.
- SDK: `@uniswap/liquidity-launcher-sdk@1.13.0` includes Robinhood (4663) addresses matching the above, `BLOCK_TIME_SECONDS_BY_CHAIN[4663] = 0.1`, helpers `floorPriceToX96`, `deriveAuctionPricing` (tick = floor/100), `requiredCurrencyRaised`, `deriveConvexAuctionSteps` (12 steps + 30 % final block), `buildPositionDefinitions('FULL_RANGE')`, `buildLpAllocationSchedule({kind:'single', percent:100})`, `encodeAuctionParams`, `encodeConfigData`, `computeLbpPoolId`. The README warns that its `TimelockedPositionRecipient` bytecode went stale on Robinhood ("timelock became a no-op"); KAY9 does not use that recipient.
- The Uniswap web app lists Robinhood Chain auctions under Explore → Auctions, so bidders can also participate there.

## Testnet 46630

- Code present at: PoolManager `0x8366…`, PositionManager `0x58da…`, CCA factory `0x0000…63F8`, Permit2, Multicall3. **Absent**: LiquidityLauncher `0x0000Ffff…`, LBPStrategy `0x05d5…`, Chainlink ETH/USD. Rehearsals deploy pinned launcher + strategy copies and a mock feed.
