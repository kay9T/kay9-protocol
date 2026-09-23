# Launch-path model review — Anthropic Claude Fable 5.1, 2026-09-23

| | |
|---|---|
| Model | Claude Fable 5.1, model id `claude-fable-5-1` as the API reported it for every response |
| Interface | Claude Code subagent started fresh, with no context from the project's working session; read-only; told not to read any other review |
| Date | 2026-09-23 |
| Commit | `8dde1aa0eec443a63ad065e653d2529a96aabbd9` of `kay9T/kay9-protocol`, tag `launch-review-3`, read with `git show <commit>:<path>` |
| Scope | as the prompt states |
| Prompt | [`LAUNCH_PATH_REVIEW_PROMPT.md`](LAUNCH_PATH_REVIEW_PROMPT.md), verbatim |

This is a model review, not a professional audit. The review text was committed unedited before
any of its findings was acted on (commit `eba174a` of the main project); the dispositions below were
added afterwards.

## Dispositions

Each finding was checked against the source before it was decided. The fixes change `KAY9Genesis`
and `KAY9LiquidityLock`, so the commit under review moves to `launch-review-4`.

| Finding | Held? | Disposition |
|---|---|---|
| F-1 — no upper bound on `startBlock`, `claimBlock`, `migrationBlock` | Yes | **Fixed.** `launch()` refuses a start more than `MAX_START_DELAY_BLOCKS` (about 30 days) ahead, and a claim or migration block more than `MAX_DURATION_BLOCKS` (about 24 h) after the end. Regression `test_launchRejectsFarFutureTiming` |
| F-2 — the dependencies the bytecode is built from were not pinned | Yes, and confirmed: a fresh install today fetched a `v4-periphery` whose `Actions.sol` differs from the one the tests ran against (the constants the vault uses are the same in both) | **Fixed.** The 237 dependency files the compiler reads are now committed with the repository, with their licences, so the commit alone decides what is compiled. `setup.sh` names the exact upstream commit of each dependency for anyone installing the rest. A build of a tree holding only the committed files passes the whole suite |
| F-3 — half the raise given to the vault before `settle()` turns a good migration into the recovery path | Yes; documented in the code as an accepted cost | **Fixed** as the reviewer suggested: `migrateAndSettle()` runs the migration and settles in the same transaction, so the outcome is written down before any other transaction can move the balance. The website's migration button now calls it. `settle()` stays for a migration somebody runs directly on the strategy. Regression `test_migrateAndSettleLocksAndSettlesAtOnce` |
| F-4 — a swallowed `sweepUnsoldTokens` failure still finalises the launch | Held as a shape; no trigger was found by the reviewer or here | **Fixed.** `settle()` and `recover()` refuse to finalise (`UnsoldNotSwept`) while the auction still reports its supply unswept |
| F-5 — the FeeSplitter's wiring is not checked | Yes | **Fixed.** `KAY9LiquidityLock`'s constructor requires the splitter's PositionManager to be the lock's and the splitter to pay the beneficiary vault (`FeeSplitterMisWired`); a mis-wired address book fails the deployment. Regression `test_refusesAMisWiredFeeSplitter` |
| F-6 — the migration's LP positions wait for somebody to `track` and `lock` them | Yes | **Fixed** by `migrateAndSettle()`, which locks every position the migration minted to the lock, identified by the PositionManager's `nextTokenId` before and after the call. A migration run directly on the strategy still needs `track`/`lock`, which stay permissionless |
| F-7 — the emission shape is free | Yes | **Fixed.** No step may release more than `MAX_STEP_MPS` (40 %) of the supply per block; the script's convex schedule releases about 30 % in its final block. Regression `test_launchRejectsAConcentratedSchedule` |
| F-8 — "at most one wei" is not what the code guarantees | **No.** The review inverts the ratio: one wei of ETH at a price of about 4e9 KAY9 per ETH makes roughly 6e4 units of liquidity, not the reverse, so the amount that cannot form one unit is under one wei. The tests measure at most one wei left after `settle()` and after `recover()`. The protocol-fee assumption it names was checked on chain: the canonical CCA factory's `protocolFeeController()` returns the zero address | **Rejected**, with the measurement. The fee check is recorded |
| F-9 — the vesting calendar is anchored to the planned TGE | Yes, and by design | **Accepted** and stated in public material: a launch that slips past a tranche date releases that tranche at settlement |
| F-10 — `renounceOwnership` before a launch strands the allocation | Yes | **Fixed.** `renounceOwnership` reverts `OwnershipCannotBeRenounced`. Regression `test_ownershipCannotBeRenounced` |
| F-11 — `Launch.s.sol` accepts any ETH/USD feed on mainnet | Yes (the open V6 item of the September review) | **Fixed.** On chain 4663 the feed must be the address book's. This also closes V6 |
| F-12 — `lockAll` iterates a list anyone can grow | Yes | **Accepted.** `lock(tokenId)`, which the vault and `migrateAndSettle` use, is unaffected; `lockAll` is a convenience |

## Verification at `launch-review-4`

Fable reached its usage limit before its own verification round, so the round was run by a fresh
Claude Opus 5.5 session (model id `claude-opus-5-5` as the API reported it), with no context from
the project's working session, reading only `launch-review-4` and this file. Its result: F-1, F-2,
F-4, F-5, F-10, F-11 **closed**; F-8's rejection, F-9 and F-12 **agreed**; F-3, F-6, F-7
**narrowed**; nothing above Low introduced.

What remains, and why it is accepted:

- **F-3 / F-6, and 2.1.** `LBPStrategy.migrate` is permissionless in Uniswap's own contract, so
  somebody can still migrate directly and give the vault half the raise in the same transaction.
  `migrateAndSettle` closes the window for everyone who uses it; nothing in `KAY9Genesis` can stop a
  call made straight to the strategy. The cost to the actor is half the raise, locked into KAY9
  liquidity for good, and the payoff is nothing. The migration positions left unlocked in that case
  cannot be withdrawn and are locked by the permissionless `track` and `lock`.
- **F-7.** The cap bounds the rate per block, not how concentrated a whole schedule is. The
  script's largest step is at most 30.8 % in its final block for every duration it can produce, at
  least 9.2 points under the cap (measured by the verifier), and the site shows the schedule before
  anyone bids.
