# KAY9 Contract Interfaces (binding spec)

This file is the contract between the Solidity implementation, the website, and the services. The website and services build their ABIs from these signatures (`viem.parseAbi`) until generated ABIs replace them; the Solidity implementation must match them exactly (names, order, types, event indexing). If a change is needed, change this file first.

All contracts: Solidity `^0.8.26`, OpenZeppelin v5, `pragma abicoder v2` default. Amounts are 18-decimal KAY9 wei unless stated. Trust scores are `uint8` 0 (worst) … 100 (most trustworthy).

---

## KAY9Token

```solidity
contract KAY9Token is ERC20, ERC20Permit, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    constructor(address genesis);            // mints TOTAL_SUPPLY to genesis, name "KAY9", symbol "KAY9"
    // no other functions beyond standard ERC20 / ERC2612 permit / burn(uint256) / burnFrom(address,uint256)
}
```

## KAY9TeamVesting

```solidity
contract KAY9TeamVesting {
    event Released(address indexed beneficiary, uint256 amount, uint256 totalReleased);
    event BeneficiaryTransferred(address indexed previousBeneficiary, address indexed newBeneficiary);
    event BeneficiaryTransferProposed(address indexed beneficiary, address indexed proposed);

    IERC20  public immutable token;
    uint256 public constant TOTAL_ALLOCATION = 90_000_000e18;
    uint256 public constant TRANCHE_1 = 10_000_000e18;   // TGE
    uint256 public constant TRANCHE_2 = 40_000_000e18;   // +6 calendar months
    uint256 public constant TRANCHE_3 = 40_000_000e18;   // +12 calendar months
    uint64  public immutable tgeTimestamp;
    uint64  public immutable unlock6mTimestamp;
    uint64  public immutable unlock12mTimestamp;
    ILaunchSettlement public immutable launch;   // KAY9Genesis; only `settled()` is read
    address public beneficiary;
    address public pendingBeneficiary;
    uint256 public released;

    constructor(IERC20 token, address beneficiary, ILaunchSettlement launch, uint64 tge, uint64 unlock6m, uint64 unlock12m);
    function unlocked() external view returns (uint256);       // what the calendar has unlocked at block.timestamp
    function releasable() external view returns (uint256);     // 0 until launch.settled(); then unlocked() - released
    function release() external;                               // permissionless, sends releasable() to beneficiary; reverts LaunchNotSettled before the launch settles
    function transferBeneficiary(address newBeneficiary) external;  // only beneficiary; names a successor (zero withdraws), changes nothing yet
    function acceptBeneficiary() external;                          // only the named successor; this is what moves the role
    function schedule() external view returns (uint64[3] memory timestamps, uint256[3] memory amounts);

    error LaunchNotSettled();
    error NotPendingBeneficiary();
}
```

**The calendar is fixed at deployment, and the launch is not.** The three timestamps are burned in
when the contracts are deployed, days before `launch()` is signed, and a launch can slip, or fail
and be run again. On the calendar alone that would hand the team liquid KAY9 before the public had
been able to buy any. So `release` reverts `LaunchNotSettled` until `KAY9Genesis.settled()` is true,
which is the moment the launch's liquidity is placed and locked and no relaunch is possible. The
gate can only delay: once the launch is settled the schedule is the calendar and nothing else, to
the second, and `unlocked()` always reports the calendar alone. `settled()` is a stored flag set by
the permissionless `settle` and `recover`, so nobody's cooperation is needed to open it and no read
of an external contract can keep it shut.

**The beneficiary role moves in two steps.** `transferBeneficiary` names a successor and changes
nothing; the role moves when that address calls `acceptBeneficiary`. The role is worth the whole
allocation, so an address nobody holds the key to can be named by mistake and costs nothing.

## KAY9Genesis (launch vault)

