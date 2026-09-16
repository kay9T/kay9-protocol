# KAY9 security

Threat model, invariants, test matrix, static analysis results, known risks and how to report a
vulnerability.

Disclosure contact: **security@kay9.io**

---

## 1. Design posture

The premise of KAY9 is that the website is disposable and the contracts are not. Every design
decision follows from that:

- **No upgradeability anywhere.** No proxy, no `delegatecall`, no `selfdestruct`, no initializer.
  What is deployed is what runs, forever.
- **No owner where an owner is not needed.** `KAY9Token`, `KAY9TeamVesting` (beyond handing on the
  beneficiary role) and `KAY9LiquidityLock` have no administrator at all.
- **Where governance exists, it is delayed and public.** The audit protocol's only administrator is
  an OpenZeppelin `TimelockController` with a 48-hour minimum delay whose proposer and executor is
  the project owner's address — a single account, not a multisig — and whose admin is itself.
- **Where the owner acts, the contract constrains the action.** The launch owner supplies pricing
  and timing. Every trust-relevant field of the auction and the migration is constructed by
  `KAY9Genesis` from its own immutables, so there is no code path that accepts a hostile struct.
- **Value has one exit.** Launch tokens leave the vault only into the auction and from there only
  into a permanently locked liquidity position. ETH the vault receives can only be spent into the
  pool. There is no withdraw function on any KAY9 contract.
- **There is no price oracle in the access path.** The lock requirement is a fixed number of KAY9
  per tier stored in the vault, changed only through the timelock and bounded on chain. Nothing a
  market does, and nothing an external feed does, can change what a period requires or what
  `KAY9AccessVault.unlock` returns.
- **A depositor's principal is not the protocol's.** No function on `KAY9AccessVault` — owner-only,
  timelocked or otherwise — sends a depositor's KAY9 to any address other than the depositor. There
  is no fee, no escrow, no treasury share, no burn, no reward and no slashing anywhere in the audit
  protocol, so there is no legitimate path for a depositor's tokens to travel and therefore no
  hostile one to defend.

---

## 2. Threat model

### 2.1 Assets at risk

| Asset | Where it sits | Who could plausibly want it |
|---|---|---|
| 910,000,000 KAY9 launch allocation | `KAY9Genesis`, then the auction and the strategy | the owner, a compromised owner key, a hostile integrator |
| 90,000,000 KAY9 team allocation | `KAY9TeamVesting` | the beneficiary, wanting it early |
| The raise in ETH | the auction, then the strategy, then the pool | the owner, a compromised owner key |
| The LP positions and their fee stream | `KAY9LiquidityLock`, then the FeeSplitter | the owner, a front-runner of the beneficiary registration |
| Depositors' locked KAY9 | `KAY9AccessVault` | anyone wanting principal that is not theirs, including a compromised owner |
| Access quota | `KAY9AccessVault`, moved only by the hub | a requester wanting more audits than the tier allows |
| The report history | `KAY9Registry` | anyone wanting to rewrite an unfavourable score |
| The scan history | `KAY9ScanRegistry` | anyone wanting a flattering automatic score, or none at all |
| The auditors' signing keys | three platform secret stores | anyone wanting to publish a score nobody computed |
| A scanner key | one platform secret store | anyone wanting to publish a basic scan nobody computed |

### 2.1a What a compromised scanner key can and cannot do

The scan registry is written to by a single authorised key, so it is worth being precise about how
much that key is worth stealing.

**It can** append a batch whose scans nobody computed, and give an asset a flattering `latestScan`
entry. It can also refuse to scan something, which is indistinguishable from not having got to it.

**It cannot** alter or remove a committed batch, touch `KAY9Registry`, forge a deep or forensic
report, move any token, or make a fabricated scan verify. The last one is the point: every scan is
committed to a Merkle root over a published, content-addressed document, so a forged entry either
fails `verifyScan` or appears in a document whose numbers can be recomputed from public chain state
by anybody. A basic scan is a *reproducibility* claim, not a consensus one, and reproducibility is
exactly what catches a liar.

**Which is why the two registries are separate contracts.** If a stolen scanner key could write
into the same record as a two-of-three auditor quorum, it would inherit the quorum's credibility.
It cannot, and a reader looking at either record can tell which kind of claim they are reading.

**Response to a compromise:** de-authorise the key through the timelock. Everything it committed
stays on-chain and stays checkable, which is better than the alternative — a record that could be
edited after the fact would be worth nothing even when nobody had been compromised.

### 2.2 Adversaries and what they can do

**A compromised owner key.** Can call `launch` with hostile pricing: an absurd floor, an absurd
graduation threshold, or a window at the legal minimum. It cannot redirect the raise, keep unsold
supply, change the pool parameters, change the position recipient, withdraw anything, or touch the
audit protocol without waiting out the 48-hour timelock. The residual power is *bad pricing*, which
the website displays before the fact from the `LaunchConfigured` event.

**A compromised timelock proposer.** Can schedule any of the audit protocol's administrative calls,
but the schedule is public for 48 hours before it can execute. It still cannot move a depositor's
principal, redirect anything, or alter a recorded report, because no such function exists. Its whole
reach over the vault is four setters: the hub address, the KAY9 amount *future* periods lock, the
per-period allowances, and the length of *future* periods. `test_noPathSendsAPrincipalAnywhereButHome` exercises the setters at once, from the
owner, while also holding the hub role, and asserts the principal never moved and is still returned
in full.