- **2.2.** If the auction's own accounting ever left it a few wei short of its unsold supply, the
  sweep would revert and `settle` and `recover` would wait; anyone can send the auction the missing
  KAY9 dust and retry. This is in the runbook.
- **2.3.** If somebody migrates directly, `migrateAndSettle` reverts and the path is `settle()`
  plus `track`/`lock` of the migration positions; the site offers `settle()` once the pool exists.

### The verification, verbatim

# KAY9 launch path: verification of the Claude Fable 5.1 findings at `launch-review-4`

**Tree reviewed:** `kay9-protocol` at commit `5464d26e8810019d1f0e535327de692798637a6f` (tag `launch-review-4`). I read it only through `git show <commit>:<path>` and `git grep <commit>`, never from the working tree. I diffed it against `8dde1aa0…` for `src` and `script`. The only file I read under `docs/reviews` was `2026-09-23-anthropic-claude-fable-5.1.md`. Line numbers below are 1-based in the file at `5464d26e`.

This is a model review, not a professional audit. I executed no Solidity. The only thing I ran was a Python copy of `AuctionSteps.convexSchedule` that uses the same integer arithmetic, to check the new emission cap.

---

## 1. Status of F-1 … F-12

| Finding | Status | Where | Reasoning |
|---|---|---|---|
| **F-1** No upper bound on the timing fields | **Closed** | `src/KAY9Genesis.sol:765–769`, constants `:310` | `startBlock` may be at most `MAX_START_DELAY_BLOCKS` (25,920,000, about 30 days at 0.1 s) ahead on the ArbSys clock. `claimBlock` and `migrationBlock` must be within `MAX_DURATION_BLOCKS` (864,000, about 24 h) after `endBlock`. The worst case is now at most 24 h during which bought tokens cannot be claimed, and the same 24 h before migration or a relaunch can start. The `uint64` sums cannot overflow, because `endBlock` is already bounded through `startBlock`. |
| **F-2** Dependencies not pinned | **Closed** | `lib/` (271 tracked files; 185 were added since `8dde1aa`), `setup.sh` | v4-core, v4-periphery, permit2, solady, OpenZeppelin, uerc20-factory, blocknumberish and forge-std are now committed. `install()` in `setup.sh` skips any directory that already exists, so the commit alone decides what is compiled. Two leftovers: `.gitignore` still says `lib/*` "is reinstalled rather than committed" and still ignores it, so a new dependency file added later would be left out silently (a clean build would then fail, which is the safe direction). No codehash or explorer-verification step was added. |
| **F-3** Giving the vault half the raise turns a good migration into recovery | **Narrowed. Not closed against a deliberate actor** | `src/KAY9Genesis.sol:651–655`, `:986–993` | `migrateAndSettle` closes the window only when it is the call that migrates. `LBPStrategy.migrate` is still permissionless (`LBPStrategy.sol:212`). An attacker contract can call `migrate` directly and then send R/2 to the vault in the same transaction, which is exactly the original attack. Or it can front-run `migrateAndSettle` with the gift, and then line 655 returns quietly. The cost (R/2 locked into liquidity for good) and the zero payoff are unchanged. So the finding is still Low, but "Fixed" overstates it. |
| **F-4** A failed sweep is swallowed and the launch still finalises | **Closed** | `:674–675`, `:681–683`, `:716–717` | Both `settle` and `recover` now revert with `UnsoldNotSwept` unless `sweepUnsoldTokensBlock() != 0`. That value is always non-zero after a sweep, because `AuctionStorage._sweepUnsoldTokens` writes the current ArbSys block. This also closes a trigger the earlier review did not name: running the `try` call out of gas on purpose. Whether this can brick anything is covered in §2. |
| **F-5** FeeSplitter wiring not checked | **Closed** (small residual) | `src/KAY9LiquidityLock.sol:96–102` | The constructor requires `feeSplitter.positionManager() == positionManager` and that some split's recipient is the beneficiary vault. `FeeSplitter._validateAndStoreSplits` already refuses a split with 0/0 bps, so the vault gets a non-zero share. The lock is deployed inside the `KAY9Genesis` constructor, so a mis-wiring fails the deployment. Residual: nothing checks the vault's own PositionManager. And if the splitter deployed on chain predates the `positionManager()` getter, deployment reverts, which is the safe outcome. |
| **F-6** Migration positions need a manual `track`/`lock` | **Narrowed** | `:652–663` | Positions minted inside `migrateAndSettle` are locked there, and the id range `[firstId, endId)` holds only mints made by this call. Positions are still left unlocked in two cases: (a) anyone migrates directly through the strategy (then `migrateAndSettle` reverts with `InitializerNotRegistered`, and `settle()` does not lock them), and (b) a good migration is misread as failed (the silent return at `:655`). They cannot be withdrawn in either case. |
| **F-7** Emission shape is free | **Narrowed** | `:778–782`, `MAX_STEP_MPS` `:315` | The cap applies to each step's per-block rate, not to how much of the supply ends up concentrated. A schedule of 4e6 + 4e6 + 2e6 mps over three consecutive one-block steps, which sells 100 % in about 0.3 s, still passes. Steps with 0 mps are still allowed. It does stop selling more than 40 % in a single block. |
| **F-8** "At most one wei" is not what the code guarantees | **Rejection accepted** | `:1133–1155` | My arithmetic is below. The earlier review inverted the ratio: one wei of ETH buys about 6.4e4 units of liquidity, so what is left after the mint is under one wei plus the rounding of the X96 steps. On the fee point: the factory's `PROTOCOL_FEE_CONTROLLER` is `immutable` (`ContinuousClearingAuctionFactory.sol:18`), and `ProtocolFeeLib.getProtocolFeeAmount` returns 0 for a zero controller (`:27`). If the chain value is zero as the project says, the fee is zero for good. I did not check the chain. |
| **F-9** Vesting is anchored to the planned TGE | **Acceptance agreed** | `src/KAY9TeamVesting.sol:145–154` | This is by design, and the design makes it public. The code is unchanged. |
| **F-10** `renounceOwnership` strands the allocation | **Closed** | `:687–689` | The override reverts with `OwnershipCannotBeRenounced`. `Ownable2Step.transferOwnership(address(0))` only sets a pending owner, and nobody can accept that, so there is no other way to renounce. |
| **F-11** Launch script accepts any feed on mainnet | **Closed** (for the script) | `script/Launch.s.sol:97–99` | On chain 4663 the feed must be `book.ethUsdFeed`, and `RobinhoodAddresses.sol:63` sets that to a non-zero address. The contract itself still accepts whatever the Safe signs, which is how the design is meant to work. |
| **F-12** `lockAll` iterates a list anyone can grow | **Acceptance agreed** | `src/KAY9LiquidityLock.sol:162–170` | The launch path uses only `lock(tokenId)`, now also through `migrateAndSettle`. |