```solidity
struct LaunchParams {
    uint64  startBlock;
    uint64  endBlock;
    uint64  claimBlock;
    uint64  migrationBlock;
    uint256 floorPriceQ96;
    uint256 auctionTickSpacingQ96;
    uint128 requiredCurrencyRaised;
    bytes   auctionStepsData;
    bytes32 salt;
}

contract KAY9Genesis is Ownable2Step {
    event Deployed(address indexed token, address indexed teamVesting, address indexed liquidityLock);
    event LaunchConfigured(uint256 indexed launchIndex, address indexed auction, LaunchParams params, uint256 impliedFloorFdvWei, uint256 impliedGraduationRaiseWei);
    event Launched(uint256 indexed launchIndex, address indexed auction, uint64 startBlock, uint64 endBlock);
    event RelaunchScheduled(uint256 earliestRelaunchTimestamp);
    event UnsoldSettled(uint256 amountToLiquidity, uint256 amountBurned, uint256 positionTokenId);
    event Recovered(uint256 ethAmount, uint256 tokenAmount, uint256 positionTokenId);
    event LeftoverEthPlaced(uint256 ethAmount, uint256 positionTokenId); // settle(): ETH a good migration left in the vault, single-sided and locked
    event MigrationOutcomeRecorded(bool succeeded);

    // immutables
    KAY9Token         public immutable token;
    KAY9TeamVesting   public immutable teamVesting;
    KAY9LiquidityLock public immutable liquidityLock;
    ILiquidityLauncher public immutable launcher;        // 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0
    ILBPStrategy      public immutable lbpStrategy;      // 0x05d552391067389EE44fec3924157ed33F976000
    IPositionManager  public immutable positionManager;
    IPoolManager      public immutable poolManager;
    IAllowanceTransfer public immutable permit2;

    uint256 public constant LAUNCH_ALLOCATION   = 910_000_000e18;
    uint256 public constant AUCTION_ALLOCATION  = 455_000_000e18;
    uint256 public constant LIQUIDITY_RESERVE   = 455_000_000e18;
    uint24  public constant POOL_FEE            = 10_000;   // 1 %
    int24   public constant POOL_TICK_SPACING   = 200;
    uint64  public constant MIN_DURATION_BLOCKS = 36_000;   // ~1 h at 0.1 s, on the auction's clock (ArbSys)
    uint64  public constant MAX_DURATION_BLOCKS = 864_000;  // ~24 h; also the furthest claimBlock and migrationBlock may sit after endBlock
    uint64  public constant MAX_START_DELAY_BLOCKS = 25_920_000; // ~30 days: the furthest ahead startBlock may be
    uint256 public constant MAX_STEP_MPS        = 4e6;      // no emission step releases more than 40 % of the supply per block
    function chainBlockNumber() external view returns (uint256);  // the clock launch windows are validated on: ArbSys.arbBlockNumber() here, block.number elsewhere
    uint256 public constant DUST_THRESHOLD      = 1_000e18;
    uint256 public constant RELAUNCH_DELAY      = 48 hours;

    address public auction;              // current CCA (ILBPInitializer) or 0
    uint256 public launchCount;
    uint256 public earliestRelaunchTimestamp;
    bool    public settled;

    constructor(address owner, address teamBeneficiary, uint64 tge, uint64 unlock6m, uint64 unlock12m,
                address creatorFeeRecipient, address launcher, address lbpStrategy, address positionManager,
                address poolManager, address permit2, address feeSplitter, address beneficiaryVault,
                address poolHook);

    function launch(LaunchParams calldata p) external;   // onlyOwner; first launch or after failure + delay
    function launchState() external view returns (uint8);  // 0 NotLaunched, 1 AuctionLive (also between launch and startBlock), 2 AuctionEnded, 3 Migrated, 4 Failed (for a non-graduated auction, only once the auction has checkpointed its end block)
    function poolKey() external view returns (PoolKey memory);  // (ETH, KAY9, 10000, 200, poolHook); the hookless recovery pool after recover()
    function poolHook() external view returns (address);        // canonical InitializerHook, immutable
    function recovered() external view returns (bool);          // true once recover() rebuilt the pool
    function outcomeRecorded() external view returns (bool);    // true once settle() or recover() wrote the migration outcome down
    function migrationSucceeded() external view returns (bool); // the recorded outcome: this launch's own migration built the official pool
    function settle() external;                           // permissionless after migration: unsold+leftover → single-sided LP or burn
    function migrateAndSettle() external;                 // permissionless: LBPStrategy.migrate, lock the positions it minted, settle — one tx; the entry the site uses
    function recover() external;                          // permissionless if graduated but migration failed
    function previewLaunch(LaunchParams calldata p) external view returns (address predictedAuction, uint256 impliedFloorFdvWei, uint256 impliedGraduationRaiseWei);
}
```

## KAY9LiquidityLock

```solidity
contract KAY9LiquidityLock is IERC721Receiver {
    event PositionLocked(uint256 indexed tokenId, address indexed beneficiary, address feeSplitter);

    IPositionManager  public immutable positionManager;
    address           public immutable feeSplitter;        // 0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf
    IBeneficiaryVault public immutable beneficiaryVault;   // 0xd35E9CA72F64C7F93BE30fad67524323396B36D7
    address           public immutable creatorFeeRecipient;

    uint256[] public lockedTokenIds;
    function lockedCount() external view returns (uint256);
    function lock(uint256 tokenId) external;               // permissionless: register beneficiary then transfer to FeeSplitter
    function lockAll() external;                           // locks every position this contract currently owns (tracked via onERC721Received or pushed ids)
    function isLocked(uint256 tokenId) external view returns (bool);
}
```

## KAY9AuditorRegistry

```solidity
contract KAY9AuditorRegistry is Ownable2Step {
    event AuditorAdded(address indexed auditor);
    event AuditorRemoved(address indexed auditor);
    event ThresholdUpdated(uint8 threshold);

    function isAuditor(address) external view returns (bool);
    function auditors() external view returns (address[] memory);
    function auditorCount() external view returns (uint256);
    function threshold() external view returns (uint8);
    function addAuditor(address auditor) external;     // onlyOwner (Timelock)
    function removeAuditor(address auditor) external;  // onlyOwner; halts (threshold 0) if fewer auditors than the threshold remain
    function setThreshold(uint8 threshold) external;   // onlyOwner
    function isHalted() external view returns (bool);  // threshold == 0
    uint256 public constant MAX_AUDITORS = 32;
    function renounceOwnership() external;             // always reverts RenounceDisabled
}
```

A removal that would leave fewer auditors than the threshold **halts** the registry rather than
lowering the threshold: nothing is attested or published until the owner names a new quorum with
`setThreshold`. Lowering it automatically let two removals out of three leave one key able to
publish alone (watchdog review, 2026-09-25). The threshold is therefore either zero, meaning halted,
or within [1, auditor count].

## KAY9AccessVault

Access to the deep and forensic tiers is a **lock**, never a payment. The vault holds the
depositor's KAY9 for one access period and returns all of it afterwards. It has no owner
withdrawal path, no reward path, no burn, and no slashing: the only way KAY9 leaves the vault is
`unlock` or `renew` returning it to the address that deposited it.