**A compromised auditor key.** One key is below the two-of-three quorum, so it cannot commit a
result on its own. Governance removes it through the timelock, and a removed auditor's signature is
refused from that moment. `attestationOf[jobId][signer]` means a single key cannot be counted twice
for one job, whether it tries within one transaction or across two.

**A market manipulator.** Can move the pool price within a block, and it changes nothing in the
access model: the lock requirement is a stored number of KAY9, not a quote, so no pump, dump, thin
market or stale market can shrink or inflate a lock. The residual risk is a *stale number* — a
requirement the owner has not adjusted after a large price move — and that number is public, as is
every change to it, 48 hours before the change applies.

**Two dishonest auditors.** Can commit a false result. The quorum does not protect against this and
does not claim to; §2.6 states what that means for the launch configuration in particular.

**A hostile ERC721 or ERC20.** The liquidity lock accepts NFTs only from the canonical
PositionManager. The vault's token is an immutable set at deployment, and the hub holds no tokens at
all (`invariant_hubHoldsNoKay9`); the reentrancy tests nevertheless prove that a
callback-on-transfer token cannot draw a vesting tranche twice or leave the vault holding less than
it owes.

**A donor.** Anyone can send KAY9 to the vault address. Nothing turns that into a yield, a reward,
or a larger allowance for anybody: `totalLocked` is the sum of the recorded principals and is
maintained by the lock, renew, upgrade and unlock paths, so a donation is simply stranded.
`test_aDonationIsNeverPaidOutAsYield` pins that, and it is the reason the vault tracks its
obligation explicitly rather than inferring it from `balanceOf`.

**A front-runner of the fee beneficiary.** `UERC20BeneficiaryVault.registerBeneficiary` only accepts
a call from the position's current PositionManager owner, and the lock registers in the same
transaction in which it hands the position on, so the window is closed by construction.

**Anyone at all.** `settle`, `recover`, `markFailed`, `lock` and `lockAll` on the liquidity lock,
`track`, `release` and `markExpired` are permissionless by design. None of them can direct
value anywhere the contract did not already fix, and none of them can put anything into the report
log. `attest` and `publishWatchdogReport` are **not** open to anyone: the submitter must itself be an
active auditor, because `reportURI` is the one field the signatures do not cover and whoever lands
the finalising transaction chooses it, permanently. Signatures pass through a relay anybody can read,
so an open submit path would have let a stranger race the auditors and record a dead or hostile
pointer against an honest score. The body stays bound by `reportHash`, so no score can be changed
that way; the worst case is now one of three keyed operators, attributable by `msg.sender`, which is
inside the threat model the quorum already accepts. `test_onlyAnActiveAuditorMaySubmitSignatures`.

### 2.3 Trust assumptions we do accept

- **The canonical Uniswap contracts behave as their source says.** The liquidity launcher, the LBP
  strategy, the continuous clearing auction factory, the FeeSplitter, the beneficiary vault and
  Uniswap v4 itself are audited third-party code that KAY9 integrates with rather than reimplements.
  Local tests run against those exact sources; fork tests run against the deployed bytecode.
- **Robinhood Chain's sequencer does not reorder the world arbitrarily.** The auction is
  block-based; a sequencer that censored bids could influence the clearing price. This is a property
  of the chain, not of KAY9.
- **The owner key is held by whom the project says holds it.** This is the one social assumption
  the contracts cannot remove, and since 2026-09-16 it rests on one key rather than on a multisig's
  signer set, so there is no second signature between a stolen key and a hostile launch price. It is bounded to the launch pricing decision and the timelocked
  governance calls, and it explicitly does **not** extend to depositors' principal, which no owner
  function can reach. It does, at launch, extend to two of the three auditor identities: see §2.6.
- **Two of the three auditors are honest.** The quorum is an assumption, not a proof. Where that
  assumption is weakest today is stated in §2.6 rather than left implied.

### 2.4 The access vault, threat by threat

The vault is new and holds other people's money, so its threats are enumerated rather than implied.
Each row is a property the contract must have, the reason it must have it, and the mechanism.