### F-8 arithmetic

- ETH is currency0 and KAY9 is currency1.
- The price is P ≈ 4e9 raw KAY9 wei per ETH wei, so √P ≈ 63,246 and the tick is about ln(4e9)/ln(1.0001) ≈ 221,100.
- `tickLower` is the anchor floored to spacing plus 200, so √Pa ≈ 63,246 · 1.0001^100 ≈ 6.39e4.
- `tickUpper` = 887,200, so √Pb ≈ 1.0001^443,600 ≈ 1.8e19.
- For a currency0-only range, L = amount0 · √Pa·√Pb / (√Pb − √Pa) ≈ amount0 · √Pa ≈ **6.4e4 liquidity per wei**.
- So the smallest amount of ETH that makes one unit of liquidity is about 1.6e-5 wei. The earlier figure "2⁹⁶/sqrtPriceX96 ≈ 6e4 wei" is this value inverted.
- `getLiquidityForAmount0` rounds L down, and the PositionManager rounds amount0 up from L. So ETH used = ⌈⌊a·k⌋/k⌉ ≤ a, and what remains is 0, or at most 1 wei from the floor on the intermediate X96 value.
- The cap `maxLiquidityPerTick` (about 3.8e34) is far above what any real raise produces (about 6e22 per ETH).

---

## 2. Defects in the changes, most severe first

No High or Medium defect was introduced. The items below are Low or Informational.

### 2.1 Low: `migrateAndSettle` can still be forced into "failed", and then returns quietly with the official-pool positions unlocked

**Where:** `src/KAY9Genesis.sol:651–655`

**Scenario:**
1. The auction graduates with raise R.
2. Before or in the same transaction as the migration, an attacker sends ≥ ⌈R/2⌉ wei to the vault.
3. Either the attacker calls `LBPStrategy.migrate` itself, or an honest user calls `migrateAndSettle`.
4. `_migrationOutcome` reads `_raiseCameBack == true` and so returns `succeeded = false`. `migrateAndSettle` returns without an event and without locking anything.
5. `recover()` then builds the hookless pool from the gift and the unsold supply.
6. The official pool's migration position(s) stay in the lock, untracked and unlocked, until someone calls `track` and `lock`. The creator fee is unregistered until then.
7. `poolKey()` now names the recovery pool.

Nothing is stolen and the attacker loses R/2. This is F-3 and F-6 surviving, not a new loss. The quiet return is new behaviour, and a caller (the website) cannot tell it apart from a true failure except by reading `launchState()` afterwards.

### 2.2 Low: `UnsoldNotSwept` turns an auction-side token shortfall from "settled with tokens stuck" into "settle and recover revert"

**Where:** `:675`, `:717`

`sweepUnsoldTokens` moves `remainingSupply()` (rounded down) out of the auction's KAY9 balance. If the per-bid `tokensFilled` amounts that bidders have already claimed (`claimBlock == endBlock`, so claims can come before migration) ever add up to more than `TOTAL_SUPPLY − remainingSupply` by even one wei, the sweep's transfer reverts. The old code finalised anyway. The new code refuses `settle`, `migrateAndSettle` and `recover`, and team vesting stays closed.

It is **not permanent**: anyone can send the missing KAY9 dust to the auction and retry. Per-bid fills are rounded down (`CheckpointAccountingLib`), which makes such a shortfall unlikely, but I did not prove the CCA stays solvent. The out-of-gas case is only transient, because `checkpoint()` is public and settlement runs after the end block is already checkpointed.

**Suggested step:** put "if `UnsoldNotSwept`, top the auction up with KAY9 dust" in the runbook.

### 2.3 Informational: a direct `LBPStrategy.migrate` makes `migrateAndSettle` revert

**Where:** `:653`

Whoever migrates first through the strategy (a bot, or an attacker as in 2.1) makes the website's only migration button revert with `InitializerNotRegistered`. Recovery is manual: `settle()` plus `track`/`lock` for each migration position. The website should detect "already migrated" and offer those calls.

### 2.4 Informational: `MAX_STEP_MPS` bounds the rate per block, not concentration

**Where:** `:779–781`

See F-7. It **does not refuse any launch built by `script/Launch.s.sol`**. I replicated `AuctionSteps.convexSchedule` with the same integer arithmetic for every duration the script can produce (1–24 h = 36,000–864,000 blocks):
- The largest step is always the final block.
- It ranges from 2,928,581 mps (17 h) to 3,080,651 mps (16 h).
- Headroom below 4e6 is at least 9.2 percentage points.
- No ramp step is anywhere near the cap.

### 2.5 Informational: the timing bounds do not refuse a script launch

**Where:** `:765–769`

The script caps `startDelayMinutes` at 43,200. That gives `startBlock = chainBlockNumber_at_script + 25,920,000`, exactly `MAX_START_DELAY_BLOCKS`. Because the Safe executes later on the same clock, `startBlock ≤ now + MAX` holds. The script also sets `claimBlock = endBlock` and `migrationBlock = endBlock + 1`, both inside the bounds.

The existing opposite risk is unchanged: a small `START_DELAY_MINUTES` plus slow Safe signing reverts with `StartBlockInPast`.

### 2.6 Informational: lock constructor check scope

**Where:** `src/KAY9LiquidityLock.sol:96–102`

The check depends on the splitter deployed on chain exposing `positionManager()`. The vendored `FeeSplitter.sol:38` does. If the deployed one does not, construction reverts, which is fail-safe. The vault's PositionManager is not checked.

### Things I checked that were fine

- **Reentrancy through the strategy or the PositionManager:**
  - The strategy is transient-nonReentrant.
  - Its ETH goes to the empty `receive()`.
  - The PositionManager mints with `_mint`, which makes no callback.
  - The official pool's hook has only `beforeInitialize`, and only the strategy can call it.
  - The later `lock()` calls reach only the canonical vault and splitter.
  - `migrateAndSettle` is itself `nonReentrant`, and it shares the guard with `settle` and `recover`.