```solidity
struct Access {
    uint8   tier;             // 0 none, 1 deep, 2 forensic
    uint64  startedAt;        // period start; identifies the period
    uint64  expiresAt;        // startedAt + lockDuration
    uint32  deepQuota;        // frozen at lock time
    uint32  forensicQuota;    // frozen at lock time
    uint32  deepUsed;
    uint32  forensicUsed;
    uint256 lockedKay9;       // principal, the depositor's property; the requirement the period opened with
}

contract KAY9AccessVault is Ownable2Step, ReentrancyGuard {
    event AccessLocked(address indexed account, uint8 tier, uint256 lockedKay9, uint64 startedAt, uint64 expiresAt, uint32 deepQuota, uint32 forensicQuota);
    event AccessRenewed(address indexed account, uint8 tier, uint256 lockedKay9, uint256 toppedUp, uint256 returned, uint64 startedAt, uint64 expiresAt);
    event AccessUpgraded(address indexed account, uint256 lockedKay9, uint256 toppedUp, uint32 forensicQuota);
    event AccessUnlocked(address indexed account, uint256 returnedKay9);
    event QuotaConsumed(address indexed account, uint8 tier, uint32 deepUsed, uint32 forensicUsed);
    event QuotaRestored(address indexed account, uint8 tier, uint32 deepUsed, uint32 forensicUsed);
    event QuotaConfigured(uint8 indexed tier, uint32 deepQuota, uint32 forensicQuota);
    event RequirementConfigured(uint8 indexed tier, uint256 kay9);
    event LockDurationUpdated(uint64 seconds_);
    event AuditHubUpdated(address auditHub);

    uint8  public constant TIER_DEEP     = 1;
    uint8  public constant TIER_FORENSIC = 2;
    uint64 public constant MIN_LOCK_DURATION = 7 days;
    uint64 public constant MAX_LOCK_DURATION = 365 days;
    uint32 public constant MAX_QUOTA = 1000;
    uint256 public constant MIN_REQUIREMENT = 1e18;                // one KAY9
    uint256 public constant MAX_REQUIREMENT = 10_000_000e18;       // 1 % of supply

    constructor(address owner_, IERC20 kay9_);                     // sets requirementOf[1] = 5_000e18, requirementOf[2] = 10_000e18

    IERC20 public immutable kay9;

    address public auditHub;
    uint64  public lockDuration;                                   // default 30 days
    mapping(uint8 tier => uint256) public requirementOf;           // KAY9 wei a tier locks; deep 5,000 KAY9, forensic 10,000 KAY9
    function deepQuotaOf(uint8 tier) external view returns (uint32);      // deep: 4, forensic: 4
    function forensicQuotaOf(uint8 tier) external view returns (uint32);  // deep: 0, forensic: 1
    uint256 public totalLocked;                                    // sum of every principal held

    function lock(uint8 tier, uint256 maxKay9) external;           // requires no live period; takes exactly requirementOf[tier]
    function lockWithPermit(uint8 tier, uint256 maxKay9, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function renew(uint8 tier, uint256 maxKay9) external;          // only at or after expiresAt; reads the current requirementOf[tier], tops up or returns the difference, resets quota
    function upgrade(uint256 maxKay9) external;                    // deep to forensic inside a live period; tops up to the current requirementOf[2] and never returns principal; deepUsed is preserved
    function unlock() external;                                    // only at or after expiresAt; returns the whole principal

    function accessOf(address account) external view returns (Access memory);
    function isActive(address account) external view returns (bool);
    function deepRemaining(address account) external view returns (uint32);
    function forensicRemaining(address account) external view returns (uint32);
    function canRequest(address account, uint8 tier) external view returns (bool);

    function consume(address account, uint8 tier) external returns (uint64 periodStartedAt);  // only auditHub
    function restore(address account, uint8 tier, uint64 periodStartedAt) external;           // only auditHub or a retired hub; no-op unless the period still matches
    function isRetiredHub(address hub) external view returns (bool);                          // a hub `setAuditHub` replaced; may still restore, never consume

    function setAuditHub(address auditHub_) external;              // onlyOwner (Timelock); the previous hub becomes a retired hub
    function setQuota(uint8 tier, uint32 deepQuota, uint32 forensicQuota) external;  // onlyOwner (Timelock)
    function setLockDuration(uint64 seconds_) external;            // onlyOwner (Timelock), within [MIN, MAX]
    function setRequirement(uint8 tier, uint256 kay9) external;    // onlyOwner (Timelock); valid tier, within [MIN_REQUIREMENT, MAX_REQUIREMENT], and requirementOf[2] >= requirementOf[1] afterwards; never touches a live period

    error ZeroAddress();
    error InvalidTier(uint8 tier);
    error AccessLive(uint64 expiresAt);
    error AccessRecordExists(uint64 expiresAt);
    error NoAccess();
    error NotExpired(uint64 expiresAt);
    error NotTheAuditHub(address caller);
    error RequirementAboveMax(uint256 required, uint256 maxKay9);
    error QuotaExhausted(uint8 tier);
    error TierNotPermitted(uint8 have, uint8 want);
    error NotAnUpgrade(uint8 tier);
    error InvalidLockDuration();
    error InvalidQuota();
    error InvalidRequirement();
}
```

Rules that the tests pin and that the rest of the system may rely on:

- **A period never opens on a zero requirement.** `setRequirement` refuses anything below
  `MIN_REQUIREMENT` (one KAY9) or above `MAX_REQUIREMENT` (10,000,000 KAY9), and refuses to leave
  the forensic requirement below the deep one, with `InvalidRequirement`. A record with
  `lockedKay9 == 0` is what the vault uses to mean "no record", so a zero requirement cannot be
  configured at all.
- **The requirement is a stored number, not a quote.** There is no price oracle in the vault: no
  TWAP, no ETH/USD feed, nothing that has to be kept alive. `requirementOf(tier)` is what the site and every
  integration reads; it is never hardcoded anywhere off chain.
- **A retired hub can still give quota back.** `setAuditHub` marks the hub it replaces as retired.
  A retired hub may call `restore` and nothing else, so a job that was pending on the old hub when
  governance moved to a new one can still expire or dispute and return its unit to the period that
  paid for it. `consume` stays with the current hub alone.

- **The requirement is frozen for the period.** `lock` copies `requirementOf[tier]` into
  `lockedKay9` and the record is never revisited. A later `setRequirement` never asks the depositor
  for more, and never shortens or voids a live period. `renew` (after expiry) and `upgrade`
  (mid-period, deep to forensic) are the only places the current requirement is read again.
- **`lock` is only for an account with no record at all.** An account holding an ended period
  calls `renew` or `unlock`; `lock` reverts `AccessRecordExists` rather than misreporting the
  period as unexpired.
