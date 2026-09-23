# Launch-path model review — Anthropic Claude Fable 5.1, 2026-09-23

| | |
|---|---|
| Model | Claude Fable 5.1, model id `claude-fable-5-1` as the API reported it for every response |
| Interface | Claude Code subagent started fresh, with no context from the project's working session; read-only; told not to read any other review |
| Date | 2026-09-23 |
| Commit | `8dde1aa0eec443a63ad065e653d2529a96aabbd9` of `kay9T/kay9-protocol`, tag `launch-review-3`, read with `git show <commit>:<path>` |
| Scope | as the prompt states |
| Prompt | [`LAUNCH_PATH_REVIEW_PROMPT.md`](LAUNCH_PATH_REVIEW_PROMPT.md), verbatim |

This is a model review, not a professional audit. The text below was committed unedited before
any of its findings was acted on; the dispositions are added in a later commit.

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