# KAY9 contracts

One section per deployed contract: what it is for, who can do what to it, and what can and cannot
change after deployment. Nothing in this system is upgradeable. There are no proxies, no
`delegatecall`, no `selfdestruct` and no initializer patterns; every contract is exactly the
bytecode that was deployed, forever.

The signatures are fixed by [`CONTRACT_INTERFACES.md`](CONTRACT_INTERFACES.md). Behaviour is fixed
by [`../ARCHITECTURE.md`](../ARCHITECTURE.md). The threat model and test matrix are in
[`SECURITY.md`](SECURITY.md).

---

## Address table

Filled in after the mainnet deployment. Every entry is verifiable on
`https://robinhoodchain.blockscout.com`.

| Contract | Address | Deployed at block | Runtime bytecode hash |
|---|---|---|---|
| KAY9Token | `0x…` | | |
| KAY9TeamVesting | `0x…` | | |
| KAY9Genesis | `0x…` | | |
| KAY9LiquidityLock | `0x…` | | |
| KAY9AuditorRegistry | `0x…` | | |
| KAY9Pricing | `0x…` | | |
| KAY9AccessVault | `0x…` | | |
| KAY9Registry | `0x…` | | |
| KAY9AuditHub | `0x…` | | |
| TimelockController | `0x…` | | |
| CCA auction (predicted) | `0x…` | | |
| Uniswap v4 pool id | `0x…` | | |

Canonical dependencies, verified 2026-09-07 (see [`RESEARCH.md`](RESEARCH.md)):