- **The `nextTokenId` range:** it holds only mints made inside this call. All definitions use `overridePositionRecipient = 0`, so every id in the range belongs to the lock. The `isLocked` / `ownerOf` guard is redundant but harmless.
- **On a genuinely failed migration,** the quiet return is correct: the raise is in the vault, and `recover` is the next step.
- **On a non-graduated auction,** `migrateAndSettle` just releases the reserve early. After that, `launchState()` is `Failed`, and the relaunch branch skips `_releaseStrategyReserve`.
- **Running settle in the same transaction** also removes the chance to move the price between migration and `_settleRemainder` / `_placeLeftoverEth`.
- **`renounceOwnership` override:** narrowing `nonpayable` to `view` is a legal override.

---

## 3. The nine properties at `5464d26e`

1. **Supply fixed at 1,000,000,000, shrinks only by a holder burning their own — holds.** `KAY9Token` has not changed since the last review.
2. **Exact 455 M / 455 M / 90 M split — holds.** The constants are at `:262–268`, and the vesting is funded at `:436`. Nothing in this area changed.
3. **The owner supplies pricing and timing only — holds.** The timing is now bounded (F-1), the per-block emission rate is capped (F-7, narrowed), and ownership cannot be renounced (F-10). There is still no withdraw function, and every trust-relevant field is still built in `_buildParams`.
4. **Every wei of the raise ends in locked liquidity except at most one wei; unsold tokens never reach the team — holds.** The "one wei" bound is correct (F-8). A donated gift also ends up in locked liquidity. The protocol fee is zero only if the chain's controller is `address(0)`, which I did not check on chain.
5. **A non-graduating auction refunds every bidder; relaunch only after failure is marked and 48 h pass — holds.** The relaunch wait can now be at most about 24 h plus 48 h after the end.
6. **A failed migration is rebuilt by `recover()` at the clearing price, and nobody profits from forcing it — holds.** The only way to force it on a healthy launch is still the R/2 gift (2.1), which pays the actor nothing.
7. **The team receives nothing before the launch has settled, then exactly the calendar — holds.** The new `UnsoldNotSwept` gate can delay settlement (2.2), but anyone can clear that by sending KAY9 dust to the auction.
8. **A locked LP position can never be withdrawn — holds.** Positions parked in the lock or in the FeeSplitter still have no exit.
9. **Every block number is read on the chain's clock — holds.** `BlockNumberish` is now in the tree. It picks ArbSys when address `0x64` has code and answers `arbBlockNumber()` at construction, and otherwise falls back to `block.number`. Nothing in scope derives a value from `block.number`; `Launch.s.sol` only prints it. This depends on `0x64` answering on chain 4663, which I did not check.

---

## 4. What I did not cover

- I built nothing and ran no tests, fuzzing, Slither or fork tests. The regression tests named in the dispositions were not read.
- I did not check any chain state: the factory's protocol-fee controller, whether the deployed FeeSplitter has `positionManager()`, the vault wiring, or ArbSys at `0x64` on 4663.
- I did not prove the CCA's token accounting is solvent (the question behind 2.2), and I did not work through its tick-iteration gas.
- I did not check the committed dependency files byte for byte against the upstream commits that `setup.sh` names.
- I did not re-read `KAY9TeamVesting`, `KAY9Token` or `Deploy.s.sol`, which are unchanged since `8dde1aa`, beyond spot checks.
- Out of scope: the audit contracts, the website and the services.

## 5. Model

Claude Opus 5.5 (model id `claude-opus-5-5[1m]`), Anthropic.

## Confirmation at `launch-review-5`

The final contract change (the pre-migration gift, R-01 in the OpenAI verification and 2.1 above)
was confirmed by a fresh Claude Opus 5.5 session (`claude-opus-5-5`), reading only
`launch-review-5`: **narrowed**, closed for every migration that runs through `migrateAndSettle`,
no defect introduced, and all nine properties hold. What stays open is the accepted path above: an
actor who calls `LBPStrategy.migrate` directly and gives the vault half the raise in the same
transaction, which costs them half the raise, locked into KAY9 liquidity, and returns nothing.

### The confirmation, verbatim

# KAY9Genesis final-change verification: launch-review-5 (`41e30ecd`)

## 1. Residual (pre-migration balance poisoning via `migrateAndSettle`): **narrowed** (closed for the call that runs the migration)

**What changed.** `migrateAndSettle` (`src/KAY9Genesis.sol:651-676`) now decides the outcome differently:
- It reads `getSlot0` on the official key before `lbpStrategy.migrate` (`:654`) and again after it (`:656`).
- It returns early unless the price went from zero to non-zero (`:665`).
- Otherwise it calls `_recordOutcome(true)` (`:666`) before `_settle` (`:675`).
- `_settle` then finds `outcomeRecorded` set and never reaches `_raiseCameBack` (`:961`, `:997-1004`).

A gift sent to the vault before this call no longer changes the outcome. It ends up in `_placeLeftoverEth` as locked, single-sided ETH. The new unit test `test_migrateAndSettleIgnoresAGiftSentBeforehand` covers this case.

**Can anything other than this launch's migration initialize the official pool during this call?** No.
- `LBPStrategy.migrate` (lib `LBPStrategy.sol:212-265`) reverts unless `registeredPoolIds[officialId] == auction` (`:237`). So it can only act on this launch's initializer.
- The key it builds uses the stored `poolParameters.hook == poolHook`. That is non-zero, so the hookless-to-strategy-hook fallback (`:241-247`) is never taken.
- `poolHook` is validated at construction (`KAY9Genesis.sol:413`, `:452-458`) as an InitializerHook with an immutable `authorized == lbpStrategy` (`InitializerHook.sol:20`, `:54`). Only the strategy can call `initialize` on that key.
- The strategy is `ReentrancyGuardTransient`, so no other initializer can be migrated or registered inside this frame. Genesis's `settle` and `recover` share Genesis's own guard.
- No external call during `tryMigrate` hands control to arbitrary code:
  - the CCA's `sweepCurrency` sends ETH to the strategy;
  - the PositionManager uses the non-safe `_mint` (`PositionManager.sol:369`), so there is no ERC-721 receiver callback;
  - KAY9 and ETH go back to the vault, whose `receive()` is empty.
- If `tryMigrate` reverts, its `initialize` is rolled back by the try/catch (`LBPStrategy.sol:251`), so `priceAfter == 0` and the function returns (`:665`).