| Threat | Why it would matter | What prevents it |
|---|---|---|
| An external dependency traps principal | A depositor's tokens would be hostage to a price feed, a thin pool or an off-chain process — a liveness failure turning into a loss | No oracle: the requirement is a stored number changed only through the timelock. `unlock` reads nothing but the record and returns exactly `lockedKay9`. `test_aRequirementChangeNeverTouchesALivePeriodAndUnlockReturnsExactly` |
| A manipulated price allows a cheap lock | Somebody would buy a month of forensic access for a fraction of the requirement, and the allowance is the only thing bounding analysis cost | No oracle: the requirement is a stored number changed only through the timelock. The risk is a stale number, which is public 48 h before it applies; `setRequirement` is bounded to 1 KAY9 – 10,000,000 KAY9 with forensic never below deep. `test_setRequirementIsBoundedAndForensicNeverBelowDeep`, `test_setRequirementIsOwnerOnly` |
| A live period is repriced underneath its depositor | A requirement change could otherwise demand a top-up, or void access somebody already holds | `lock` copies `requirementOf[tier]` into `lockedKay9` and the record is never revisited; only `renew` (after expiry) and `upgrade` read the current number. `test_theRequirementIsFrozenForThePeriod`, `test_aFallingRequirementDoesNotRefundMidPeriod`, `test_aRequirementChangeNeverTouchesALivePeriodAndUnlockReturnsExactly` |
| Quota is farmed by renewing early | Four deep audits, a renewal the next day for no extra KAY9, four more — the allowance would be unbounded for the price of one transaction | `renew` reverts before `expiresAt`. `test_renewRevertsBeforeExpiry` |
| Quota is reset by upgrading | Upgrading deep to forensic would otherwise hand back a spent deep allowance for the price of the difference | `upgrade` carries `deepUsed` across and leaves the expiry alone. `test_upgradePreservesDeepUsedAndKeepsTheExpiry` |
| A restore credits a later period | A unit spent in one period could reappear in the next one, which did not pay for it | `restore` takes the period explicitly and is a silent no-op unless `startedAt` still matches. The hub records `accessPeriodStartedAt` on the job for exactly this |
| A hub migration strands pending jobs | If governance ever points the vault at a new hub, a job still open on the old one has to expire or dispute, and both hand the unit back through `restore`; a vault that only knew one hub made those transitions revert forever | `setAuditHub` retires the hub it replaces rather than forgetting it. A retired hub may `restore` and nothing else; `consume` stays with the current hub. `test_aRetiredHubMayRestoreButNeverConsume`, `test_aJobPendingAcrossAHubMigrationStillExpiresAndRefunds` |
| A period opens on a zero requirement | `lockedKay9 == 0` is how the vault spells "no record", so a zero requirement would open a period `consume` and `unlock` could not see, or let `renew`/`upgrade` wipe a live principal to nothing | A zero requirement cannot be configured: `setRequirement` reverts `InvalidRequirement` below `MIN_REQUIREMENT` (one KAY9). `test_setRequirementIsBoundedAndForensicNeverBelowDeep` |
| Something other than the hub moves quota | Any address that could call `consume`/`restore` would control who gets audits | Both revert `NotTheAuditHub` for every caller but the configured hub, the owner included. `test_onlyTheHubCanMoveQuota` |
| The vault owes more than it holds | Somebody's unlock would fail at the worst possible moment | `totalLocked` is maintained on every path and the balance is asserted against it: `test_vaultBalanceAlwaysEqualsTotalLockedAndNobodyGainsTokens`, `invariant_vaultIsAlwaysSolvent` |
| A governance change reaches a live period | An owner could shorten a period or cut an allowance somebody is already inside | Allowances and expiry are copied into the record at lock time. `test_changingTheDurationDoesNotMoveALivePeriod` |
| Using the whole allowance costs principal | The distinction between a lock and a fee would collapse | `test_usingEveryAuditStillReturnsTheWholePrincipal` |

### 2.5 The audit hub, threat by threat

| Threat | Why it would matter | What prevents it |
|---|---|---|
| An auditor attests twice | One key would reach a two-of-three quorum alone | `attestationOf[jobId][signer]` is checked before counting, so a repeat is refused whether it arrives in the same call or a later one. `test_anAuditorCannotAttestTwice`, `test_theSameAuditorTwiceInOneCallIsRefused` |
| A signature is replayed against another job | A result signed for a safe token would finalise a job about a different one | `jobId` is the first field of the signed struct. `test_noReplayAcrossJobs` |
| A signature is replayed on another chain or deployment | A testnet signature would finalise a mainnet job, or an old hub's signature a new hub's job | The EIP-712 domain separator binds `chainId` and `verifyingContract`. `test_noReplayAcrossChains`, `test_noReplayAcrossDeployments` |
| A result describes an asset other than the job's | The registry's history for one asset would be polluted by another's verdict | `result.chainKey` and `result.assetId` must equal the job's. `test_aResultMustDescribeTheJobsAsset` |
| A watchdog report is replayed into the log | One quorum signature set would append the same alert repeatedly | `watchdogReportCommitted[digest]`. `test_watchdogReportCannotBeCommittedTwice`, `test_watchdogReportCannotBeReplayed` |
| A job reaches two outcomes | A disputed job could later be finalised, or a fulfilled one expired, and the quota accounting would drift | The status guard at the top of every path, plus `invariant_jobsHaveExactlyOneOutcome`, `test_aDisputedJobCannotThenBeFinalised`, `test_aFulfilledJobCannotBeDisputedOrExpired`, `test_anExpiredJobCannotBeFulfilled` |
| Disagreement is hidden or averaged | A number nobody signed would be presented as a quorum verdict | Contradictory results are never combined; three mutually different results produce an on-chain `Disputed` state and restore the quota. `test_threeDifferentResultsDisputeTheJob` |
| Who requested an audit changes its score | The whole point of removing payment would be lost | Nothing derived from the requester reaches the scoring path, and the hub records the declaration verbatim. `test_creatorAndIndependentRequestsAreIdenticalExceptForMetadata`, `test_declaredRequesterKindIsRecordedVerbatim` |
| Governance strands a job mid-flight | A pause could leave a spent quota unit with no way to a result | Pausing blocks new requests only; attestations, disputes and expiries are never pausable. `test_pauseOnlyBlocksNewRequests` |
| A stranger chooses the recorded `reportURI` | The URI is outside the signed struct, so whoever submits two honest signatures picks the pointer the permanent record carries | Only an active auditor may call `attest` or `publishWatchdogReport`; `markExpired` stays open because nothing reaches the log through it. `test_onlyAnActiveAuditorMaySubmitSignatures`, `test_aRemovedAuditorCannotSubmitEither`, `test_anyoneMayStillExpireAJob` |

### 2.6 The limitation we will not bury

At launch, **two of the three auditor identities run inside accounts the project owner controls.**
`docs/AUDITOR_NETWORK.md` §4.3 gives the reason: opening accounts on three genuinely independent
commercial clouds requires a payment card this project does not have, so auditor A runs as an Azure
Container Apps job in the owner's subscription, auditor B as a GitHub Actions workflow in a separate
repository the owner also controls, and only auditor C is held by an independent operator.