- **`renew` is refused before `expiresAt`.** Otherwise a depositor could spend a quota, renew for
  nothing, and spend it again. Renewal at or after expiry needs no unlock-and-relock round trip:
  the vault tops up or returns the difference against the current requirement.
- **`upgrade` preserves `deepUsed`.** Deep quota is identical in both tiers, so upgrading buys the
  forensic slot and nothing else.
- **`upgrade` only ever adds.** It leaves `max(lockedKay9, requirementOf[2])` locked: a top-up when
  the forensic requirement is above what the period holds, and nothing at all when governance has
  since lowered it below that. No principal leaves the vault before `expiresAt`, so a lowered
  requirement takes effect at the next `renew` or after `unlock`, exactly as it does for a period
  that is never upgraded. `maxKay9` is compared with the amount the call leaves locked, and
  `AccessUpgraded.lockedKay9` reports that amount. `deepQuota` likewise becomes
  `max(deepQuota, deepQuotaOf[2])`, so a `setQuota` after the period opened cannot shrink it.
- **Every path out returns principal to the depositor.** `unlock` returns `lockedKay9` in full.
  There is no function, owner-only or otherwise, that sends a depositor's KAY9 anywhere else.
- **`unlock` reads nothing but the record.** It returns exactly `lockedKay9`; no configuration
  change and no external contract can stand between a depositor and their principal.
- **Quota is consumed on the chain, by the hub, not by any website.** `consume` is callable only by
  the configured audit hub and returns the period it debited, so a later `restore` cannot credit a
  different period. `restore` is accepted from the configured hub and from any hub it has replaced.

## KAY9ScanRegistry

The permanent record of **automatic basic scans**. Separate from `KAY9Registry` on purpose: the
two carry different claims, and the product depends on nobody confusing them.

| | `KAY9ScanRegistry` | `KAY9Registry` |
|---|---|---|
| Claim | reproducibility — "this is what the published engine computes" | consensus — "two of three auditors signed the same result" |
| Writer | an authorised scanner | the audit hub only, after quorum |
| Trigger | automatic, on discovery and on re-scan | a request that consumed access quota |
| Cost shape | one transaction per **batch** | one transaction per report |
| Anyone can recompute it | yes, from public chain state at the stated block | no, it depends on the auditors' private analysis |

Batching is in the design from the first day rather than added later. A basic scan is unsolicited,
so the number of them is set by how many tokens launch, not by how many people pay. One
transaction per scan makes the cost of watching a chain scale with that chain's activity, which is
the wrong shape; one transaction per batch makes it scale with time. **A batch of one is a legal
batch**, so a single urgent scan is not a special case anywhere in the code.

```solidity
struct ScanBatch {
    bytes32 root;            // Merkle root over the batch's scan leaves
    uint32  count;           // scans in the batch
    uint32  engineVersion;
    uint64  committedAt;     // block.timestamp
    uint64  committedBlock;  // the chain's own height (ArbSys on this Orbit chain), the number an explorer shows
    address scanner;
    string  uri;             // content-addressed batch document
}

struct ScanSummary {
    bytes32 chainKey;
    bytes32 assetId;
    uint8   overallTrust;
    uint8   confidence;      // separate from the score, never folded into it
    uint64  flags;
    uint64  scannedAtBlock;
}

contract KAY9ScanRegistry {
    event ScanBatchCommitted(uint256 indexed batchId, bytes32 indexed root, uint32 count, uint32 engineVersion, string uri, address indexed scanner);
    event AssetScanned(bytes32 indexed chainKey, bytes32 indexed assetId, uint256 indexed batchId, uint8 overallTrust, uint8 confidence, uint64 flags, uint64 scannedAtBlock);
    event ScannerUpdated(address indexed scanner, bool allowed);

    uint32 public constant MAX_BATCH = 500;          // bounds both count and summaries
    address public immutable guardian;               // may revoke a scanner at once, nothing else
    mapping(address => bool) public isScanner;

    constructor(address owner_, address guardian_, address[] memory initialScanners);  // owner is the timelock from the first block

    function assetKey(bytes32 chainKey, bytes32 assetId) external pure returns (bytes32);   // keccak256(abi.encode(chainKey, assetId))
    function scanLeaf(bytes32 chainKey, bytes32 assetId, uint8 overallTrust, uint8 confidence, uint64 flags, uint32 engineVersion, uint64 scannedAtBlock, bytes32 reportHash) external pure returns (bytes32);
    function commitScanBatch(bytes32 root, uint32 count, uint32 engineVersion, string calldata uri, ScanSummary[] calldata summaries) external returns (uint256 batchId);  // authorised scanner only
    function verifyScan(uint256 batchId, bytes32 leaf, bytes32[] calldata proof) external view returns (bool);
    function batchCount() external view returns (uint256);
    function getBatch(uint256 batchId) external view returns (ScanBatch memory);
    function latestScan(bytes32 chainKey, bytes32 assetId) external view returns (bool scanned, uint256 batchId, uint8 overallTrust);
    function setScanner(address scanner, bool allowed) external;  // onlyOwner
    function revokeScanner(address scanner) external;             // guardian only, no delay
    function renounceOwnership() external;                        // always reverts RenounceDisabled
}
```

**The leaf definition is part of the protocol, not an implementation detail.** A third party
verifying a scan hashes exactly those fields in exactly that order:

```
leaf = keccak256(keccak256(abi.encode(
    chainKey, assetId, overallTrust, confidence, flags, engineVersion, scannedAtBlock, reportHash
)))
```

Double-hashed so a leaf can never be confused with an internal node, which is the standard defence
against a second-preimage attack on a Merkle tree. Internal nodes hash **sorted pairs**, so a proof
carries no left-or-right flags and cannot be replayed against a differently shaped tree.

Notes that a caller has to know:

- **`latestScan` returns `scanned` because an unset `uint8` defaults to 0, the worst possible
  score.** Without it, "never looked at" and "looked at and found the worst possible reading" are
  the same answer.
- **`verifyScan` reverts on an unknown batch rather than returning false.** False would be
  indistinguishable from "not in this batch", and a caller that got the id wrong deserves to be
  told.