**Can `priceBefore` be non-zero for a legitimate `migrateAndSettle`?** No.
- `launch` refuses to start if the official pool already exists (`KAY9Genesis.sol:490-491`).
- From `launch` until `migrate`, the key is reserved to `auction`, so other distributions get `PoolIdOccupied`, and the hook blocks direct initialization.
- The only way to see `priceBefore != 0` is for a migration to have already run. In that case `migrate` itself reverts first, with `InitializerNotRegistered`.
- The `priceBefore != 0` guard in `:665` is therefore defensive and never fires on a legitimate call.

**Is recording success here ever wrong?** No. Zero before and non-zero after, inside one non-reentrant call to the strategy for this launch's registered initializer, can only mean that initializer's `tryMigrate` finished without reverting. That includes the position mint to `liquidityLock`.

**Why narrowed rather than closed.** `LBPStrategy.migrate` has no access control. An attacker can call it directly at `migrationBlock` and send the vault half the raise in the same transaction. After that:
- `migrateAndSettle` reverts with `InitializerNotRegistered`.
- `settle` reads the balance (`:519`) and reverts with `PoolNotReady`.
- `recover` runs. The gift and the leftover supply go into the hookless pool, and `poolKey` points there.
- The migration's LP position sits in `liquidityLock` until someone tracks and locks it (the pre-existing F-6 path).

This is the same window accepted at launch-review-4 and documented at `:979-990`: the attacker loses half the raise into locked liquidity, gets nothing back and strands nothing. The "gift before migration" variant is closed only when `migrateAndSettle` is the call that migrates. An attacker who runs the migration themselves still reaches the old window.

## 2. Defects introduced by this change

None found.

- `officialId` is computed from the same immutables the strategy's stored key uses.
- The early return on a failed migration leaves the outcome unrecorded, as before, so `recover` stays reachable.
- The id-range lock loop and `_settle` are unchanged.
- Informational only, not a defect: ETH already in the vault from an earlier launch that was relaunched without `recover` is now placed by `_placeLeftoverEth` on a good migration. Before, it made that migration read as failed. Either way it ends in locked liquidity.
- The fork-test repair (re-applying the ArbSys mock with `_setBlock` after `vm.clearMockedCalls`) is correct. It strengthens the recovery assertions: at most 1 wei left, and a non-zero sweep block.

## 3. The nine property verdicts

No verdict changes. All nine still hold.
- **Property 4:** the bound is unchanged at one wei, plus any gift, which also ends in locked liquidity.
- **Property 6:** still depends on the gift path. That path is now reachable only when the attacker makes the direct `lbpStrategy.migrate` call themselves, not by a gift ahead of an honest `migrateAndSettle`.

## 4. Reviewer

Claude Opus 5.5 (1M context), model ID `claude-opus-5-5[1m]`.

## The review, verbatim

# KAY9 launch path — independent model review

**Tree reviewed:** `kay9-protocol` at commit `8dde1aa0eec443a63ad065e653d2529a96aabbd9` (tag `launch-review-3`), read exclusively through `git show <commit>:<path>` / `git ls-tree`. The first two lines of `src/KAY9Genesis.sol` at that commit are:

```
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
```

Files read in full: `src/KAY9Genesis.sol`, `src/KAY9Token.sol`, `src/KAY9TeamVesting.sol`, `src/KAY9LiquidityLock.sol`, `src/libraries/{AuctionPriceLib,AuctionSteps,TickRange,CalendarMonths}.sol`, `src/interfaces/uniswap/*`, `script/Deploy.s.sol`, `script/Launch.s.sol`, `script/config/RobinhoodAddresses.sol`, `setup.sh`, `foundry.toml`, `remappings.txt`, `.gitignore`, `.env.example`, `Makefile`, `deployments/*.json`, and under `lib/`: `LBPStrategy.sol`, `SelfInitializerMixin.sol`, `LiquidityLauncher.sol`, `Multicall.sol`, `Permit2Forwarder.sol`, `InitializerHook.sol`, `MigratorParams.sol`, `PositionPlanner.sol`, `TokenPricing.sol`, `TickCalculations.sol`, `FeeSplitter.sol`, `BeneficiaryVault.sol`, `UERC20BeneficiaryVault.sol`, `ProtocolFeeLib.sol`, `ProtocolFeeController.sol`, `ContinuousClearingAuction.sol`, `ContinuousClearingAuctionFactory.sol`, `AuctionStorage.sol`, `StepStorage.sol`, `TickStorage.sol`, `CheckpointStorage.sol`, `StepLib.sol`, `ConstantsLib.sol`, `MaxBidPriceLib.sol`, `PriceLib.sol`, `DemandLib.sol`, and the launcher/CCA interface files. Test files were only skimmed for names and for the Uniswap stack they build. Line numbers below are 1-based in the file at this commit.

This is a model review, not a professional audit. No code was executed.

---

## Findings, most severe first

### F-1. Medium — `launch()` puts no upper bound on `startBlock`, `claimBlock` or `migrationBlock`, so one wrong parameter can freeze the whole pipeline for years

**File:** `src/KAY9Genesis.sol`, `_validate`, lines 690–706 (specifically 691, 696, 697).

Only lower bounds are enforced: `startBlock > now`, `endBlock − startBlock ∈ [36 000, 864 000]`, `claimBlock ≥ endBlock`, `migrationBlock > endBlock`. Nothing bounds how far in the future any of them may be. `Launch.s.sol` produces sane values (`claimBlock = endBlock`, `migrationBlock = endBlock + 1`, delay ≤ 30 days — lines 130, 164–165), but the contract accepts anything the owner Safe signs.

Failure scenario (mistake or malice, the contract cannot tell them apart):

1. The Safe signs `launch(p)` with `migrationBlock = endBlock + 3 × 10⁸` (a pasted digit, or a hostile owner) — every other field is normal.
2. The auction runs and graduates. Bidders' ETH is in the auction, the 455 M reserve is in the strategy.
3. `LBPStrategy.migrate` reverts `MigrationNotYetAllowed` until block `endBlock + 3 × 10⁸` (≈ 1 year at 0.1 s). `registeredPoolIds` stays set, so `_migrationOutcome` reports `attempted = false`, `launchState()` is `AuctionEnded` (never `Failed`), `recover()` reverts `NothingToRecover`, `markFailed()` reverts `NotFailed`, and a relaunch is impossible. No code path can move the raise or the reserve until then.
4. The same holds for a non-graduated auction: the relaunch branch calls `_releaseStrategyReserve` → `migrate`, which reverts for the same span, so the 48-hour relaunch promise becomes a one-year promise.
5. Independently, `claimBlock = 2⁶⁴ − 1` makes every bidder's filled tokens unclaimable forever (`claimTokens` is gated by `onlyAfterClaimBlock`); bidders can `exitBid` for their unspent ETH but the tokens they paid for stay in the auction.