There are three signing keys, three secret stores and three identities in `KAY9AuditorRegistry`, so
the quorum genuinely protects against **one** dishonest or compromised auditor. It does **not**
protect against a compromise of the owner's own accounts: an attacker holding both of the owner's
platforms holds two of three votes and can commit a result nobody computed.

That is a real limitation of the launch configuration, not a theoretical one, and it is stated on
the website in these terms rather than only here. What it cannot do even then is worth knowing: a
false result is still permanent, public, attributable to the exact keys that signed it, and
verifiable against the pinned block by anybody who re-runs the deterministic core
(`docs/WATCHDOG.md` §2.1). Forgery is possible in that configuration; quiet forgery is not.

The mitigation is a move, not a mechanism: auditors B and C onto independent platforms as soon as
either a funding method or independent operators exist, and then a set larger than three through the
timelock. `docs/ROADMAP.md` carries it as a phase.

---

## 3. Invariants

Enforced by construction and checked by the stateful invariant suite in `test/invariant/`.

| Invariant | Why it holds |
|---|---|
| Total supply never exceeds 1,000,000,000e18 | The only mint is in the token constructor; only `burn` moves the number, and only downward |
| `released <= unlocked <= 90,000,000e18` | `unlocked` is a pure function of three immutable timestamps; `release` writes state before transferring |
| The vesting balance equals `TOTAL_ALLOCATION - released` | Nothing else can move tokens out |
| `kay9.balanceOf(accessVault)` is never less than `totalLocked` | Every path that changes a principal changes `totalLocked` by the same amount in the same transaction (`invariant_vaultIsAlwaysSolvent`) |
| `kay9.balanceOf(auditHub)` is always zero | The hub has no code that receives, holds or sends KAY9 (`invariant_hubHoldsNoKay9`) |
| A depositor's principal is only ever returned to that depositor | There is no other transfer destination in the contract |
| `deepUsed <= deepQuota` and `forensicUsed <= forensicQuota`, always | `consume` checks before incrementing, `restore` checks before decrementing, and both are hub-only (`invariant_quotaUsedNeverExceedsQuotaGranted`) |
| A job reaches exactly one of fulfilled, disputed or expired, once | Every transition is guarded on `JobStatus.Requested` (`invariant_jobsHaveExactlyOneOutcome`) |
| The report log never shrinks and entries are never rewritten | `recordReport` only pushes, and only the hub may call it (`invariant_registryIsAppendOnly`) |
| A locked position stays at the FeeSplitter | The lock has no path that can pull it back |
| The genesis vault never gains tokens beyond its launch allocation | Nothing mints, and the vault's only inflows are the returns from its own launch |

---

## 4. Test matrix

This table is the requirement side of the suite: what has to be true, and the test that pins it.

As of 2026-09-11 the offline suite is green — 290 tests across 24 suites, default and `ci` fuzz
profiles — and the three fork tests pass against live Robinhood mainnet state (block 59,996,178).
`docs/STATUS.md` §3 carries the run. A green suite is evidence for the rows below, not a launch
sign-off: gate 6 of `docs/LAUNCH_READINESS.md` (model review of the launch path) is still open. A
human external review was sought and not funded; the gate now asks for reviews by two model families,
published in full, and says plainly that this is not a professional audit.