| Dependency | Address |
|---|---|
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Uniswap v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` |
| Uniswap v4 StateView | `0xF3334192D15450CdD385c8B70e03f9A6bD9E673b` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| LiquidityLauncher v3.2.0 | `0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0` |
| LBPStrategy v3.1.1 | `0x05d552391067389EE44fec3924157ed33F976000` |
| CCA factory v2.1.0 | `0x000000001F26a0044BaA66024e7b6599c61963F8` |
| FeeSplitter (40 % native to vault) | `0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf` |
| UERC20BeneficiaryVault | `0xd35E9CA72F64C7F93BE30fad67524323396B36D7` |
| CompoundingClaimRecipient | `0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a` |
| Chainlink ETH/USD | `0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9` |

---

## KAY9Token

**Purpose.** The token. OpenZeppelin ERC20 plus ERC20Permit (EIP-2612) plus ERC20Burnable, 18
decimals, name and symbol both `KAY9`.

**Permissions.** None. There is no owner, no role, no minter.

**Admin capabilities.** None whatsoever.

**Upgradeable.** No.

**What can change.** Only balances, allowances and the total supply, and the supply only downward,
by a holder burning their own balance. `burnFrom` requires an allowance like any other spend.

**What cannot change.** The supply ceiling. Exactly 1,000,000,000 × 10¹⁸ KAY9 is minted in the
constructor to `KAY9Genesis`, which is also the contract that deploys the token, and no code path
exists that can mint again. There is no pause, no blacklist, no transfer fee, no transfer hook and
no rescue function. A transfer moves exactly the amount requested.

**Verification.** `test/unit/KAY9Token.t.sol` calls every plausible mint, pause, blacklist and
ownership selector against the deployed bytecode and asserts each one fails, and scans the runtime
bytecode for those selectors.

---

## KAY9TeamVesting

**Purpose.** Holds the 90,000,000 KAY9 team allocation and releases it in three tranches at
timestamps fixed at deployment: 10,000,000 at the token generation event, 40,000,000 six calendar
months later, 40,000,000 twelve calendar months later.

**Permissions.** The beneficiary, and only for one thing.

**Admin capabilities.** `transferBeneficiary(address)` hands the beneficiary role to another
address. That is the entire administrative surface. There is no owner.

**Upgradeable.** No.

**What can change.** The beneficiary address, and the `released` counter as tranches are drawn.

**What cannot change.** The three timestamps and the three amounts, which are immutables. `release()`
is permissionless: anyone may trigger it, and it always pays the current beneficiary. A tranche is
unlocked at the instant `block.timestamp` reaches its timestamp and not one second earlier. Nothing
can accelerate a tranche, withdraw the unvested remainder, or move any other token out of the
contract.

**Calendar dates.** The unlock timestamps are computed off-chain with
`script/ComputeVesting.s.sol`, which adds whole calendar months while keeping the day of month and
the time of day in UTC, clamping to the last day of the month when the target month is too short.
They are exact dates, not 180-day approximations.

---

## KAY9Genesis

**Purpose.** The launch vault. Its constructor deploys `KAY9Token` (which mints the whole supply to
the vault), deploys and funds `KAY9TeamVesting` with 90,000,000 KAY9, and deploys
`KAY9LiquidityLock`. The vault then holds the 910,000,000 KAY9 launch allocation and is the only
route by which those tokens can leave.

**Permissions.** The project owner Safe, through `Ownable2Step`.

**Admin capabilities, complete list.**

| Function | Who | Effect | Constraint |
|---|---|---|---|
| `launch(LaunchParams)` | owner | Starts the fair launch | Once, or again only after a failure has been marked and 48 hours have passed |
| `transferOwnership` / `acceptOwnership` | owner | Moves the owner role | Two-step |

There is no withdraw, no rescue, no pause and no parameter setter. `settle()`, `recover()` and
`markFailed()` are permissionless.

**Upgradeable.** No.

**What the owner controls.** Only pricing and timing: the auction start, end, claim and migration
blocks, the Q96 floor price, the auction price-tick granularity, the graduation threshold, the
emission schedule and a salt. Every one of those is echoed in the `LaunchConfigured` event together
with the implied floor valuation and the implied graduation raise, so the website can show them
before the launch runs.

**What the contract fixes, and the owner therefore cannot change.**

- the strategy is the canonical `LBPStrategy` address, an immutable
- `MigratorParameters.token` is KAY9 and `currency` is native ETH
- `reservedTokenAmountForLP` is exactly 455,000,000 KAY9 and the distributed amount is exactly
  910,000,000 KAY9
- the pool is fee `10000` (1 %), tick spacing `200`, hook = Uniswap's canonical `InitializerHook`
  (`0xD462a559337859369EF271814851A18F496ba000`). The hook holds the `beforeInitialize` permission
  and no other, takes no hook data, and refuses every caller but the LBPStrategy, so the pool key
  cannot be squatted before the launch and an initialized pool is proof the migration ran. It has no
  swap, liquidity or donate logic and can never charge or divert anything
- `positionRecipient` is `KAY9LiquidityLock` and `recipient` is the vault itself
- `positionDefinitions` is a single full-range position at weight 1e7
- `lpAllocationSchedule` is a single bracket sending 100 % of the raise to liquidity
- `AuctionParameters.currency` is 0, `tokensRecipient` is the vault, `fundsRecipient` is the
  `address(1)` sentinel the factory rewrites to the strategy, and `validationHook` is 0, so there is
  no whitelist
- the auction window is between 36,000 and 864,000 blocks (about one to twenty-four hours at the
  measured 0.1 s cadence), the claim block is at or after the end block, and the migration block is
  strictly after the end block

Because the vault builds the structs itself from its own immutables and only then hands them to the
launcher, an owner cannot supply a hostile struct: there is no code path that accepts one.

**Auction address prediction.** The vault reproduces all three salt derivations, the launcher's
`keccak256(abi.encode(msg.sender, salt))`, the strategy's
`keccak256(abi.encode(strategySalt, migrationParams))`, and the factory's CREATE2 salt, and asks the
canonical factory for the resulting address before the launch executes. After the multicall it
asserts that the strategy really did register that address. `previewLaunch` exposes the same
prediction as a view for the website.

**Lifecycle states.** `launchState()` returns 0 not launched, 1 auction live, 2 auction ended,
3 migrated, 4 failed.

**Settlement.** `settle()` is permissionless and runs after migration. It claims the unsold supply
from the auction, then places everything the vault holds as a single-sided KAY9 position and locks
that position through `KAY9LiquidityLock`. Because native ETH sorts before KAY9, KAY9 is currency1
and buying KAY9 pushes the tick down, so a KAY9-only range sits *below* the current tick, at KAY9
prices above the current one. Anything under the 1,000 KAY9 dust threshold is burned instead of
placed. Unsold supply can never become a team allocation.

**Recovery.** `recover()` is permissionless and only possible when the auction graduated but the
strategy's migration reverted, which returns the raised ETH and the reserve to the vault. It
initializes the pool at the auction's final clearing price, using the same price conversion the
strategy would have used, mints one full-range position out of the ETH and the KAY9, and locks it.
The ETH has exactly one exit and it leads into the pool.

**Known residue.** The strategy forwards its leftover ETH dust to the vault after a successful
migration. Because the vault has no withdrawal path, that dust, on the order of 10⁻⁵ ETH, stays
frozen in the vault forever. That is the deliberate trade: a permanently stuck rounding remainder is
safer than an owner-callable sweep.

**Relaunch.** After a failure anyone calls `markFailed()`, which starts a 48-hour cooldown and emits
`RelaunchScheduled`. Only then, and only after the cooldown, may the owner call `launch()` again
with new pricing. The same invariants apply to the new launch.

---

## KAY9LiquidityLock

**Purpose.** The one-way door the liquidity positions pass through. It receives the LP NFTs minted
at migration and at settlement, registers the project creator-fee address as the beneficiary of each
position while it still owns it, and transfers the NFT to the Uniswap FeeSplitter, where nothing can
withdraw it again.

**Permissions.** None. There is no owner.

**Admin capabilities.** None.

**Upgradeable.** No.

**What can change.** Only the list of position ids it has seen and locked.

**What cannot change.** The position manager, the fee splitter, the beneficiary vault and the
creator-fee recipient are all immutables. `lock(uint256)` is permissionless and its destination is
fixed at deployment, so calling it is never a decision, only a chore. There is no other transfer
path out of the lock.

**Why the registration comes first.** `UERC20BeneficiaryVault.registerBeneficiary` only accepts a
call from the position's current PositionManager owner. KAY9 has no `graffiti()` function, so an
unregistered position's 40 % native fee share would flush to the vault's fallback address. The lock
therefore registers while it owns the NFT and only then hands it over. Registration is skipped only
when a beneficiary NFT already exists for that position; any other registration failure stops the
lock rather than silently forfeiting the fee stream.

**A note on discovery.** The canonical PositionManager mints with a plain `_mint` and does not call
`onERC721Received`, so a position minted straight to the lock is not announced. `lock(tokenId)`
works for any position the lock owns; `track(tokenId)` records an id so that `lockAll()` can sweep
it later. `KAY9Genesis` always calls `lock` directly with the id it just minted.

**Fee split once locked.** 40 % of the native-side fees go to the holder of the beneficiary NFT, the
project creator-fee address. 60 % of the native side and 100 % of the KAY9 side compound back into
the position through the CompoundingClaimRecipient.

---

## KAY9AuditorRegistry

**Purpose.** The set of addresses whose signatures the audit hub accepts, plus the quorum threshold.
Two of three at launch.

**Permissions.** Owner, which is the 48-hour TimelockController.

**Admin capabilities.**

| Function | Effect |
|---|---|
| `addAuditor(address)` | Adds an operator |
| `removeAuditor(address)` | Removes an operator, lowering the threshold if it would otherwise become unsatisfiable |
| `setThreshold(uint8)` | Sets the quorum, constrained to `1 <= threshold <= auditorCount` |
| `transferOwnership` / `acceptOwnership` | Moves the owner role, two-step |

Every one of those goes through the timelock, so it is visible on-chain for 48 hours before it takes
effect.

**Upgradeable.** No.

**What cannot change.** Nothing here can move funds or rewrite a recorded report. The registry only
answers who is an auditor and how many signatures a result needs.

---

## KAY9Pricing

**Purpose.** Answers one question: how much KAY9 is a tier's USD target worth right now. It combines
a time-weighted average of the official KAY9/ETH pool's tick with the Chainlink ETH/USD feed.
Uniswap v4 pools carry no built-in oracle, so the contract keeps its own ring buffer of 2,048
observations.

`usdTarget[tier]` is **the USD value of the KAY9 an access lock must hold**, not a fee and not a
price. Nothing is ever charged. `KAY9AccessVault` asks this contract once, when a period opens,
freezes the answer for that period, and does not ask again until renewal.

**Permissions.** Owner, which is the TimelockController.

**Admin capabilities.**

| Function | Effect | Constraint |
|---|---|---|
| `configurePool(PoolKey)` | Binds the official pool | Once only; the pool must be initialized and must pair native ETH with KAY9 |
| `setUsdTarget(uint8,uint256)` | Sets a tier's USD lock target, zero deactivates the tier | |
| `setParams(...)` | Sets the window and safety thresholds | Window within 15 to 120 minutes, at least two observations, non-zero gap no larger than the window, deviation at most 100 %, feed age at least the 86,400 s heartbeat |
| `setFeed(AggregatorV3Interface)` | Replaces the ETH/USD aggregator | Non-zero |
| `transferOwnership` / `acceptOwnership` | Moves the owner role | Two-step |

`poke()` is permissionless.

**Upgradeable.** No.

**Defaults.** Window 1,800 s, minimum 10 observations in the window, maximum 300 s between
observations, minimum pool liquidity 1e15, maximum deviation 5,000 bps, maximum feed age 90,000 s.
Access targets: deep `100e8`, forensic `500e8`, both set in the constructor and both active.

**Failure codes.** Every quoting getter reverts `PricingUnavailable(code)` rather than returning a
degraded number. 0 available, 1 no pool, 2 too few observations, 3 gap too large, 4 low liquidity,
5 feed stale, 6 feed invalid, 7 window not covered by stored observations. A tier whose target is
zero reverts `InactiveTier(tier)` instead, which is a configuration answer rather than an oracle
answer and must not be rendered as an outage. `pricingStatus()` returns the whole picture without
reverting, for the website.

**Conservatism rule, and which direction it points.** The KAY9 price in USD is `ethUsd / kay9PerEth`,
so a *lower* KAY9 USD price means a *larger* KAY9 requirement for the same USD target. The contract
takes the higher of the two KAY9-per-ETH readings, `max(twap, spot)`, which is the lower of the two
candidate KAY9 USD prices. A pump that makes KAY9 look expensive for a single block therefore cannot
shrink a lock, because the pumped reading has the lower KAY9-per-ETH value and is discarded. In the
other direction a dump would inflate the requirement, so the spot reading is capped at
`maxDeviationBps` above the TWAP before it is used. The error is always in the direction of asking
for more KAY9, never less, because the failure that matters is somebody buying a period cheaply
during a manipulation.

**Precision.** `getPriceInKay9` computes `usdTarget × kay9PerEth / ethUsd` in one full-precision step
rather than going through the 1e8-scaled display price, so it does not lose precision on a cheap
token. `getKay9UsdPriceE8` is a display value and rounds to 1e8.

---

## KAY9AccessVault

**Purpose.** Holds a depositor's KAY9 for one access period and tells the audit hub what that
depositor is entitled to. The deposit is a lock, not a payment: KAY9 enters from the depositor and
leaves only back to the depositor.

**Permissions.** Owner, which is the TimelockController, plus the configured audit hub for quota
only.

**Admin capabilities, complete list.**

| Function | Who | Effect | Constraint |
|---|---|---|---|
| `setAuditHub(address)` | owner (Timelock) | Names the only address allowed to move quota | Non-zero |
| `setQuota(uint8,uint32,uint32)` | owner (Timelock) | Sets a tier's per-period allowances | Each at most `MAX_QUOTA` (1000); the deep tier may not be given a forensic allowance |
| `setLockDuration(uint64)` | owner (Timelock) | Sets the length of future periods | Within 7 and 365 days |
| `transferOwnership` / `acceptOwnership` | owner | Moves the owner role | Two-step |

**There is no fifth row, and that is the point.** No function on this contract — owner-only,
timelocked, or otherwise — sends a depositor's KAY9 to any address other than the depositor. There
is no withdrawal path, no rescue, no sweep, no reward path, no burn and no slashing. `setQuota` and
`setLockDuration` do not reach into live periods either: the allowances and the expiry are copied
into the access record when the period opens, so a governance change applies to the next period and
never to one somebody is already inside.

**Upgradeable.** No.

**The tiers.**

| Tier | USD target | Period | Deep allowance | Forensic allowance |
|---|---|---|---|---|
| `TIER_DEEP` = 1 | `usdTarget[1]`, `$100` at launch | `lockDuration`, 30 days | 4 | 0 |
| `TIER_FORENSIC` = 2 | `usdTarget[2]`, `$500` at launch | `lockDuration`, 30 days | 4 | 1 |

Basic scans are not a tier here. They need no lock, no wallet and no KAY9, and never touch this
contract.

**Opening a period.** `quoteLock(tier)` returns the KAY9 a tier currently requires and the USD
target it came from, and bubbles `PricingUnavailable` when the oracle cannot be trusted. `lock(tier,
maxKay9)` takes exactly the quoted amount — `maxKay9` is the caller's slippage bound, since the
requirement is denominated in dollars but paid in a moving token — and writes it into the record as
both `lockedKay9` and `quotedKay9`. `lockWithPermit` wraps an ERC-2612 permit; a failing permit is
tolerated when the allowance is already in place, so a griefer cannot brick the call by
front-running it. A period can only be opened when the account holds no principal at all, so an
expired record must be `unlock`ed or `renew`ed first.

**The requirement is frozen for the period.** After `lock`, the oracle is never consulted again for
that period. If KAY9 doubles the next day nobody is asked for more and no period is shortened or
voided; if it halves, nobody is refunded either, because the period was opened at the price of the
day. Renewal is where the number is asked again, so the requirement tracks the token over time
without ever moving underneath somebody who is already inside a period.

**Renewal is refused before expiry, deliberately.** This is the one rule in the vault that exists
purely to close an abuse, so it is worth stating why. If a depositor could renew early they could
spend four deep audits on day one, renew on day two for no extra KAY9, and spend four more; the
allowance would be unbounded for anyone willing to send one extra transaction. At or after expiry
the period genuinely ended and there is no such problem, so `renew` requotes, settles the difference
in whichever direction it went, and starts a fresh period without an unlock-and-relock round trip.

**Upgrading is allowed mid-period**, deep to forensic only. It tops the lock up to the forensic
requirement, leaves the expiry alone, and carries `deepUsed` across. Deep allowance is four in both
tiers, so upgrading buys the forensic slot and nothing else; without carrying the used counter,
upgrading would be a way to reset the deep allowance for the price of the difference.

**Unlocking never reads the oracle.** `unlock()` returns `lockedKay9` in full at or after expiry and
touches no price feed at all. An oracle outage must be able to stop a new lock and must never be
able to trap an existing one.

**Quota is moved by the hub and by nobody else.** `consume(account, tier)` reverts unless the caller
is `auditHub`, and reverts for the requester when there is no live period, when the held tier is
lower than the requested one, or when that tier's allowance is spent. It returns the period's
`startedAt`, which the hub records on the job. `restore(account, tier, periodStartedAt)` credits a
unit back when a job produced no result, and is a **silent no-op** when the account's current period
no longer matches the one passed in — that is what stops a credit landing in a later period that did
not pay for it. Both emit events, and `deepRemaining`, `forensicRemaining` and `canRequest` are
public reads, so anybody can verify a quota without asking a website.

**What can change.** Access records, `totalLocked`, the three governed parameters, and the owner.

**What cannot change.** That the principal is the depositor's. `totalLocked` is the sum of every
principal held and includes nothing else.

---

## KAY9Registry

**Purpose.** The append-only log of committed audit results, the cross-chain asset identity scheme,
and the read surface anyone else builds on.

**Permissions.** `recordReport` is callable only by the audit hub, which is an immutable.

**Admin capabilities.** None. There is no owner.

**Upgradeable.** No.

**What can change.** Only by appending. Nothing is ever overwritten or deleted.

**What a record holds.** Beyond the `AuditResult` itself, each `ReportRecord` carries the metadata
the hub passed in: `jobId` (zero for an unsolicited watchdog report), `requester` (the zero address
for one), `declaredRequesterKind` (0 unknown, 1 independent, 2 token creator, 3 integration) and the
`tier` the request consumed. It also carries the `signers` whose signatures finalised it,
`committedAt` and `committedBlock`. The requester and their declaration are recorded because a
reader is entitled to know who asked; they are recorded *verbatim*, which is why every surface
renders `declaredRequesterKind` as declared rather than as established. Only flag bit 18 says the
requester was actually shown on-chain to be the asset's deployer.

**Why an asset has a history rather than a score.** A new audit of the same asset appends a new
record; it never replaces the old one. So an asset that scored 89 in September and 42 in October has
both records, both signed, both permanent, and a reader can see risk change over time.
Consequently `latest` means "most recent snapshot", never "current truth", and every surface that
renders it also renders `committedAt`.

**Reads.**

| Function | What it is for |
|---|---|
| `reportCount`, `getReport`, `getReports` | The whole log, newest-first paging handled by the caller |
| `historyCount`, `history` | Every report id for one asset, in commitment order |
| `latest` | The most recent full record for an asset |
| `latestSummary`, `latestSummaryForToken` | One call, no arrays of structs, no report body: the read a wallet, DEX, launchpad or badge makes |
| `scoreHistory` | Paired `committedAt` and `overallTrust` arrays: the read a trust-over-time chart makes |

`latestSummary` and `scoreHistory` exist so that consuming KAY9 risk data never requires an
off-chain API or a KAY9-operated frontend. An integrator that can call a contract can render KAY9
risk without asking anybody's permission and without a key.

Both paging functions clamp rather than revert: an `offset` at or past the end returns an empty
array, and `limit` saturates, so `type(uint256).max` means "to the end of the log" and never
overflows. A caller may therefore treat a maximal limit as "everything from here" without first
reading a count.

**Identity.** `chainKey = keccak256(bytes(caip2))`, for example `"eip155:4663"`, `"eip155:56"`,
`"solana:mainnet"`. `assetId` is `bytes32(uint256(uint160(addr)))` for EVM contracts and the 32-byte
mint key for Solana. `assetKey(chainKey, assetId) = keccak256(abi.encode(chainKey, assetId))` groups
the history of one asset.

---

## KAY9AuditHub

**Purpose.** Takes audit requests, enforces access on-chain, collects auditor attestations, and
appends finalised results to the registry.

**No KAY9 changes hands here.** There is no escrow, no fee, no payment split, no treasury share and
no burn. The only thing a request spends is a quota unit in `KAY9AccessVault`, and a request that
produces no result gets that unit back.

**Permissions.** Owner, which is the TimelockController.

**Admin capabilities.**

| Function | Effect | Constraint |
|---|---|---|
| `setSla(uint64)` | Sets how long a job may sit unanswered before anyone may expire it | Between 1 hour and 30 days; 6 hours by default |
| `setRequestsPaused(bool)` | Refuses new requests | Attestations, disputes and expiries are never pausable |
| `transferOwnership` / `acceptOwnership` | Moves the owner role | Two-step |

That is the entire list. There is no treasury setter, because there is no money to send. Pausing is
deliberately limited to *new* requests: a job that has already spent a quota unit must always be
able to reach a result, a dispute or an expiry, so that governance can never strand somebody's
allowance.

**Upgradeable.** No.

**How a request is authorised.** `requestAudit(chainKey, assetId, tier, declaredRequesterKind)`
calls `accessVault.consume(msg.sender, tier)` before it does anything else, and that call is the
whole authorisation. It reverts unless the caller holds a live period of at least the requested tier
with allowance left. The website is never consulted and cannot grant access; a wallet, a script, a
bot or another contract calling the hub directly gets exactly the same answer as a visitor clicking
a button on kay9.io, because the website was never in the path. The job records `requestedBlock`
(the chain's own height at request time, read through `BlockNumberish` — kept for the on-chain
audit trail, never the analysis pin, because an audited asset may live on another chain), the
`requestedAt` timestamp every auditor actually pins its analysis to, and `accessPeriodStartedAt`,
which is the period the quota unit came from.

**Attestation and quorum.** Each auditor takes at most one position per job. `attest(jobId, result,
signatures[])` accepts one or more 65-byte ECDSA signatures over the EIP-712 digest of `(jobId,
result)`; every recovered signer must be an active auditor and must not have attested this job
already, and the submitter must itself be an active auditor (`SubmitterNotAnAuditor`): `reportURI`
is outside the signed struct, so whoever lands the finalising transaction chooses the pointer the
registry keeps, and the signature relay is readable by anyone. The ordinary path is one transaction:
the second auditor to finish submits the first one's agreeing signature with its own. An auditor
that disagrees pays for its own transaction to say so. That asymmetry is intentional — dissent
should be frictionless but it is not the common case.

- The moment one digest reaches `auditors.threshold()` votes, the job becomes `Fulfilled` against
  that result and the record is appended to the registry.
- The job becomes `Disputed` as soon as agreement is arithmetically out of reach, that is when
  `bestAgreement + silent < threshold`, where `silent` counts **currently active** auditors who
  have not attested to this job at all, not `auditorCount − attestations`. A raw difference can
  undercount silence once the set has rotated mid-job — an attestation from an auditor since
  removed still increments `attestations` — and read a still-active, still-silent auditor as
  having already spoken. With three auditors, a threshold of two and no rotation, three mutually
  different results still dispute the job.
- Contradictory results are **never** averaged. There is no mean, no median and no tie-break that
  invents a number nobody signed. A dispute is a public on-chain state and `attestationOf` shows
  which auditor took which position.
- `markExpired(jobId)` is permissionless once `requestedAt + slaSeconds` has passed.
- `Disputed` and `Expired` both call `accessVault.restore` with the period the unit came from, so a
  caller is never charged a quota for an audit that produced no result, and the credit cannot land
  in a later period.

**Duplicate protection, and why it is not signer ordering.** For `attest`, duplicates are blocked by
`attestationOf[jobId][signer]` rather than by requiring signatures to be sorted, because signatures
for one job arrive in more than one transaction and a global ordering rule cannot be enforced across
them. The signer list stored on the finalised report is kept sorted by insertion, so the record is
canonical either way. `publishWatchdogReport` has no such history to consult, so it *does* require
signers strictly ascending by address, and each watchdog digest may be committed only once.

**Signature rules.** The EIP-712 domain is `("KAY9AuditHub", "1")` and binds the chain id and the
hub address, so a signature cannot be replayed on another chain or against another deployment. The
signed payload contains the job id, so it cannot move to another job, and `result.chainKey` and
`result.assetId` must equal the job's, so it cannot describe another asset. A job can be finalised
once.

**Requester neutrality.** Nothing in the request path reaches the scoring path. The hub records who
asked and what they declared themselves to be, and passes only `chainKey`, `assetId` and `tier` to
the auditors through the `AuditRequested` event. There is no field an auditor could read that says
the creator paid, because nobody pays.

**Watchdog reports.** `publishWatchdogReport(result, signatures[])` lets the quorum commit a report
with `jobId = 0` and no requester. Nobody asked for it and nobody paid for it, which is what makes
KAY9 a watchdog rather than a vendor. Free basic scans never touch this contract at all.

---

## TimelockController

**Purpose.** The only administrator of the audit protocol. OpenZeppelin's standard
`TimelockController` with a 48-hour minimum delay.

**Roles.** The project owner Safe is both proposer and executor. The admin role is renounced at
construction by passing `address(0)`, so the timelock administers itself and the delay cannot be
shortened without going through the delay.

**Upgradeable.** No.

**What it can do.** Exactly the administrative functions listed above for `KAY9AuditorRegistry`,
`KAY9Pricing`, `KAY9AccessVault` and `KAY9AuditHub`, each after a 48-hour public delay. It has no
power over `KAY9Token`, `KAY9TeamVesting`, `KAY9Genesis` or `KAY9LiquidityLock`, and no power over a
depositor's principal in `KAY9AccessVault`: the three functions it holds there configure the hub
address, the allowances and the period length, and none of them moves a balance.

---

## Complete admin surface

| Contract | Admin | Power | Delay |
|---|---|---|---|
| KAY9Token | none | — | — |
| KAY9TeamVesting | beneficiary | change beneficiary | none |
| KAY9Genesis | owner Safe | `launch`, and relaunch after a marked failure | 48 h for relaunch |
| KAY9LiquidityLock | none | — | — |
| KAY9AuditorRegistry | Timelock | add or remove auditor, set threshold | 48 h |
| KAY9Pricing | Timelock | USD access targets, window and thresholds, feed address, bind the pool once | 48 h |
| KAY9AccessVault | Timelock | audit hub address, per-period allowances, period length | 48 h |
| KAY9Registry | none | — | — |
| KAY9AuditHub | Timelock | SLA, pause new requests | 48 h |
| TimelockController | owner Safe as proposer and executor, itself as admin | schedule and execute | 48 h minimum |

Nothing outside this table can be changed by anyone, and one thing that is not in the table cannot
be changed by anyone at all: a depositor's principal in `KAY9AccessVault`. No row above, and no
combination of rows above, can move it anywhere except back to the depositor.