Nothing is stolen, but the design's claim that the owner "supplies pricing and timing only" is weaker than it sounds when "timing" includes an unbounded lock-up of buyers' assets and of the raise. The `LaunchConfigured` event lets a diligent bidder inspect the values, but no bidder should have to.

**Suggested fix:** bound the three values on the auction clock, mirroring what the script already does off-chain, e.g. `startBlock ≤ now + 30 days / 0.1 s`, `claimBlock ≤ endBlock + MAX_DURATION_BLOCKS`, `migrationBlock ≤ endBlock + MAX_DURATION_BLOCKS` (or tighter). Consider fixing `claimBlock = endBlock` and `migrationBlock = endBlock + 1` in the contract outright, since the script never chooses anything else.

### F-2. Medium — the bytecode that ships depends on unpinned third-party sources; the reviewed commit does not determine what is compiled

**Files:** `setup.sh` lines 45–52; `.gitignore` (`lib/*` ignored except the two vendored trees); no `foundry.lock`, no `.gitmodules`; `test/utils/InitializerHook.sol` line 19.

Only `liquidity-launcher` and `continuous-clearing-auction` are committed. `setup.sh` fetches `forge-std`, `v4-core`, `v4-periphery`, `permit2`, `solady`, `uerc20-factory` and `blocknumberish` with `forge install --no-git <org/repo>` and no tag or commit; only OpenZeppelin is pinned (`@v5.4.0`). It then patches Permit2 pragmas with `sed`. The test helper states that the repository "pins" v4-periphery 1.0.4; nothing in the tree enforces that.

Code from those unpinned trees is compiled *into* `KAY9Genesis`: `Actions.MINT_POSITION/SETTLE/TAKE_PAIR` constants, `ActionConstants.CONTRACT_BALANCE`, `Hooks.ALL_HOOK_MASK / BEFORE_INITIALIZE_FLAG / isValidHookAddress`, `TickMath`, `LiquidityAmounts`, `StateLibrary.getSlot0` slot layout, `PoolKey`/`PoolId` hashing, and `BlockNumberish` (which decides whether block heights come from ArbSys or `block.number`, property 9).

Failure scenario: the owner (or a verifier) clones this exact commit next month, runs `setup.sh`, and gets a newer `v4-periphery` HEAD in which an `Actions` value or the `PositionManager` plan encoding changed. `_mintAndLock` (lines 1105–1115) then encodes a plan the deployed PositionManager rejects or misinterprets; `settle()` and `recover()` revert forever, or, in the worse case, the review of this commit does not describe the deployed bytecode at all. Nothing in the repository would flag it.

**Suggested fix:** pin every dependency to a commit (submodules at fixed SHAs, or `forge install org/repo@<sha>` plus a committed `foundry.lock`), record the resulting `codehash`es in `deployments/4663.json`, and make Blockscout source verification part of the launch gate so the public can rebuild the exact bytecode from this tag.

### F-3. Low — sending half the raise to the vault before `settle()` turns a successful migration into the recovery path (documented and accepted by the code; the cost is small at the reference parameters)

**File:** `src/KAY9Genesis.sol`, `_raiseCameBack` lines 909–916, used at line 883; `recover` lines 633–682; `markFailed` lines 582–588; `receive()` line 438.

The only discriminator between "our migration succeeded" and "a stranger built the pool" is whether the vault holds at least half of `currencyRaised()`. The vault accepts ETH from anyone.

Failure scenario:

1. The auction graduates with a raise R. Anyone calls `LBPStrategy.migrate`; the official pool is built and the LP position lands in `KAY9LiquidityLock`.
2. Before anyone calls `settle()`, an attacker sends `R/2` ETH to the vault (a plain transfer, one transaction; it can also be done before migration, or even before the auction).
3. `_migrationOutcome` now reads `(true, false)`: `launchState()` is `Failed`, `settle()` reverts `PoolNotReady`, `markFailed()` succeeds and starts the 48-hour relaunch clock, and `recover()` initialises the **hookless** pool at the clearing price, mints the gift plus every unsold KAY9 into it, and `poolKey()` names that pool from then on.
4. Result: the launch's liquidity is split across two pools, the website/oracle are pointed at the smaller one, and the relaunch clock has been started on a healthy launch (the relaunch itself is later refused by `OfficialPoolExists` and `InsufficientLaunchBalance`, so no further harm).

The attacker gains nothing and their ETH is locked for good, which is why this is Low. But the reference launch raises about 1.8 ETH (`Launch.s.sol` line 62), so fragmenting the launch costs well under 1 ETH, and the comment in `_raiseCameBack` itself names the closing move without the contract offering it.

**Suggested fix:** add a permissionless `migrateAndSettle()` to `KAY9Genesis` that calls `lbpStrategy.migrate(ILBPInitializer(auction))` and then runs the `settle()` body in the same transaction, and make it the only entry the runbook and the website use. That closes the window completely without changing the discriminator.

### F-4. Low — `settle()` and `recover()` swallow a failing `sweepUnsoldTokens` and still mark the launch settled, after which no caller can ever sweep

**File:** `src/KAY9Genesis.sol`, `_sweepUnsoldTokens` lines 971–976 (try/catch), called from `settle` line 618 and `recover` line 648.