| Requirement | Test |
|---|---|
| Exactly 1,000,000,000 supply | `KAY9Token.t.sol::test_exactSupply` |
| No mint function in the deployed bytecode | `test_noMintFunction` (selector calls plus a bytecode scan) |
| No pause, blacklist, owner or upgrade surface | `test_noAdminSurface` |
| Allocations sum to 100 %: 455 M + 455 M + 90 M | `test_allocationsSumToWholeSupply` |
| Transfers have no tax | `test_transferHasNoTax` |
| Burn only destroys the caller's own balance | `test_burnOnlyOwnBalance`, `test_burnFromRequiresAllowance` |
| Team unlock boundaries to the second | `KAY9TeamVesting.t.sol::test_unlockBoundariesToTheSecond` |
| No early unlock | `test_noEarlyUnlock` |
| No owner override on vesting | `test_noOwnerOverride` |
| Beneficiary transfer rules | `test_transferBeneficiary` |
| Vesting fuzz: monotonic, never over-releases | `testFuzz_unlockedIsMonotonic`, `testFuzz_releaseNeverExceedsUnlocked` |
| Calendar month arithmetic, including clamping | `test_calendarMonthsKeepDayAndTime`, `test_calendarMonthsClampShortMonths`, two fuzz tests |
| Vendored structs encode identically to upstream | `KAY9Launch.t.sol::test_vendoredStructsMatchUpstream`, `test_migrationParamsEncodingMatchesUpstream` |
| Every malformed `LaunchParams` reverts | `test_malformedParamsRevert`, eleven cases, asserting nothing moved |
| 1 % fee and tick spacing 200 | `test_migrationParamsAreFixedByTheContract`, `test_graduationMigrationAndLock` |
| Recipients fixed by the contract | `test_auctionRecipientsAreFixedByTheContract` |
| Auction address prediction | `test_launchMovesFullAllocation` |
| Emission schedule satisfies the auction's invariants | `test_auctionStepsInvariants` |
| Creator fee registration | `KAY9LiquidityLock.t.sol::test_lockIsOneWay` |
| Locking is one-way and permissionless | `test_lockIsOneWay`, `test_lockIsPermissionless` |
| Failed auction, non-graduation path | `test_nonGraduationAndRelaunch` |
| Partial auction that does not graduate | `test_partialAuctionDoesNotGraduate` |
| Relaunch only after failure and 48 hours | `test_nonGraduationAndRelaunch`, `test_markFailedRejectsHealthyLaunch` |
| Unsold handling and dust rounding | `test_settleLocksUnsoldSupply`, `test_settleIsIdempotentGuarded` |
| Migration failure and recovery | `KAY9Recover.t.sol`, five tests |
| The owner cannot touch recovered ETH | `test_ownerCannotTouchRecoveredEth` |
| Reentrancy: a hostile token cannot double-release a tranche, open two periods, withdraw twice, or mint quota | `KAY9Reentrancy.t.sol::test_vestingResistsReentrantToken`, `test_lockCannotBeReenteredToOpenASecondPeriod`, `test_unlockCannotBeReenteredToWithdrawTwice`, `test_quotaCannotBeSpentWhileUnlocking`, `test_reenteringALockCannotCreateExtraQuota` |
| Hostile ERC721 rejected by the lock | `test_lockRejectsHostileNft` |
| The lock takes exactly the stored requirement | `KAY9AccessVault.t.sol::test_lockTakesExactlyTheQuotedRequirement`, `test_forensicLockTakesTheForensicRequirement`, `test_lockRefusesARequirementAboveTheMaximum` |
| The requirement is frozen for the period | `test_theRequirementIsFrozenForThePeriod`, `test_aFallingRequirementDoesNotRefundMidPeriod` |
| `setRequirement` is bounded, owner-only, and forensic never drops below deep | `test_setRequirementIsBoundedAndForensicNeverBelowDeep`, `test_setRequirementIsOwnerOnly` |
| A requirement change never touches a live period and `unlock` returns exactly what was locked | `test_aRequirementChangeNeverTouchesALivePeriodAndUnlockReturnsExactly` |
| Renewal settles the difference against the current requirement in both directions | `test_renewTopsUpWhenTheRequirementRose`, `test_renewReturnsTheDifferenceWhenTheRequirementFell` |
| No path sends a principal anywhere but home | `test_noPathSendsAPrincipalAnywhereButHome` |
| Using the whole allowance still returns the whole principal | `test_usingEveryAuditStillReturnsTheWholePrincipal` |
| A donation is never paid out as yield | `test_aDonationIsNeverPaidOutAsYield` |
| The vault always holds what it owes | `test_vaultBalanceAlwaysEqualsTotalLockedAndNobodyGainsTokens`, `Kay9Invariants.t.sol::invariant_vaultIsAlwaysSolvent` |
| Renewal before expiry is refused, so quota cannot be farmed | `test_renewRevertsBeforeExpiry` |
| Renewal settles the difference in both directions and resets quota | `test_renewTopsUpWhenTheRequirementRose`, `test_renewReturnsTheDifferenceWhenTheRequirementFell`, `test_renewResetsQuotaAndExtendsThePeriod` |
| Upgrading preserves `deepUsed` and the expiry | `test_upgradePreservesDeepUsedAndKeepsTheExpiry`, `test_upgradeOnlyAppliesToALiveDeepPeriod` |
| Period boundaries are exact, and a live period is not moved by governance | `test_periodBoundariesAreExact`, `test_changingTheDurationDoesNotMoveALivePeriod` |
| Only the hub can move quota | `test_onlyTheHubCanMoveQuota` |
| Quota used never exceeds quota granted | `Kay9Invariants.t.sol::invariant_quotaUsedNeverExceedsQuotaGranted` |
| A restore into a period that has since been replaced is a no-op | **not yet covered**; `restore`'s `periodStartedAt` argument and the hub's `accessPeriodStartedAt` are the mechanism |
| A request spends a quota unit and nothing else | `KAY9AuditHub.t.sol::test_requestSpendsQuotaAndNothingElse` |
| The hub never holds KAY9 | `Kay9Invariants.t.sol::invariant_hubHoldsNoKay9` |
| A request without access, without quota, or at the wrong tier is refused | `test_requestWithoutAccessReverts`, `test_requestWithNoQuotaLeftReverts`, `test_requestWithTheWrongTierReverts`, `test_requestAtExpiryIsRefused` |
| Two agreeing signatures finalise, in one transaction or two | `test_twoAgreeingSignaturesFinaliseInOneTransaction`, `test_twoSeparateAttestationsFinalise` |
| One signature does not finalise, and one dissenter does not block | `test_oneSignatureDoesNotFinalise`, `test_oneDissenterDoesNotBlockAQuorum` |
| Three mutually different results dispute the job | `test_threeDifferentResultsDisputeTheJob` |
| An auditor cannot attest twice, in either shape | `test_anAuditorCannotAttestTwice`, `test_theSameAuditorTwiceInOneCallIsRefused` |
| A non-auditor or removed auditor signature is refused | `test_aNonAuditorSignatureIsRefused`, `test_aRemovedAuditorCannotAttest` |
| Replay across jobs, chains and deployments rejected | `test_noReplayAcrossJobs`, `test_noReplayAcrossChains`, `test_noReplayAcrossDeployments` |
| A result must describe the job's asset | `test_aResultMustDescribeTheJobsAsset` |
| A job reaches exactly one outcome | `test_aDisputedJobCannotThenBeFinalised`, `test_aFulfilledJobCannotBeDisputedOrExpired`, `test_anExpiredJobCannotBeFulfilled`, `invariant_jobsHaveExactlyOneOutcome` |
| Expiry is refused early and restores quota afterwards | `test_markExpiredRevertsBeforeTheSlaAndRestoresQuotaAfterIt` |
| Watchdog reports need a sorted quorum and cannot be replayed | `test_watchdogReportNeedsSortedQuorumSignatures`, `test_watchdogReportCannotBeCommittedTwice`, `AuditHubReplay.t.sol::test_watchdogReportCannotBeReplayed`, `test_unsolicitedReportUsesJobIdZero` |
| Who requested an audit changes nothing but metadata | `test_creatorAndIndependentRequestsAreIdenticalExceptForMetadata`, `test_declaredRequesterKindIsRecordedVerbatim` |
| Pausing blocks new requests but not attestation, dispute or expiry | `test_pauseOnlyBlocksNewRequests` |
| Registry is append-only and hub-gated | `KAY9Registry.t.sol::test_recordsAreOnlyEverAppended`, `test_onlyTheHubCanAppend`, `test_reportHistoryIsNeverOverwritten`, `invariant_registryIsAppendOnly` |
| A report record keeps every field, including the commitment point | `test_recordStoresEveryFieldIncludingCommitmentPoint`, `test_reportHashIsStoredVerbatim` |
| An unaudited asset reads as none rather than reverting | `test_latestOfAnUnauditedAssetReportsNoneRatherThanReverting`, `test_latestSummaryOfAnUnauditedAssetIsEmpty` |
| The integrator reads agree with the full records | `test_latestReadsAgreeWithEachOther`, `test_latestSummaryForTokenMatchesLatestSummary`, `testFuzz_scoreHistoryAgreesWithHistory`, `testFuzz_getReportsAgreesWithGetReport` |
| Paging clamps rather than reverts, on any window | `testFuzz_pagingNeverRevertsOnAnyWindow`, `test_unboundedLimitSaturatesToTheEndOfTheLog` |
| Governance is timelocked and bounded | `test_governanceIsTimelocked`, `test_governanceIsTimelockedAndBounded`, `test_auditorRegistryRules` |
| Direct contract calls with no UI | every test drives the contracts directly; the fork suite in particular uses only contract calls |
| The launch script derives parameters the vault accepts | `LaunchScript.t.sol`, five tests including a fuzz over every allowed duration |
| The canonical address book is correct | `Scripts.t.sol::test_mainnetAddressBook`, `test_testnetAddressBook` |
| The vesting helper produces the right calendar dates | `Scripts.t.sol::test_computeVestingSchedule` |
| The invariant handler really reaches every state, including disputed and expired | `Kay9Invariants.t.sol::test_handlerReachesEveryState` |
| The official pool key cannot be squatted, even by the owner | `test/review/GenesisLaunchGrief.t.sol::test_officialPoolKeyCannotBeSquatted` |
| A lookalike hookless pool is irrelevant to launch, migration and settlement | `test_hooklessPoolIsIrrelevantToTheLaunch` |
| The vault rejects a hook that is not a canonical InitializerHook for its strategy | `test_constructorRejectsBadHooks` |
| `poolKey()` is the official key before migration | `test/review/GenesisPoolResolution.t.sol::test_poolKeyIsTheOfficialKeyBeforeMigration` |
| Recovery refuses a squatted recovery pool priced by a stranger | `test_recoveryRefusesASquattedPoolPrice` |
| Recovery accepts a squatted recovery pool already at the clearing price | `test_recoveryAcceptsASquattedPoolAtTheClearingPrice` |
| The deployed InitializerHook gates the real pool on mainnet | `test/fork/RobinhoodFork.t.sol::test_fork_fullLaunchCycle` |
| A watchdog report cannot be replayed into the log | `test/review/AuditHubReplay.t.sol::test_watchdogReportCannotBeReplayed` |
| Full launch on real mainnet code | `test/fork/RobinhoodFork.t.sol::test_fork_fullLaunchCycle` |
| Non-graduation on real mainnet code | `test_fork_nonGraduation` |
| Migration failure and recovery on real mainnet code | `test_fork_recoverAfterFailedMigration` |