- **`latestScan` is an index the scanner supplies, not a value proven against the root.** The
  contract does not check that the summaries are the batch's leaves. It publishes both the root and
  the summaries, so a scanner that publishes summaries its own root does not support is caught by
  the first person who checks, the evidence stays on-chain for good, and the guardian can revoke the
  scanner at once. The newest batch always wins, so the next honest batch that indexes the asset
  replaces a bad value. Proving each summary would put a Merkle proof per indexed scan in calldata,
  which this chain pays for on its parent chain. Scores above 100 are refused.
- **`verifyScan` proves that a hash is in the tree.** Pass a leaf computed with `scanLeaf` from the
  scan's fields. Given the root itself or an internal node it also returns true, and neither says
  anything about a scan; a double-hashed leaf cannot collide with a node.
- **`scannedAtBlock` is the scanner's statement** of the block it read, on the scanned asset's own
  chain. The contract records it and cannot check it. `committedBlock` is the one the contract
  reads itself, from ArbSys.
- **`count` is the batch; `summaries` is the subset indexed on-chain.** Every scan in the batch is
  committed to `root` and provable with `verifyScan`, whether or not it is indexed. Indexing an
  asset costs a cold storage write — measured at about 24,700 gas, against roughly 150,000 for the
  whole batch however large — so on a chain producing tens of thousands of launches a day,
  indexing everything would cost thousands of dollars a month and indexing what people have
  actually bought costs tens. A batch that claims to hold fewer scans than it indexes is refused
  with `CountTooSmall`, and one that claims more than `MAX_BATCH` with `BatchTooLarge`.
- **A scanner can only ever append.** There is no function, owner-only or otherwise, that alters or
  removes a committed batch. Removing a scanner stops it committing again and changes nothing it
  already committed.
- **Auditors are not scanners by default.** A basic scan is one key's claim, so every key that can
  make one is named in `isScanner`, and one auditor key cannot move a headline score that the
  report path needs a quorum for.
- **Governance owns it from the first block.** The constructor takes the timelock as owner and the
  initial scanners, so the deploying key never owns it. The guardian, the owner's address, can
  only revoke a scanner; adding one goes through the 48-hour timelock.

## KAY9Registry


```solidity
struct AuditResult {
    bytes32 chainKey;
    bytes32 assetId;
    uint8   overallTrust;
    uint8   contractTrust;
    uint8   liquidityTrust;
    uint8   holderTrust;
    uint8   insiderTrust;
    uint8   creatorTrust;
    uint8   tradingTrust;
    uint8   botTrust;
    uint64  flags;
    uint32  engineVersion;
    uint64  analyzedAt;
    bytes32 reportHash;
    string  reportURI;
}

struct ReportMeta {
    uint256 jobId;                  // 0 for unsolicited watchdog reports
    address requester;              // address(0) for watchdog reports
    uint8   declaredRequesterKind;  // 0 unknown, 1 independent, 2 token creator, 3 integration
    uint8   tier;                   // access tier the request consumed; 0 for watchdog reports
}

struct ReportRecord {
    uint256 jobId;                  // 0 for unsolicited watchdog reports
    address requester;
    uint8   declaredRequesterKind;
    uint8   tier;
    AuditResult result;
    address[] signers;
    uint64  committedAt;            // block.timestamp
    uint64  committedBlock;
}

contract KAY9Registry {
    event ReportRecorded(uint256 indexed reportId, bytes32 indexed chainKey, bytes32 indexed assetId, uint256 jobId, uint8 overallTrust, bytes32 reportHash);

    address public immutable auditHub;
    bytes32 public constant CHAIN_ROBINHOOD = keccak256("eip155:4663");
    bytes32 public constant CHAIN_ROBINHOOD_TESTNET = keccak256("eip155:46630");
    bytes32 public constant CHAIN_BNB = keccak256("eip155:56");
    bytes32 public constant CHAIN_SOLANA = keccak256("solana:mainnet");

    function assetKey(bytes32 chainKey, bytes32 assetId) external pure returns (bytes32);   // keccak256(abi.encode(chainKey, assetId))
    function evmAssetId(address token) external pure returns (bytes32);                     // bytes32(uint256(uint160(token)))
    function recordReport(ReportMeta calldata meta, AuditResult calldata result, address[] calldata signers) external returns (uint256 reportId); // only auditHub
    function reportCount() external view returns (uint256);
    function getReport(uint256 reportId) external view returns (ReportRecord memory);
    function getReports(uint256 offset, uint256 limit) external view returns (ReportRecord[] memory);    // newest-first paging handled by caller; returns [offset, offset+limit) clamped to the end of the log
    function historyCount(bytes32 chainKey, bytes32 assetId) external view returns (uint256);
    function history(bytes32 chainKey, bytes32 assetId, uint256 offset, uint256 limit) external view returns (uint256[] memory reportIds); // same clamping as getReports
    function latest(bytes32 chainKey, bytes32 assetId) external view returns (bool exists, ReportRecord memory record);
    function latestAnalyzedAt(bytes32 chainKey, bytes32 assetId) external view returns (bool exists, uint64 analyzedAt);  // the hub's freshness rule for watchdog reports
    function latestSummary(bytes32 chainKey, bytes32 assetId) external view returns (bool exists, uint256 reportId, uint8 overallTrust, uint64 flags, uint32 engineVersion, uint64 committedAt);
    function latestSummaryForToken(bytes32 chainKey, address token) external view returns (bool exists, uint256 reportId, uint8 overallTrust, uint64 flags, uint32 engineVersion, uint64 committedAt);
    function latestSnapshot(bytes32 chainKey, bytes32 assetId) external view returns (bool exists, uint256 reportId, uint8 overallTrust, uint64 flags, uint32 engineVersion, uint8 tier, uint8 declaredRequesterKind, uint64 analyzedAt, uint64 committedAt);
    function scoreHistory(bytes32 chainKey, bytes32 assetId, uint256 offset, uint256 limit) external view returns (uint64[] memory committedAt, uint8[] memory overallTrust);
}
```