`KAY9Genesis` is the auction's only `TOKENS_RECIPIENT`, and it calls `sweepUnsoldTokens()` only from `settle()`, `recover()` and the relaunch branch. Once `settled == true`, all three are closed (`AlreadySettled`, `NothingToRecover`, `WrongLaunchState`). If the sweep ever reverted inside the try/catch, `_settleRemainder` would run on the vault's balance alone and finalise, leaving the unsold supply in the auction with no remaining caller. I could not construct a trigger (the sweep's preconditions are all satisfied after a migration and KAY9 transfers cannot fail), so this is defensive, but the pattern "swallow, then finalise" is the wrong shape for a one-way state change.

**Suggested fix:** after `_sweepUnsoldTokens()`, require `sweepUnsoldTokensBlock() != 0` before `_settleRemainder`, or drop the try/catch in `settle()`/`recover()` and let a real failure surface.

### F-5. Low — the lock and the deploy script do not check that the FeeSplitter and BeneficiaryVault are wired to each other and to the PositionManager

**Files:** `src/KAY9LiquidityLock.sol` constructor lines 74–91 and `lock` lines 127–141; `script/Deploy.s.sol` lines 134–149 (addresses taken from the address book unchecked, unlike the hook at 253–257).

Every `_mintAndLock` ends in `liquidityLock.lock(tokenId)`, which calls `beneficiaryVault.registerBeneficiary` and then `safeTransferFrom(this, feeSplitter, tokenId)`; `FeeSplitter.onERC721Received` reverts unless `msg.sender` is *its* PositionManager. The constructor guards one mis-wiring (recipient == vault) precisely because a reverting `lock()` bricks `settle()` and `recover()`, but not the others.

Failure scenario: the address book carries a FeeSplitter or BeneficiaryVault bound to a different PositionManager (there are two FeeSplitters on the chain per the project's own notes), or one whose splits do not pay the beneficiary vault. In the first case `recover()` reverts inside `lock()` every time, so a failed migration's entire raise is stuck in the vault and the team vesting never opens. In the second case the creator registers as beneficiary of a fee stream that never reaches that vault.

**Suggested fix:** in the constructor assert `IFeeSplitter(feeSplitter).positionManager() == positionManager`, the vault's PositionManager likewise if it is exposed, and that `feeSplitter.getSplits()` contains the vault as a recipient; or perform the same reads in `Deploy.s.sol` before broadcasting.

### F-6. Low — the LP position(s) the migration mints are parked in the lock but nothing in the launch path tracks or locks them

**Files:** `src/KAY9LiquidityLock.sol` lines 93–103 and 156–164; `src/KAY9Genesis.sol` `settle` lines 612–621.

The canonical PositionManager mints with a plain `_mint`, so the migration position arrives without `onERC721Received`; the lock's own comment says so. `settle()` locks only the position it mints itself. `PositionPlanner.resolve` can mint **two** positions for KAY9's plan (the weighted full-range definition and the implicit full-range fallback with the remainder, `lib/.../PositionPlanner.sol` lines 144–176), and both need a permissionless `track(tokenId)` + `lock(tokenId)` from somebody. Until then they are not in the FeeSplitter and the creator fee is unregistered. They are not withdrawable while parked (the lock has no other exit), so this is operational rather than a loss.

**Suggested fix:** record `positionManager.nextTokenId()` in `launch()` and, in `settle()`, `track`+`lock` every id in `[recorded, nextTokenId())` that the lock owns on the official key (bounded, at most a handful); or at minimum put the `track`/`lock` calls in the runbook next to `migrate`.

### F-7. Informational — the owner also chooses the emission shape, which `KAY9Genesis` validates only for byte length

**File:** `src/KAY9Genesis.sol` lines 704–705. The CCA enforces that the steps sum to 100 % and span the window (`StepStorage._validate`), but a step's `mps` may be zero, so an owner could sell 100 % of the auction supply in the first block or only in the last. The script builds the SDK's convex schedule; the contract does not require it. Within "timing", but the website should render the schedule and the contract could at least cap any single block's share.

### F-8. Informational — "at most one wei of rounding" is not what the code guarantees

**File:** `src/KAY9Genesis.sol`, `_placeLeftoverEth` lines 1056–1078. A currency0-only range needs roughly `2⁹⁶ / sqrtPriceX96(tickLower)` wei to make one unit of liquidity; at a plausible KAY9 price (~2.5 × 10⁻¹⁰ ETH) that is on the order of 6 × 10⁴ wei, which then stays in the vault with no exit. Economically nothing, but the published figure should say "dust" rather than "one wei". The claim also silently assumes the CCA factory's protocol-fee controller is zero (see property 4).

### F-9. Informational — the vesting calendar is anchored to the planned TGE, not to settlement

**Files:** `src/KAY9TeamVesting.sol` lines 136–148; `script/Deploy.s.sol` lines 216–228. If the launch slips past `unlock6m` (two failed attempts plus cooldowns can take weeks), settlement releases 1 % + 4 % at once. Consistent with the stated property ("never brings a tranche forward"), but worth saying in public material.

### F-10. Informational — `renounceOwnership` is inherited and, before a launch, would strand 910 M KAY9

**File:** `src/KAY9Genesis.sol` line 80 (`Ownable2Step`). `launch()` is `onlyOwner` and there is no other path for the allocation. Override `renounceOwnership` to revert.

### F-11. Informational — `Launch.s.sol` accepts a non-canonical `ETH_USD_FEED` on mainnet

**File:** `script/Launch.s.sol` line 92. `Deploy.s.sol` refuses a non-canonical hook on chain 4663; the launch script does not apply the same rule to the price feed that sets the floor and the graduation threshold for good. The printed review and the decimals/staleness checks are the only guard.

### F-12. Informational — `KAY9LiquidityLock.lockAll` iterates a list any stranger can grow

**File:** `src/KAY9LiquidityLock.sol` lines 99–103, 146–154. Anyone can `safeTransferFrom` an NFT to the lock and it is tracked. `lockAll` can be made expensive; `lock(tokenId)`, which `KAY9Genesis` uses, is unaffected.

---

## The nine claimed properties

1. **Supply fixed at 1 000 000 000, shrinks only by a holder's own burn — holds.** `KAY9Token` is OpenZeppelin `ERC20 + ERC20Permit + ERC20Burnable` with a single `_mint` in the constructor and no owner, hook, pause, blacklist, fee or proxy. `burnFrom` needs the holder's allowance, which is the holder's own act.

2. **Exact 455 M / 455 M / 90 M split — holds.** The vesting contract is funded with `TOTAL_ALLOCATION = 90 M` at construction (`KAY9Genesis` line 412); `launch()` deposits `LAUNCH_ALLOCATION = 910 M` and the strategy sends `910 M − reservedTokenAmountForLP (455 M)` to the auction (`LBPStrategy` lines 83–87, 113–114); `InsufficientLaunchBalance` refuses anything less.

3. **Owner supplies pricing and timing only; no withdraw — holds, with F-1 and F-7 as the caveats.** Every trust-relevant field is built from immutables or constants (`_buildParams` lines 712–753): currency `address(0)`, `tokensRecipient = this`, `fundsRecipient` sentinel rewritten by the factory to the strategy, `validationHook = 0`, `recipient = this`, `positionRecipient = liquidityLock`, fee 10000 / spacing 200 / the validated InitializerHook, one full-range definition, one 100 % bracket. The predicted address is checked after execution. The contract has `receive()` and no function that sends ETH or tokens anywhere but the PositionManager, the lock, the auction pipeline or `burn`. Timing, however, is unbounded (F-1) and the emission shape is free (F-7).

4. **Every wei of the raise ends in locked liquidity except at most one wei; unsold supply never reaches the team — holds in substance, the bound is inexact.** A good migration spends the raise on the full-range position (the ETH side binds, as the comment argues), returns the remainder to the vault, and `settle()` places it single-sided above the clearing price. Unsold tokens go single-sided below the clearing price or are burned; the team has no path to them. Two qualifications: the residual can be tens of thousands of wei, not one (F-8); and the CCA's `sweepCurrency` (`ContinuousClearingAuction.sol` lines 664–685) deducts a protocol fee before the strategy ever sees the raise. The fee controller is immutable in the factory, and the address book pins one factory; the project's research notes say that factory's controller is zero, but I could not verify it from the code.

5. **A non-graduating auction refunds every bidder in full; relaunch only after failure is marked and 48 h have passed — holds.** `exitBid` and `exitPartiallyFilledBid` return the full bid when `!_isGraduated()` (lines 499–502, 526–531); `sweepCurrency` sweeps zero (lines 669–672); graduation is monotone so no bid can have been partially exited earlier. `launch()` requires `Failed`, a non-zero `earliestRelaunchTimestamp` and `block.timestamp ≥` it (lines 452–455); `_finalized` stops a failure from being declared before the end-block checkpoint. Caveat: F-3 lets a stranger start the 48 h clock on a healthy launch; the relaunch is then refused, so nothing is lost.

6. **A graduated auction whose migration fails is rebuilt by `recover()` at the clearing price, and nobody profits from forcing it — holds, as far as I could take it.** `recover()` prices the hookless pool with the same arithmetic as `TokenPricing` (I compared `AuctionPriceLib` line by line), refuses any other existing price, and an empty squatted pool can be re-priced by a zero-fill swap (a funded one at a cost, atomically with recovery). I found no third-party way to make `tryMigrate` revert: the hook admits only the strategy, the official pool cannot pre-exist while the key is registered, and an out-of-gas in the `try` cannot leave the `catch` enough gas to succeed, so a forced false failure through gas is not available. The only way to *reach* `recover()` on a healthy launch is F-3, which costs the actor half the raise and pays them nothing.

7. **Team receives nothing before settlement, then exactly the calendar — holds.** `releasable()`/`release()` are gated on `launch.settled()`; `settled` is set only by `_settleRemainder`, which runs only after a confirmed migration (`settle`) or after the recovery mint (`recover`); amounts and timestamps are immutable; the beneficiary role is two-step. Settlement is terminal (state `Migrated`), so a relaunch cannot reset `settled`. F-9 notes the calendar anchor.

8. **A locked position can never be withdrawn — holds.** `KAY9LiquidityLock` owns positions and exposes only `lock()` whose destination is the immutable `feeSplitter`; `FeeSplitter` has no transfer or decrease path (`collectFees` does a zero-liquidity decrease, `increaseLiquidity` only adds) and only accepts NFTs from its PositionManager. Positions parked in the lock before `lock()` (F-6) are equally unwithdrawable. F-5 is about the wiring being unverified, not about an exit.

9. **Every block number is read on the chain's own clock — holds for the reviewed code, could not be fully concluded for the dependency.** `KAY9Genesis` never touches `block.number`: `_validate` and `launchState` use `_getBlockNumberish()`, `_finalized` compares the auction's own `lastCheckpointedBlock` with the stored `endBlock`, and `block.timestamp` is used only for the relaunch delay and the Permit2 expiry. `Launch.s.sol` derives every block from `genesis.chainBlockNumber()`. The CCA and the strategy read `BlockNumberish` too. But `BlockNumberish` itself is not in the tree at this commit and is installed unpinned (F-2), so I could not read how it detects ArbSys on chain 4663.

---

## What was not covered or could not be verified

- **Third-party sources absent from the commit:** `v4-core`, `v4-periphery`, `permit2`, `solady`, OpenZeppelin, `uerc20-factory` and `blocknumberish` are not in the tree (only the two Uniswap launch trees are vendored). Statements above about `PositionManager` minting without a callback, `Actions` encoding, `LiquidityAmounts`, `Hooks` masks, `TickMath`, `StateLibrary` and the ERC-20 base rest on my knowledge of the canonical upstream code, not on reading the versions that will actually be compiled (F-2).
- **CCA internals beyond the launch path:** bid accounting (`BidLib`, `CheckpointAccountingLib`), the tick-iteration gas profile and `forceIterateOverTicks`, and the exact relation between `currencyRaised()` and the ETH the auction holds were not verified. The strategy's balance-delta check (`CurrencyRaisedMismatch`) is the safeguard KAY9 relies on there.
- **On-chain state of Robinhood Chain:** whether the address-book entries are the contracts the vendored sources describe, the CCA factory's protocol-fee controller, which of the two FeeSplitters pays the pinned beneficiary vault, and whether address `0x64` carries code for `BlockNumberish` detection. Nothing here was checked against the chain.
- **No execution:** I did not build, run the test suite, run Slither, or fork the chain; no invariant, fuzz or gas measurement is behind any statement above. The test names suggest broad coverage of the scenarios I reasoned about, but I did not read the test bodies.
- **Out of scope by the brief:** the audit protocol contracts, the website, the services, `Testnet.s.sol`, `Rehearse.s.sol`, `ComputeVesting.s.sol`, `DeployWatchdog.s.sol`, and the `Deploy.s.sol` logic for the timelock, auditor registry, access vault and audit hub (read only to the extent needed to see what `KAY9Genesis` is given).
- **Economics:** whether the floor/graduation valuations, the 1 % fee, the convex schedule or the 48-hour cooldown are good choices was not assessed.

---

**Model:** Claude Fable 5.1 (model id `claude-fable-5-1`), Anthropic.