### Notes on the local test environment

The offline suite deploys the genuine Uniswap v4 core and periphery, the genuine liquidity launcher,
LBP strategy and continuous clearing auction, the genuine FeeSplitter and beneficiary vault, and the
genuine Permit2, rather than mocks. Nothing in the access path needs a stand-in, because nothing in
it reads a price feed.

The static analysis results in §5 were produced against the previous contracts and must be re-run
before launch: `KAY9AccessVault` did not exist when they were taken, and `KAY9AuditHub` no longer
contains the payment arithmetic several of the dispositions refer to.

---

## 5. Static analysis

Command:

```bash
slither . --config-file slither.config.json
```

The configuration excludes `lib/`, `test/` and `script/`, so only the eight KAY9 contracts and their
libraries are analysed.

`crytic-compile` 0.4.2 cannot read the `out/build-info` layout that Foundry 1.8.1 writes, so
slither's Foundry auto-detection fails before it reaches any detector. Forcing the plain solc
platform works:

```bash
solc-select install 0.8.26 && solc-select use 0.8.26
slither src/KAY9Genesis.sol  --compile-force-framework solc --solc <path to solc-0.8.26> --config-file slither.solc.json
slither src/KAY9AuditHub.sol --compile-force-framework solc --solc <path to solc-0.8.26> --config-file slither.solc.json
```

Those two entry points reach every source file in `src/`.

**Result (2026-09-11, all ten contracts as their own entry points): 68 distinct findings in 11
detector classes, none of them a defect.** One is reported High by slither 0.11.6 (`weak-prng`) and
is a false positive on a rounding modulo. The full list with a disposition for each is in
[`../packages/contracts/SLITHER.md`](../SLITHER.md). Summary:

| Severity | Detector | Count | Disposition |
|---|---|---|---|
| High | `weak-prng` | 1 | False positive: a modulo used to round the mean tick toward negative infinity |
| Medium | `reentrancy-no-eth` | 3 | Not exploitable: `nonReentrant`, status set before the call, immutable callees |
| Medium | `incorrect-equality` | 8 | False positives: comparisons against zero, the current block, or a Merkle root |
| Medium | `divide-before-multiply` | 4 | Intentional snap-to-spacing arithmetic, identical to v4-core's |
| Medium | `uninitialized-local` | 4 | False positives: accumulators that start at the zero default |
| Medium | `unused-return` | 9 | Intentional tuple destructuring of `getSlot0`, `initialize`, `multicall` and `latestRoundData` |
| Low | `reentrancy-benign` | 4 | Bookkeeping after guarded calls |
| Low | `reentrancy-events` | 2 | Event ordering only |
| Low | `calls-loop` | 9 | Loops bounded by the auditor set or the position list |
| Low | `timestamp` | 21 | Intentional: vesting, cooldowns, periods, service levels |
| Informational | `unindexed-event-address` | 3 | Event shapes are fixed by `CONTRACT_INTERFACES.md` |

What static analysis cannot see, and a rehearsal did: `block.number` on this Orbit chain is the
parent chain's height while the auction reads `ArbSys.arbBlockNumber()`. `docs/RESEARCH.md` has
the measurement and the testnet launch that exposed it.

Nothing was reported by the detectors that would actually matter here: `arbitrary-send-eth`,
`arbitrary-send-erc20`, `controlled-delegatecall`, `suicidal`, `unprotected-upgrade`,
`unchecked-transfer`, `tx-origin`, `uninitialized-state`, `shadowing-state`, `incorrect-shift`,
`storage-array` and `msg-value-loop` are all clean.

## 6. Known risks

**The official pool key cannot be squatted.** The migration target is
`(ETH, KAY9, fee 10000, tickSpacing 200, InitializerHook)`, keyed on Uniswap's canonical
`0xD462a559337859369EF271814851A18F496ba000`, whose `authorized()` is the LBP strategy. Uniswap v4
calls `beforeInitialize` on that hook for every `PoolManager.initialize`, and the hook reverts for
every caller but the strategy, so the strategy's own migration is the only transaction in existence
that can create the pool. That closes two things at once. Nobody can pre-initialize the key to make
`MigratorParams.validateHook` reject the distribution and brick `launch()` forever — with a hookless
key that was a one-transaction, unrecoverable grief against the whole 910,000,000 allocation. And an
initialized pool is now proof that the migration ran, so `poolKey()` resolves to exactly one pool
with no hookless/fallback ambiguity and no decoy a stranger can plant. The hook holds the
`beforeInitialize` permission bit and no other, takes no hook data, and has no swap, liquidity or
donate logic; `KAY9Genesis` re-checks all of that in its constructor (live code, ERC-165
`IInitializerHook`, `authorized() == lbpStrategy`, address flags exactly `beforeInitialize`,
`Hooks.isValidHookAddress` for the static 1 % fee). `test/review/GenesisLaunchGrief.t.sol` pins it,
and the fork suite proves the deployed hook behaves this way on mainnet.

**Recovery has to leave the hook behind, and prices itself off the auction.** A migration that
reverted never reached `PoolManager.initialize`, and the vault is not the strategy, so it cannot
create the hooked pool. `recover()` therefore rebuilds into the hookless pool with the same pair, fee
and spacing, and `poolKey()` reports that pool from then on (`recovered()` says which). Anyone can
initialize that hookless key, so `recover()` refuses to run unless the pool is either uninitialized
or already sitting at exactly the auction's final clearing price: minting the whole raise as a
full-range position at a price a stranger chose would be a drain, and failing closed is not. A
squatted key is not a permanent block either — an empty pool's price moves to any target for the cost
of a swap that fills nothing, after which recovery proceeds. `recover()` also sweeps the auction's
unsold supply before it settles the remainder: only this contract may sweep it, and after recovery
nothing else would. Severity: low, fails closed.

**Settlement is permissionless and anchors no cheaper than the clearing price.** `settle()` places
the leftover supply as one single-sided range whose upper edge sits one tick spacing below the lower
of the pool's current tick and the auction's final clearing tick: a KAY9 price no cheaper than the
market and no cheaper than what every bidder paid. An earlier revision anchored at spot alone, on the
reasoning that the range's depth near the current price was thin. It is not. A currency1-only range
holds its tokens in proportion to √P, so the ticks nearest the anchor hold the most, and the share of
the leftover sold within a price ratio k of the anchor is 1 − 1/√k whatever the lower edge is.
Anyone holding KAY9 could push the price down, call `settle()` and buy a large part of the leftover
back below the clearing price in the same transaction, paying only the two 1 % fees. With the
clearing price as a floor, pushing the price down first gains nothing, and pushing it up only makes
the leftover dearer for everybody, the manipulator included. `test_settleIgnoresPushedDownPrice`
pins it. Severity: was medium, fixed.

**Frozen ETH dust in the genesis vault.** After a successful migration the LBP strategy forwards its
leftover ETH dust, on the order of 10⁻⁵ ETH, to the vault. The vault has no withdrawal path, so that
dust stays there forever. Adding a sweep would mean adding an owner-callable ETH transfer, which is
a far worse trade than losing a rounding remainder. Severity: negligible, accepted.