`latestSummary` is the read a wallet, DEX, launchpad or badge makes: one call, no arrays of
structs, no report body. `scoreHistory` is the read a risk-over-time chart makes. Both exist so
that consuming KAY9 risk data never requires an off-chain API or a KAY9-operated frontend.

A report is **never** overwritten. A new audit of the same asset appends a new record, and
`history` keeps every one of them in commitment order. `latest` therefore means "most recent
snapshot", not "current truth", and every surface that renders it also renders `committedAt`.

**`committedAt` is when a record was written, not when the asset was looked at.** A requested
audit is pinned to the moment it was requested and may be committed hours later, and because the
log is in commitment order, the latest record can describe an earlier moment than the one before
it. `latestSnapshot` is `latestSummary` with both clocks, the kind of record and its provenance:
`analyzedAt`, the moment the analysis describes; `tier` (0 an unsolicited watchdog report, 1 a
requested deep audit, 2 a forensic one); and `declaredRequesterKind`, what the requester said it
was (0 nothing, 1 independent, 2 the asset's creator, 3 an integration). A surface that presents a
score as current must show `analyzedAt`, must not call a tier-0 record an audit, and must not
render a score commissioned by the asset's own declared creator without saying so. The declaration
is unverified by construction — see *Requester neutrality* — so a surface renders it as declared,
never as established.
`latestSummary` keeps its shape so that nothing already reading it breaks; the registry on
Robinhood testnet predates `latestSnapshot` and does not have it.

Both paging functions clamp rather than revert. `offset` at or past the end returns an empty array, and `limit` is saturating: `type(uint256).max` means "to the end of the log" and never overflows. Callers may therefore treat a maximal limit as "everything from here" without first reading `reportCount`.

## KAY9AuditHub

The hub takes requests, enforces access on-chain, collects auditor attestations, and appends
finalized results to the registry. **No KAY9 changes hands here.** There is no escrow, no fee, no
payment split and no burn; the only thing a request spends is a quota unit in the access vault.

```solidity
enum JobStatus { None, Requested, Fulfilled, Disputed, Expired }

struct Job {
    address requester;
    bytes32 chainKey;
    bytes32 assetId;
    uint8   tier;                    // 1 deep, 2 forensic
    uint8   declaredRequesterKind;   // 0 unknown, 1 independent, 2 token creator, 3 integration
    uint64  requestedAt;              // the analysis pin: a Unix timestamp, resolved per-chain
    uint64  requestedBlock;           // the chain's own height at request time (ArbSys); auditors still pin by requestedAt
                                       // chain, kept for the audit trail only — never an RPC pin
    uint64  accessPeriodStartedAt;   // the vault period the quota unit came from
    uint64  slaSeconds;              // the service level in force at request time, frozen for the job's life
    uint8   attestations;            // how many auditors have taken a position
    JobStatus status;
    uint256 reportId;                // set when fulfilled
}

contract KAY9AuditHub is Ownable2Step, EIP712, ReentrancyGuard {
    event AuditRequested(uint256 indexed jobId, address indexed requester, bytes32 indexed chainKey, bytes32 assetId, uint8 tier, uint8 declaredRequesterKind, uint64 expiresAt);
    event AuditAttested(uint256 indexed jobId, address indexed auditor, bytes32 digest, uint8 votesForDigest);
    event AuditFulfilled(uint256 indexed jobId, uint256 indexed reportId, uint8 overallTrust, address[] signers);
    event AuditDisputed(uint256 indexed jobId, uint8 attestations, uint8 bestAgreement, uint8 required);
    event AuditExpired(uint256 indexed jobId, address indexed requester);
    event WatchdogReportPublished(uint256 indexed reportId, bytes32 indexed chainKey, bytes32 indexed assetId, address[] signers);
    event SlaUpdated(uint64 slaSeconds);
    event RequestsPaused(bool paused);

    uint8 public constant TIER_DEEP     = 1;   // must equal KAY9AccessVault.TIER_DEEP
    uint8 public constant TIER_FORENSIC = 2;   // must equal KAY9AccessVault.TIER_FORENSIC

    uint8 public constant REQUESTER_UNKNOWN     = 0;
    uint8 public constant REQUESTER_INDEPENDENT = 1;
    uint8 public constant REQUESTER_CREATOR     = 2;
    uint8 public constant REQUESTER_INTEGRATION = 3;

    KAY9Registry        public immutable registry;
    KAY9AuditorRegistry public immutable auditors;
    KAY9AccessVault     public accessVault;   // zero before the token; set once, by governance

    // reportURI is deliberately not in this type: it says only where a copy of the report body
    // currently lives, not what the report says, so it never affects whether two auditors agree.
    bytes32 public constant RESULT_TYPEHASH = keccak256("AuditResult(uint256 jobId,bytes32 chainKey,bytes32 assetId,uint8 overallTrust,uint8 contractTrust,uint8 liquidityTrust,uint8 holderTrust,uint8 insiderTrust,uint8 creatorTrust,uint8 tradingTrust,uint8 botTrust,uint64 flags,uint32 engineVersion,uint64 analyzedAt,bytes32 reportHash)");
    uint64 public constant MIN_SLA = 1 hours;
    uint64 public constant MAX_SLA = 30 days;

    uint64  public slaSeconds;      // default 6 hours
    bool    public requestsPaused;
    uint256 public jobCount;

    function requestAudit(bytes32 chainKey, bytes32 assetId, uint8 tier, uint8 declaredRequesterKind) external returns (uint256 jobId);
    function attest(uint256 jobId, AuditResult calldata result, bytes[] calldata signatures) external returns (uint256 reportId);  // caller must be an active auditor; reportId is 0 until quorum lands; reverts JobExpired at or after jobExpiresAt
    function markExpired(uint256 jobId) external;                                    // permissionless at or after jobExpiresAt; restores the quota unit
    function finalizeAgreed(uint256 jobId, AuditResult calldata result) external returns (uint256 reportId);  // caller must be an active auditor; settles a recorded position that meets the current threshold
    function publishWatchdogReport(AuditResult calldata result, bytes[] calldata signatures) external returns (uint256 reportId);  // caller must be an active auditor; analyzedAt must be newer than the asset's latest record
    function renounceOwnership() external;                                            // always reverts RenounceDisabled
    function watchdogReportCommitted(bytes32 digest) external view returns (bool);

    function getJob(uint256 jobId) external view returns (Job memory);
    function attestationOf(uint256 jobId, address auditor) external view returns (bytes32 digest);
    function digestVotes(uint256 jobId, bytes32 digest) external view returns (uint8);
    function bestAgreement(uint256 jobId) external view returns (uint8);
    function jobExpiresAt(uint256 jobId) external view returns (uint64);
    function hashResult(uint256 jobId, AuditResult calldata result) external view returns (bytes32);

    function setSla(uint64 slaSeconds_) external;         // onlyOwner (Timelock)
    function setAccessVault(KAY9AccessVault accessVault_) external;  // onlyOwner (Timelock), once only
    function setRequestsPaused(bool paused) external;     // onlyOwner (Timelock); results, disputes and expiries are never pausable
    // EIP-712 domain: name "KAY9AuditHub", version "1"

    error ZeroAddress();
    error RequestsArePaused();
    error UnknownJob(uint256 jobId);
    error WrongJobStatus(uint256 jobId, JobStatus status);
    error ResultAssetMismatch();
    error InvalidTier(uint8 tier);
    error TierMismatch();
    error InvalidRequesterKind(uint8 kind);
    error NoSignatures();
    error NotAnAuditor(address signer);
    error SubmitterNotAnAuditor(address caller);
    error AlreadyAttested(uint256 jobId, address auditor);
    error SignersNotSorted(address previous, address current);
    error QuorumNotMet(uint256 provided, uint256 required);
    error NotExpired(uint256 jobId, uint64 expiresAt);
    error JobExpired(uint256 jobId, uint64 expiresAt);
    error InvalidSla();
    error DuplicateWatchdogReport(bytes32 digest);
}
```

### How a request is authorised

**The vault arrives after the hub.** The watchdog goes live before $KAY9 exists, and `KAY9Registry`
binds to its hub immutably, so the hub must be the final one from its first deployment — but the
vault holds KAY9 and cannot exist yet. So the hub deploys with `accessVault == address(0)`:
`requestAudit` reverts `AccessVaultNotSet`, and `publishWatchdogReport` — no quota, no requester,
submitted by any active auditor — works from day one, which is how deep and forensic reports are
published in beta.
Governance calls `setAccessVault` exactly once at launch; a second call reverts
`AccessVaultAlreadySet`, so the binding ends up as permanent as an immutable would have been.

`requestAudit` calls `accessVault.consume(msg.sender, tier)`, which reverts unless the caller holds
a live period of at least the requested tier with quota left. The website is never consulted and
cannot grant access; any wallet, script or contract calling the hub directly gets exactly the same
answer. `declaredRequesterKind` is metadata the caller states about itself and the hub records it
verbatim, which is why every surface labels it as declared.

### The deadline is hard

`jobExpiresAt(jobId)` is `requestedAt` plus the SLA that was in force when the job was requested,
and it divides the job's life in two with nothing shared between the halves. Before it, `attest`
is accepted and `markExpired` reverts `NotExpired`. At it and after it, `attest` reverts
`JobExpired` and `markExpired` is the only thing that can happen to the job. A result that missed
the deadline is never recorded against the requester's quota: the unit goes back, and they may
ask again. Without this the two calls raced, and whichever transaction landed first decided
whether a late result spent the unit or the missed deadline returned it.

The vote counters (`Job.attestations`, `digestVotes`) are `uint8` and are incremented with checked
arithmetic. The auditor set has no ceiling, so a job that outlived enough rotations could collect
more than 255 votes; the 256th reverts rather than wrapping the agreement count to zero.

### Attestation and quorum

Each auditor takes exactly one position per job. `attest` accepts one or more 65-byte ECDSA
signatures over the EIP-712 digest of `(jobId, result)`; every recovered signer must be an active
auditor and must not have attested this job already. An auditor holding a peer's agreeing signature
sends both in one transaction, which is the ordinary path; a disagreeing auditor sends its own
signature in its own transaction.

**The submitter must itself be an active auditor**, for `attest` and for `publishWatchdogReport`
alike, and the reason is the one field the signatures do not cover. `reportURI` is deliberately
outside the signed struct (three auditors pinning identical bytes to three backends is not a
disagreement), so whoever lands the finalising transaction chooses the URI the registry records,
permanently. Signatures travel through a relay that anybody can read, so an open `attest` would have
let a stranger race the auditors and write a pointer of their choosing into the permanent log. The
body is still bound by `reportHash`, so the substitution could never change a score — but the record
would carry a dead or hostile pointer forever. Gating the submitter to the auditor set means the
worst case is one of three keyed operators, attributable by `msg.sender`, which is inside the threat
model the quorum already accepts. `markExpired` stays permissionless: nobody can put anything into
the log with it.

- The moment one digest reaches `auditors.threshold()` votes **from auditors who are still in the
  active set**, the job finalises against that result and the record is appended to the registry.
  Attestations are recorded when they arrive, but the auditor set can change between the first and
  the last of them, so the holders of a position are re-checked at the moment it would finalise.
  An operator removed through the timelock cannot carry a job over the line on a stale vote.
- The job becomes `Disputed` as soon as agreement is arithmetically out of reach, that is when
  `bestActive + silent < threshold`. `bestActive` is the largest number of **currently active**
  auditors holding any one position, and `silent` counts currently active auditors who have not
  attested to this job at all. Both are membership-aware: a removed auditor's vote neither fills a
  silent seat nor counts toward a position, because a removed auditor's vote can never finalise.
  With three auditors, a threshold of two and no rotation, three mutually different results still
  dispute the job. A halted registry (threshold zero) disputes nothing; the job can still expire.
- `attest` only checks the position it adds to. If governance lowers the threshold, a position
  recorded earlier can come to meet it with no auditor able to add a vote, so `finalizeAgreed`
  settles it.
- Every score in a result must be at most 100, and `analyzedAt` may not be in the future. A
  watchdog report must also be newer, by `analyzedAt`, than the asset's latest record, so no single
  auditor can publish an older signed snapshot over a newer one.
- A `Disputed` or `Expired` job restores its quota unit to the period it came from, so a caller is
  never charged a quota for an audit that produced no result.

Contradictory results are never averaged, and a dispute is a public on-chain state with the
conflicting digests readable per auditor. Nothing hides disagreement.

### Replay and misuse resistance

The EIP-712 domain binds the chain id and the hub address, so a signature cannot move to another
chain or another deployment. The signed payload contains the job id, so it cannot move to another
job, and `result.chainKey`/`result.assetId` must equal the job's, so it cannot describe another
asset. `attestationOf` blocks the same auditor signing twice. For watchdog reports, which have no
job to consume, signers must be strictly ascending by address and each digest may be committed
once.

### Requester neutrality

Nothing in the request path reaches the scoring path. The hub records who asked and what they
declared themselves to be, and `AuditRequested` carries both — it has to, since the record is public
and a reader is entitled to it. What no auditor reads it *into* is the analysis:
`PinnedAnalysisRequest` carries a chain, an asset, a tier and a pinned block, and no requester field
at all, so there is no path by which `declaredRequesterKind` could reach a signal. There is also no
field an auditor could read that says the creator paid, because nobody pays. A declaration is stored and rendered as declared and unverified, and the
protocol never converts it into a finding of its own: there is no flag for who asked. An earlier
draft of this document reserved bit 18 for an auditor that had established the requester really was
the deployer, and no auditor ever implemented it. It is withdrawn rather than built, because
building it would put requester identity inside the analysis the score is computed from — the one
boundary requester neutrality exists to hold. Bit 18 stays unassigned; do not reuse it.

## Flags bitmask (uint64)

| Bit | Name | Meaning |
|---|---|---|
| 0 | MINTABLE | supply can be increased |
| 1 | FREEZABLE | balances can be frozen / paused |
| 2 | BLACKLIST | address deny-list present |
| 3 | MUTABLE_TAX | transfer fee can be changed |
| 4 | PROXY | upgradeable proxy |
| 5 | OWNER_PRIVILEGES | owner has non-standard powers |
| 6 | LOW_LIQUIDITY | liquidity below thresholds |
| 7 | UNLOCKED_LIQUIDITY | LP supply is not held at a burn address (a third-party time lock is not visible to this check) |
| 8 | HOLDER_CONCENTRATION | top holders exceed thresholds |
| 9 | LINKED_WALLETS | clustered wallets share funding |
| 10 | CREATOR_HISTORY | the deployer created other contracts in the sampled history (their outcomes are not checked) |
| 11 | SNIPERS | a few addresses took most of the tokens sold out of the pool in the first blocks (mints and direct transfers are not in that denominator) |
| 12 | BUNDLED_BUYS | transactions delivered tokens to three or more addresses at once |
| 13 | WASH_TRADING | wash-like volume pattern |
| 14 | HONEYPOT_SIGNALS | sell restrictions suspected |
| 15 | HIDDEN_TRANSFER_RESTRICTION | non-standard transfer logic |
| 16 | UNVERIFIED_SOURCE | source not verified on explorer (informational; scores zero) |
| 17 | INSUFFICIENT_DATA | analysis partial |
| 19 | MONITORING_UPDATE | this report supersedes an earlier one for the same asset (informational; scores zero) |

## Cross-chain identity

`chainKey = keccak256(bytes(key))`. `assetId`: EVM `bytes32(uint256(uint160(addr)))`; Solana = the 32-byte mint public key.

| Chain | Key KAY9 hashes | CAIP-2 identifier |
|---|---|---|
| Robinhood Chain | `eip155:4663` | the same |
| Robinhood Chain testnet | `eip155:46630` | the same |
| BNB Smart Chain | `eip155:56` | the same |
| Solana mainnet | `solana:mainnet` | `solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp` |

For every EVM chain the key *is* the CAIP-2 identifier. For Solana it is not: CAIP-2 names a Solana
cluster by the first 32 characters of its genesis hash, and KAY9 has always filed Solana records
under the alias `solana:mainnet`. The alias stays, because every Solana record and every archived
snapshot is keyed on it and a registry never rewrites what it has recorded. An integrator working
from CAIP-2 identifiers must translate that one key before hashing; `@kay9/chain` exports the
mapping as `CAIP2_IDENTIFIERS`.

---

## Implementation supersets (added during implementation, ABI-compatible)

The Solidity implementation exposes these additional members. They are supersets of the spec above; nothing above was removed or changed.

```solidity
// KAY9Genesis
function markFailed() public;              // permissionless: records a failed launch (auction ended without graduation and its end block checkpointed, or migration recovered) and starts the 48 h relaunch cooldown
function previewLaunch(LaunchParams calldata p) external view returns (address predictedAuction, uint256 impliedFloorFdvWei, uint256 impliedGraduationRaiseWei);

// KAY9LiquidityLock
function track(uint256 tokenId) external;  // permissionless: registers a position this contract already owns (PositionManager mints without a receiver callback)
```

Settlement range note: with native ETH as `currency0` and KAY9 as `currency1`, a KAY9-only position must sit **below the current tick**. Its upper edge is anchored at the lower of the current tick and the auction's clearing tick (`[minUsableTick, min(currentTick, clearingTick) - tickSpacing]`); in price terms that is KAY9 offered at prices above both the current market price and the auction's clearing price, which is what ARCHITECTURE §4.2 describes.