**Relaunch requires an explicit failure marker.** The chain does not record the timestamp at which a
failure became observable, so the 48-hour relaunch cooldown starts when someone calls the
permissionless `markFailed()`. If nobody calls it, the cooldown never starts and the owner cannot
relaunch. This delays a relaunch; it can never accelerate one. `markFailed()` accepts a
non-graduated auction only once the auction has checkpointed its end block: before that checkpoint
`isGraduated` still reports an earlier figure, and the final block releases the largest slice of
supply, so a launch that is about to graduate would otherwise read as failed. Anyone can call the
auction's `checkpoint()`. Severity: low, accepted.

**A relaunch reuses the same pool key.** After a non-graduated auction no pool was ever initialized,
so a relaunch can reserve the same key. The relaunch itself calls `migrate()` on the dead auction
when nobody has, which releases the strategy's pool-id reservation and returns the LP reserve inside
the same transaction; before the auction's migration block that call reverts, and so does the
relaunch. After a
`recover()`, the hookless recovery pool exists but the hooked official key does not, so a relaunch
would reserve it again. In practice a recovery is terminal: the liquidity is
already locked and there is nothing left to relaunch. Severity: informational.

**KAY9 held outside the launch before the official pool exists.** The InitializerHook stops anybody
but the LBP strategy from initializing the official pool, but the strategy initializes it for any
registered distribution of KAY9, not only this vault's. While no auction of ours holds the key's
registration (before the first `launch`, during a relaunch cooldown, after a failed migration),
anybody holding KAY9 can run a small distribution of their own through the launcher and bring the
official pool into being at a price they chose. Before that pool exists, the only KAY9 outside the
launch pipeline is the team's TGE tranche, so `TGE_TIMESTAMP` is set no earlier than the planned
migration and the team moves nothing before the pool exists (`docs/DEPLOYMENT.md`). Two checks make
the contract fail closed if that rule is broken. `launch` refuses while the official pool exists
(`OfficialPoolExists`), so no bidder's ETH enters an auction whose migration could only fail. A
launch whose auction did not graduate never reads as migrated, whatever happens to the official
pool, so `settle` cannot place the supply into a stranger's pool. `test/review/GenesisLaunchGrief.t.sol`
pins both. One case remains: after a graduated auction whose migration failed, bidders hold KAY9,
and one who creates the official pool before anybody calls `recover()` makes the vault read the
launch as migrated, which blocks recovery and leaves the raise frozen in the vault. A migration
failure is not expected with a static-fee pool and a standard token, and `recover()` is
permissionless, so the operational answer is to call it in the block the failure is seen.
Severity: medium, fails closed except for that residual case.

**Owner pricing discretion.** The owner can choose a floor or graduation valuation that the market
considers absurd. The contract cannot judge that; the website shows the implied numbers from
`LaunchConfigured` before the auction starts, and bidders decide. Severity: accepted by design.

**The lock requirement can go stale.** The requirement is a fixed number of KAY9, so a large move
in the token's price changes the dollar value of a lock until the owner adjusts the number through
the timelock. A requirement that has become very cheap weakens the allowance as a cost bound; one
that has become very expensive shuts people out. Neither touches principal or a live period, and
every adjustment is public for 48 hours before it applies. The contract bounds the number to
1 KAY9 – 10,000,000 KAY9 with forensic never below deep, so a mistaken change cannot make a lock
free or take more than 1 % of supply. Severity: low, accepted in exchange for having no oracle and
no off-chain process to keep alive in the access path.

**The launch auditor set is not three independent operators.** Two of the three auditor identities
run inside accounts the project owner controls, so the two-of-three quorum protects against one
dishonest auditor and not against a compromise of the owner's own accounts. §2.6 states this in
full, including what it does and does not make possible. Severity: real, disclosed, and mitigated by
migration rather than by a mechanism.

**Governance can change what a period locks and allows, but only ahead of time.** The timelock can
raise a lock requirement or cut an allowance. Every such change is public for 48 hours before it can
execute, and none of it reaches a live period, because the requirement, the allowances and the
expiry are all copied into the access record when the period opens. The residual power is over
periods that have not started yet. Severity: accepted by design.

**Single-block clearing-price influence.** The continuous clearing auction concentrates about 30 %
of the supply in the final block precisely to make the closing price expensive to manipulate, but a
sufficiently large actor can still influence where a four-hour auction ends. This is a property of
the Uniswap auction design, not of KAY9. Severity: inherited, documented.

**Third-party dependency risk.** A bug in the canonical liquidity launcher, LBP strategy, auction
factory, FeeSplitter or Uniswap v4 would affect KAY9. The recovery path exists precisely because
migration is the step where that risk concentrates: if the strategy's migration reverts for any
reason, the vault rebuilds the pool itself. Severity: inherited, mitigated.

**Permit2 pragma relaxation for local tests only.** `lib/permit2/src/*.sol` had its pragma changed
from `0.8.17` to `^0.8.17` so the project compiles under one pinned solc. The locally compiled
Permit2 is used only by the offline tests; the fork tests and every deployment use the canonical
deployed Permit2 at `0x000000000022D473030F116dDEE9F6B43aC78BA3`. Severity: none in production, but
it means local Permit2 bytecode differs from mainnet.

---

## 7. Reporting a vulnerability

Email **security@kay9.io** with a description, an impact assessment and, if you have one, a
reproduction. Please do not open a public issue for anything that could move funds or lock
liquidity. We will acknowledge within 72 hours.

There is no bug bounty programme at launch. If one is established it will be announced on-chain and
documented here.
