// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {KAY9Registry, AuditResult, ReportMeta} from "./KAY9Registry.sol";
import {KAY9AuditorRegistry} from "./KAY9AuditorRegistry.sol";
import {KAY9AccessVault} from "./KAY9AccessVault.sol";

/// @notice The lifecycle of an audit request.
/// @dev A job leaves `Requested` in exactly one of three ways: the auditors agree and it is
///      `Fulfilled`, they cannot agree and it is `Disputed`, or nobody answered in time and it is
///      `Expired`. The last two give the quota unit back.
enum JobStatus {
    None,
    Requested,
    Fulfilled,
    Disputed,
    Expired
}

/// @notice One audit request.
/// @dev No KAY9 is held here. The only thing a request spends is a quota unit in the access vault,
///      and `accessPeriodStartedAt` records which period it came from so a later restore cannot
///      credit a different one.
struct Job {
    address requester;
    bytes32 chainKey;
    bytes32 assetId;
    uint8 tier;
    uint8 declaredRequesterKind;
    /// The analysis pin every auditor resolves against the target chain's own history. A Unix
    /// timestamp, never `requestedBlock` below: it means the same thing on every chain, which
    /// `requestedBlock` does not (see its own comment).
    uint64 requestedAt;
    /// The chain's own height at request time, read through `BlockNumberish` (ArbSys on this
    /// Arbitrum Orbit chain), which is the number `eth_getLogs`, `eth_call` and the explorer use.
    /// Kept for the on-chain audit trail; the auditors still pin their analysis to `requestedAt`,
    /// because a timestamp means the same thing on every chain an audited asset can live on.
    uint64 requestedBlock;
    uint64 accessPeriodStartedAt;
    /// The service level in force when this job was requested, frozen for its whole life. A later
    /// `setSla` call must never move a pending job's own deadline — see `_disputeIfUnreachable`'s
    /// neighbour, `markExpired`, for why that snapshot is load-bearing.
    uint64 slaSeconds;
    uint8 attestations;
    JobStatus status;
    uint256 reportId;
}

/// @title KAY9AuditHub
/// @notice Takes audit requests, checks access on-chain against the vault, collects auditor
///         attestations, and appends agreed results to the append-only registry.
/// @dev Nothing is charged. Access is a lock in KAY9AccessVault, and a request debits one quota
///      unit of the requested tier. Results are authenticated with EIP-712 signatures over the job
///      id and the result struct; the domain separator binds the chain id and this contract's
///      address, so a signature can never be replayed on another chain or against a different
///      deployment, and the job id inside the signed payload stops replay across jobs.
///
///      Each auditor takes at most one position per job. When one position reaches the quorum
///      threshold the job finalises; when agreement becomes arithmetically impossible the job is
///      disputed and says so on-chain. Contradictory results are never averaged.
/// @custom:security-contact security@kay9.io
contract KAY9AuditHub is Ownable2Step, EIP712, ReentrancyGuard, BlockNumberish {
    /// @notice Emitted when a request is accepted and its quota unit debited.
    /// @param jobId The new job id.
    /// @param requester The caller.
    /// @param chainKey The CAIP-2 chain key hash of the asset to audit.
    /// @param assetId The asset identifier within that chain.
    /// @param tier The requested tier.
    /// @param declaredRequesterKind What the caller says it is. Metadata, never verified here.
    /// @param expiresAt When the request may be marked expired.
    event AuditRequested(
        uint256 indexed jobId,
        address indexed requester,
        bytes32 indexed chainKey,
        bytes32 assetId,
        uint8 tier,
        uint8 declaredRequesterKind,
        uint64 expiresAt
    );

    /// @notice Emitted for every auditor position recorded against a job.
    /// @param jobId The job.
    /// @param auditor The signer.
    /// @param digest The result the auditor signed.
    /// @param votesForDigest How many auditors now hold that position.
    event AuditAttested(uint256 indexed jobId, address indexed auditor, bytes32 digest, uint8 votesForDigest);

    /// @notice Emitted when a position reaches quorum and the result is recorded.
    /// @param jobId The settled job.
    /// @param reportId The registry index of the recorded report.
    /// @param overallTrust The headline trust score.
    /// @param signers The auditors that held the winning position, in ascending address order.
    event AuditFulfilled(uint256 indexed jobId, uint256 indexed reportId, uint8 overallTrust, address[] signers);

    /// @notice Emitted when the auditors cannot reach quorum.
    /// @param jobId The disputed job.
    /// @param attestations How many auditors took a position.
    /// @param bestAgreement The largest number that agreed on any one result.
    /// @param required The quorum threshold at the time.
    event AuditDisputed(uint256 indexed jobId, uint8 attestations, uint8 bestAgreement, uint8 required);

    /// @notice Emitted when a request times out without a result.
    /// @param jobId The expired job.
    /// @param requester The caller whose quota unit is restored.
    event AuditExpired(uint256 indexed jobId, address indexed requester);

    /// @notice Emitted when the quorum commits an unsolicited report.
    /// @param reportId The registry index of the recorded report.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @param signers The auditors that signed.
    event WatchdogReportPublished(
        uint256 indexed reportId, bytes32 indexed chainKey, bytes32 indexed assetId, address[] signers
    );

    /// @notice Emitted when the service level changes.
    /// @param slaSeconds The new service level, in seconds.
    event SlaUpdated(uint64 slaSeconds);

    /// @notice Emitted when new requests are paused or unpaused.
    /// @param paused Whether new requests are refused.
    event RequestsPaused(bool paused);

    /// @notice Thrown when a constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a new request arrives while requests are paused.
    error RequestsArePaused();

    /// @notice Thrown when an audit is requested before governance has set an access vault.
    /// @dev The state the hub is in between the watchdog going live and the token launching.
    ///      Unsolicited quorum-signed reports still work; requests do not, because there is
    ///      nothing to spend.
    error AccessVaultNotSet();

    /// @notice Thrown when the access vault is set a second time.
    /// @dev Once is all governance gets. A hub that could be re-pointed could be made to honour
    ///      quota nobody locked for.
    error AccessVaultAlreadySet();

    /// @notice Thrown when a job id does not exist.
    /// @param jobId The unknown job.
    error UnknownJob(uint256 jobId);

    /// @notice Thrown when a job is not in the state the call requires.
    /// @param jobId The job.
    /// @param status The job's current status.
    error WrongJobStatus(uint256 jobId, JobStatus status);

    /// @notice Thrown when a submitted result does not describe the job's asset.
    error ResultAssetMismatch();

    /// @notice Thrown when a tier outside {deep, forensic} is requested.
    /// @param tier The rejected tier.
    error InvalidTier(uint8 tier);

    /// @notice Thrown at deployment when the vault's tier constants differ from this contract's.
    error TierMismatch();

    /// @notice Thrown when a requester kind outside the documented set is declared.
    /// @param kind The rejected value.
    error InvalidRequesterKind(uint8 kind);

    /// @notice Thrown when attest is called with an empty signature array.
    error NoSignatures();

    /// @notice Thrown when a recovered signer is not an active auditor.
    /// @param signer The rejected signer.
    error NotAnAuditor(address signer);

    /// @notice Thrown when the account submitting signatures is not itself an active auditor.
    /// @dev `reportURI` is the one field of a result the signatures do not cover, so whoever lands
    ///      the finalising transaction chooses the pointer the registry records forever. Auditor
    ///      signatures travel through a relay anybody can read, so an open submit path would let a
    ///      stranger race the auditors and write a hostile or dead pointer into the permanent log.
    ///      The body is still bound by `reportHash`, so a score can never be changed that way, but
    ///      the record would point nowhere. Requiring the submitter to be an auditor bounds the
    ///      worst case to one of the keyed operators, attributable by `msg.sender`.
    /// @param caller The rejected submitter.
    error SubmitterNotAnAuditor(address caller);

    /// @notice Thrown when an auditor takes a second position on the same job.
    /// @param jobId The job.
    /// @param auditor The auditor that already attested.
    error AlreadyAttested(uint256 jobId, address auditor);

    /// @notice Thrown when watchdog signers are not in strictly ascending address order.
    /// @param previous The previous signer.
    /// @param current The offending signer.
    error SignersNotSorted(address previous, address current);

    /// @notice Thrown when fewer valid signatures are supplied than the quorum requires.
    /// @param provided The number of accepted signatures.
    /// @param required The quorum threshold.
    error QuorumNotMet(uint256 provided, uint256 required);

    /// @notice Thrown when markExpired is called before the service level has elapsed.
    /// @param jobId The job.
    /// @param expiresAt The timestamp the job expires at.
    error NotExpired(uint256 jobId, uint64 expiresAt);

    /// @notice Thrown when a result arrives at or after the job's deadline.
    /// @param jobId The job.
    /// @param expiresAt The deadline it missed.
    error JobExpired(uint256 jobId, uint64 expiresAt);

    /// @notice Thrown when the service level would be set outside its allowed range.
    error InvalidSla();

    /// @notice Emitted when governance binds the access vault, which opens requests.
    /// @param accessVault The vault.
    event AccessVaultSet(address indexed accessVault);

    /// @notice Thrown when a score in a result is above 100, the top of every trust scale.
    error ScoreOutOfRange();

    /// @notice Thrown when a watchdog report is not newer than the asset's latest record.
    /// @dev Without this, any one auditor holding an older quorum-signed report that was never
    ///      published could publish it after a newer one and make the stale snapshot `latest`.
    /// @param analyzedAt The rejected report's analysis time.
    /// @param latestAnalyzedAt The analysis time of the asset's current latest record.
    error StaleWatchdogReport(uint64 analyzedAt, uint64 latestAnalyzedAt);

    /// @notice Thrown when a result claims to have been analysed in the future.
    /// @param analyzedAt The rejected analysis time.
    error AnalyzedInFuture(uint64 analyzedAt);

    /// @notice Thrown by `renounceOwnership`: an ownerless hub could never bind its access vault.
    error RenounceDisabled();

    /// @notice Thrown when a watchdog report that has already been committed is submitted again.
    /// @param digest The EIP-712 digest of the duplicate report.
    error DuplicateWatchdogReport(bytes32 digest);

    /// @notice The deep tier. Must equal KAY9AccessVault.TIER_DEEP.
    /// @dev Mirrored rather than read from the vault, because reading it would be two external
    ///      calls on the hot path to learn two numbers that can never change. The deployment
    ///      script asserts the two agree.
    uint8 public constant TIER_DEEP = 1;

    /// @notice The forensic tier. Must equal KAY9AccessVault.TIER_FORENSIC.
    uint8 public constant TIER_FORENSIC = 2;

    /// @notice The requester said nothing about itself.
    uint8 public constant REQUESTER_UNKNOWN = 0;

    /// @notice The requester says it has no relationship with the asset.
    uint8 public constant REQUESTER_INDEPENDENT = 1;

    /// @notice The requester says it is the asset's creator. A claim, not a verified fact.
    uint8 public constant REQUESTER_CREATOR = 2;

    /// @notice The requester says it is an integration acting for someone else.
    uint8 public constant REQUESTER_INTEGRATION = 3;

    /// @notice The append-only report log.
    KAY9Registry public immutable registry;

    /// @notice The auditor set and quorum threshold.
    KAY9AuditorRegistry public immutable auditors;

    /// @notice The lock that grants access and holds the quota.
    /// @notice The vault that holds access locks and quota, or the zero address before the token.
    ///
    /// @dev Not immutable, and set at most once, because of the order the protocol ships in. The
    ///      watchdog runs on mainnet before $KAY9 exists; the vault holds KAY9, so it cannot exist
    ///      until the token does. But `KAY9Registry` binds to its hub **immutably**, so the hub has
    ///      to be the final one from the very first deployment — there is no second chance to point
    ///      the registry somewhere else.
    ///
    ///      So the hub deploys without a vault and does the work that needs no access:
    ///      `publishWatchdogReport` needs no request, consumes no quota, and is how a quorum
    ///      publishes an unsolicited deep or forensic report. `requestAudit` is the only thing that
    ///      needs the vault, and it refuses until governance sets one.
    ///
    ///      The setter is `onlyOwner`, which in production is the 48-hour timelock, and it can be
    ///      used exactly once. After that the binding is as permanent as an immutable would have
    ///      been: nobody, including governance, can point the hub at a different vault and start
    ///      honouring quota nobody locked for.
    KAY9AccessVault public accessVault;

    /// @notice The EIP-712 type hash of a signed audit result.
    /// @dev `reportURI` is deliberately not in this type, and not in `_structHash` below, even
    ///      though the `AuditResult` struct itself still carries it. `reportURI` says only where a
    ///      copy of the report body currently lives; `reportHash`, which *is* signed, is what binds
    ///      that document to this record (KAY9Registry.sol's own doc comment on `AuditResult`).
    ///      Three independent auditors pinning byte-identical content to three different storage
    ///      backends is not a disagreement — it was treated as one before this fix, which meant
    ///      quorum could not form whenever operators' pinning behaviour merely differed, let alone
    ///      failed (R17 in KAY9-REVIEW.md).
    bytes32 public constant RESULT_TYPEHASH = keccak256(
        "AuditResult(uint256 jobId,bytes32 chainKey,bytes32 assetId,uint8 overallTrust,uint8 contractTrust,uint8 liquidityTrust,uint8 holderTrust,uint8 insiderTrust,uint8 creatorTrust,uint8 tradingTrust,uint8 botTrust,uint64 flags,uint32 engineVersion,uint64 analyzedAt,bytes32 reportHash)"
    );

    /// @notice The shortest service level governance may configure, in seconds.
    uint64 public constant MIN_SLA = 1 hours;

    /// @notice The longest service level governance may configure, in seconds.
    uint64 public constant MAX_SLA = 30 days;

    /// @notice How long a job may stay unanswered before it can be expired, in seconds.
    uint64 public slaSeconds;

    /// @notice Whether new requests are refused. Results, disputes and expiries are never pausable.
    bool public requestsPaused;

    /// @notice The number of jobs ever created. Job ids start at one.
    uint256 public jobCount;

    /// @notice Every job by id.
    mapping(uint256 jobId => Job) private _jobs;

    /// @notice The position each auditor has taken on each job, as a result digest.
    mapping(uint256 jobId => mapping(address auditor => bytes32 digest)) public attestationOf;

    /// @notice How many auditors hold each position on each job.
    mapping(uint256 jobId => mapping(bytes32 digest => uint8 votes)) public digestVotes;

    /// @notice The largest agreement reached on each job so far.
    mapping(uint256 jobId => uint8 votes) public bestAgreement;

    /// @notice The auditors holding each position on a job, kept in ascending address order.
    mapping(uint256 jobId => mapping(bytes32 digest => address[] signers)) private _digestSigners;

    /// @notice Every distinct position taken on each job, in the order first taken.
    /// @dev Bounded by the auditor set, which `KAY9AuditorRegistry.MAX_AUDITORS` caps. Kept so the
    ///      dispute check can count each position's **active** holders after the set rotates.
    mapping(uint256 jobId => bytes32[] digests) private _jobDigests;

    /// @notice The digest of every watchdog report already committed, so none can be replayed.
    mapping(bytes32 digest => bool) public watchdogReportCommitted;

    /// @notice Deploys the hub.
    /// @param owner_ The owner, which in production is the TimelockController.
    /// @param registryAddress The append-only report log bound to this hub.
    /// @param auditors_ The auditor set.
    /// @param accessVault_ The access vault that holds locks and quota, or zero before the token
    ///        exists. With zero, `requestAudit` refuses and `publishWatchdogReport` still works.
    constructor(address owner_, address registryAddress, KAY9AuditorRegistry auditors_, KAY9AccessVault accessVault_)
        Ownable(owner_)
        EIP712("KAY9AuditHub", "1")
    {
        if (registryAddress == address(0) || address(auditors_) == address(0)) {
            revert ZeroAddress();
        }
        // A zero vault is legal and means "before the token": requests are refused until governance
        // sets one. A non-zero vault is checked now, exactly as it would have been if immutable.
        if (address(accessVault_) != address(0)) {
            if (accessVault_.TIER_DEEP() != TIER_DEEP || accessVault_.TIER_FORENSIC() != TIER_FORENSIC) {
                revert TierMismatch();
            }
        }
        registry = KAY9Registry(registryAddress);
        auditors = auditors_;
        accessVault = accessVault_;
        slaSeconds = 6 hours;
        emit SlaUpdated(6 hours);
    }

    // -------------------------------------------------------------------------------------------
    // Requests
    // -------------------------------------------------------------------------------------------

    /// @notice Creates an audit request, debiting one quota unit from the caller's access period.
    /// @dev The vault, not this contract and certainly not a website, decides whether the caller
    ///      may request. A caller with no live period, the wrong tier or no quota left reverts
    ///      inside `consume`.
    /// @param chainKey The CAIP-2 chain key hash of the asset.
    /// @param assetId The asset identifier within that chain.
    /// @param tier The requested tier: 1 deep, 2 forensic.
    /// @param declaredRequesterKind What the caller states it is. Recorded verbatim as metadata and
    ///        never consulted by the analysis.
    /// @return jobId The new job id.
    function requestAudit(bytes32 chainKey, bytes32 assetId, uint8 tier, uint8 declaredRequesterKind)
        external
        nonReentrant
        returns (uint256 jobId)
    {
        if (requestsPaused) revert RequestsArePaused();
        if (tier != TIER_DEEP && tier != TIER_FORENSIC) revert InvalidTier(tier);
        if (declaredRequesterKind > REQUESTER_INTEGRATION) revert InvalidRequesterKind(declaredRequesterKind);

        if (address(accessVault) == address(0)) revert AccessVaultNotSet();
        uint64 periodStartedAt = accessVault.consume(msg.sender, tier);

        jobId = ++jobCount;
        // The current service level is captured here and never read live again for this job.
        // Without this, a governance change to slaSeconds while jobs are pending moved every
        // pending job's actual deadline in markExpired/jobExpiresAt away from the one the
        // AuditRequested event below already promised.
        uint64 slaAtRequest = slaSeconds;
        _jobs[jobId] = Job({
            requester: msg.sender,
            chainKey: chainKey,
            assetId: assetId,
            tier: tier,
            declaredRequesterKind: declaredRequesterKind,
            requestedAt: uint64(block.timestamp),
            requestedBlock: uint64(_getBlockNumberish()),
            accessPeriodStartedAt: periodStartedAt,
            slaSeconds: slaAtRequest,
            attestations: 0,
            status: JobStatus.Requested,
            reportId: 0
        });

        emit AuditRequested(
            jobId, msg.sender, chainKey, assetId, tier, declaredRequesterKind, uint64(block.timestamp) + slaAtRequest
        );
    }

    /// @notice Expires a job whose service level has elapsed and gives the quota unit back.
    /// @dev Permissionless. A request that produced no result must not cost the requester anything.
    ///      The deadline is the SLA that was in force when this job was requested, not whatever
    ///      `slaSeconds` has since become — a job's promised deadline does not move under it.
    /// @param jobId The job to expire.
    function markExpired(uint256 jobId) external nonReentrant {
        Job storage job = _jobs[jobId];
        if (job.status == JobStatus.None) revert UnknownJob(jobId);
        if (job.status != JobStatus.Requested) revert WrongJobStatus(jobId, job.status);

        uint64 expiresAt = job.requestedAt + job.slaSeconds;
        if (block.timestamp < expiresAt) revert NotExpired(jobId, expiresAt);

        job.status = JobStatus.Expired;
        emit AuditExpired(jobId, job.requester);
        accessVault.restore(job.requester, job.tier, job.accessPeriodStartedAt);
    }

    // -------------------------------------------------------------------------------------------
    // Results
    // -------------------------------------------------------------------------------------------

    /// @notice The EIP-712 digest the auditors sign.
    /// @param jobId The job the result settles, or zero for a watchdog report.
    /// @param result The result being committed.
    /// @return The digest.
    function hashResult(uint256 jobId, AuditResult calldata result) public view returns (bytes32) {
        return _hashTypedDataV4(_structHash(jobId, result));
    }

    /// @notice When a job may be expired.
    /// @dev Reads the job's own frozen SLA (see `Job.slaSeconds`), not the current `slaSeconds`,
    ///      so this always agrees with the deadline `AuditRequested` promised and with what
    ///      `markExpired` will actually enforce.
    /// @param jobId The job.
    /// @return The expiry timestamp, or zero for a job that does not exist.
    function jobExpiresAt(uint256 jobId) external view returns (uint64) {
        Job storage job = _jobs[jobId];
        if (job.status == JobStatus.None) return 0;
        return job.requestedAt + job.slaSeconds;
    }

    /// @notice Records one or more auditor positions on a job, finalising it if quorum is reached.
    /// @dev The ordinary path is an auditor sending its own signature together with a peer's
    ///      agreeing one in a single transaction. An auditor that disagrees sends its own signature
    ///      in its own transaction; that position is recorded rather than discarded, which is what
    ///      makes disagreement visible. The submitter must be an active auditor: see
    ///      `SubmitterNotAnAuditor` for why the unsigned `reportURI` makes that necessary.
    /// @param jobId The job being attested.
    /// @param result The result these signatures cover. Its chainKey and assetId must match the job.
    /// @param signatures The 65-byte ECDSA signatures over the job's digest of this result.
    /// @return reportId The registry index of the recorded report, or zero if quorum has not landed.
    function attest(uint256 jobId, AuditResult calldata result, bytes[] calldata signatures)
        external
        nonReentrant
        returns (uint256 reportId)
    {
        _requireAuditorSubmitter();
        Job storage job = _jobs[jobId];
        if (job.status == JobStatus.None) revert UnknownJob(jobId);
        if (job.status != JobStatus.Requested) revert WrongJobStatus(jobId, job.status);
        // The deadline is hard. From `expiresAt` on, `markExpired` is the only thing that can
        // happen to this job, and it returns the requester's quota unit. Without this the two raced:
        // whichever transaction landed first decided whether a late result spent the unit or the
        // missed deadline gave it back, and a requester could not tell which they would get.
        uint64 expiresAt = job.requestedAt + job.slaSeconds;
        if (block.timestamp >= expiresAt) revert JobExpired(jobId, expiresAt);
        if (result.chainKey != job.chainKey || result.assetId != job.assetId) revert ResultAssetMismatch();

        uint256 count = signatures.length;
        if (count == 0) revert NoSignatures();

        _checkResult(result);
        bytes32 digest = hashResult(jobId, result);
        uint8 votes = digestVotes[jobId][digest];
        if (votes == 0) _jobDigests[jobId].push(digest);

        for (uint256 i = 0; i < count; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (!auditors.isAuditor(signer)) revert NotAnAuditor(signer);
            if (attestationOf[jobId][signer] != bytes32(0)) revert AlreadyAttested(jobId, signer);

            attestationOf[jobId][signer] = digest;
            _insertSorted(_digestSigners[jobId][digest], signer);
            // Checked arithmetic. The auditor set is capped at MAX_AUDITORS, far below 255, so a
            // job would need many full rotations inside its SLA to reach the limit; if it ever
            // did, the 256th vote reverts rather than wrapping the agreement count to zero.
            votes += 1;
            job.attestations += 1;
            emit AuditAttested(jobId, signer, digest, votes);
        }

        digestVotes[jobId][digest] = votes;
        if (votes > bestAgreement[jobId]) bestAgreement[jobId] = votes;

        uint8 required = auditors.threshold();
        if (required != 0 && votes >= required) {
            // Attestations are recorded when they arrive, but the auditor set can change between
            // the first and the last of them. A position is only allowed to finalise if every
            // auditor still holding it is still an auditor, so that an operator removed through
            // the timelock cannot carry a job over the line on a stale vote.
            address[] memory holders = _activeHolders(jobId, digest);
            if (holders.length >= required) return _finalize(jobId, job, result, holders);
        }

        _disputeIfUnreachable(jobId, job, required);
        return 0;
    }

    /// @notice Finalises a job whose recorded position already meets the current quorum.
    /// @dev `attest` only checks the position it has just added to. When governance lowers the
    ///      threshold, a position recorded earlier can come to meet the quorum with no auditor able
    ///      to add to it, since each holds one position per job. This settles it. Like `attest` it
    ///      needs an auditor submitter, because `reportURI` is not signed, and it applies the same
    ///      deadline and the same active-holder filter.
    /// @param jobId The job.
    /// @param result The result the recorded position signed.
    /// @return reportId The registry index of the recorded report.
    function finalizeAgreed(uint256 jobId, AuditResult calldata result)
        external
        nonReentrant
        returns (uint256 reportId)
    {
        _requireAuditorSubmitter();
        Job storage job = _jobs[jobId];
        if (job.status == JobStatus.None) revert UnknownJob(jobId);
        if (job.status != JobStatus.Requested) revert WrongJobStatus(jobId, job.status);
        uint64 expiresAt = job.requestedAt + job.slaSeconds;
        if (block.timestamp >= expiresAt) revert JobExpired(jobId, expiresAt);
        if (result.chainKey != job.chainKey || result.assetId != job.assetId) revert ResultAssetMismatch();

        bytes32 digest = hashResult(jobId, result);
        uint8 required = auditors.threshold();
        address[] memory holders = _activeHolders(jobId, digest);
        if (required == 0 || holders.length < required) revert QuorumNotMet(holders.length, required);
        return _finalize(jobId, job, result, holders);
    }

    /// @notice Commits an unsolicited, unpaid report signed by the quorum.
    /// @dev This is the continuous-monitoring path: an asset can be re-reported at any time without
    ///      anyone requesting it, and the registry appends rather than replaces. Unlike a job,
    ///      nothing is consumed by committing one, so the digest is recorded and a second
    ///      submission of the same signed report is refused. Without that, anyone holding one valid
    ///      signature set could append the same record to the permanent log without limit.
    ///
    ///      It is not permissionless: the submitter must be an active auditor, for the same
    ///      `reportURI` reason as `attest`. A report must also be newer, by `analyzedAt`, than the
    ///      asset's latest record, so no single auditor can make an older signed snapshot `latest`.
    /// @param result The signed result.
    /// @param signatures The 65-byte ECDSA signatures, ordered by ascending signer address.
    /// @return reportId The registry index of the recorded report.
    function publishWatchdogReport(AuditResult calldata result, bytes[] calldata signatures)
        external
        nonReentrant
        returns (uint256 reportId)
    {
        _requireAuditorSubmitter();
        _checkResult(result);
        bytes32 digest = hashResult(0, result);
        if (watchdogReportCommitted[digest]) revert DuplicateWatchdogReport(digest);
        (bool exists, uint64 latestAnalyzedAt) = registry.latestAnalyzedAt(result.chainKey, result.assetId);
        if (exists && result.analyzedAt <= latestAnalyzedAt) {
            revert StaleWatchdogReport(result.analyzedAt, latestAnalyzedAt);
        }
        watchdogReportCommitted[digest] = true;

        address[] memory signers = _verifySorted(digest, signatures);

        reportId = registry.recordReport(
            ReportMeta({jobId: 0, requester: address(0), declaredRequesterKind: REQUESTER_UNKNOWN, tier: 0}),
            result,
            signers
        );
        emit WatchdogReportPublished(reportId, result.chainKey, result.assetId, signers);
    }

    /// @notice Binds the access vault, once, opening requests.
    /// @dev The one governance action that turns the pre-token hub into the full one. It is
    ///      `onlyOwner` — the 48-hour timelock in production — refuses a second call, and applies
    ///      the same tier check the constructor would have applied to a vault supplied at
    ///      deployment. It cannot touch anything already committed.
    /// @param accessVault_ The vault.
    function setAccessVault(KAY9AccessVault accessVault_) external onlyOwner {
        if (address(accessVault) != address(0)) revert AccessVaultAlreadySet();
        if (address(accessVault_) == address(0)) revert ZeroAddress();
        if (accessVault_.TIER_DEEP() != TIER_DEEP || accessVault_.TIER_FORENSIC() != TIER_FORENSIC) {
            revert TierMismatch();
        }
        accessVault = accessVault_;
        emit AccessVaultSet(address(accessVault_));
    }

    /// @notice A job by id.
    /// @param jobId The job id.
    /// @return The job.
    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    /// @notice The auditors holding one position on a job.
    /// @param jobId The job.
    /// @param digest The position.
    /// @return The signers, in ascending address order.
    function digestSigners(uint256 jobId, bytes32 digest) external view returns (address[] memory) {
        return _digestSigners[jobId][digest];
    }

    // -------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------

    /// @notice Sets the service level after which an unanswered job may be expired.
    /// @param slaSeconds_ The new service level, within [MIN_SLA, MAX_SLA].
    function setSla(uint64 slaSeconds_) external onlyOwner {
        if (slaSeconds_ < MIN_SLA || slaSeconds_ > MAX_SLA) revert InvalidSla();
        slaSeconds = slaSeconds_;
        emit SlaUpdated(slaSeconds_);
    }

    /// @notice Pauses or unpauses new requests. Results, disputes and expiries are never affected.
    /// @param paused Whether to refuse new requests.
    function setRequestsPaused(bool paused) external onlyOwner {
        requestsPaused = paused;
        emit RequestsPaused(paused);
    }

    // -------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------

    /// @notice Disabled. An ownerless hub could never bind its access vault.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Refuses a result whose scores leave the 0-100 scale or whose analysis is in the future.
    /// @param result The result.
    function _checkResult(AuditResult calldata result) private view {
        if (
            result.overallTrust > 100 || result.contractTrust > 100 || result.liquidityTrust > 100
                || result.holderTrust > 100 || result.insiderTrust > 100 || result.creatorTrust > 100
                || result.tradingTrust > 100 || result.botTrust > 100
        ) revert ScoreOutOfRange();
        if (result.analyzedAt > block.timestamp) revert AnalyzedInFuture(result.analyzedAt);
    }

    /// @notice Refuses a submitter that is not an active auditor.
    /// @dev Applied to every path that can append to the registry. `markExpired` does not need it,
    ///      because nothing reaches the log through it.
    function _requireAuditorSubmitter() private view {
        if (!auditors.isAuditor(msg.sender)) revert SubmitterNotAnAuditor(msg.sender);
    }

    /// @notice The EIP-712 struct hash of a result.
    /// @dev The payload is assembled in four chunks because encoding all fifteen members in one
    ///      expression exhausts the EVM stack under the legacy code generator. The concatenation is
    ///      byte-for-byte identical to a single abi.encode of the same members. `result.reportURI`
    ///      is deliberately not one of them — see `RESULT_TYPEHASH`.
    /// @param jobId The job the result settles, or zero for a watchdog report.
    /// @param result The result being committed.
    /// @return The struct hash.
    function _structHash(uint256 jobId, AuditResult calldata result) private pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                abi.encode(RESULT_TYPEHASH, jobId, result.chainKey, result.assetId),
                abi.encode(result.overallTrust, result.contractTrust, result.liquidityTrust, result.holderTrust),
                abi.encode(result.insiderTrust, result.creatorTrust, result.tradingTrust, result.botTrust),
                abi.encode(result.flags, result.engineVersion, result.analyzedAt, result.reportHash)
            )
        );
    }

    /// @notice Records the agreed result and closes the job.
    /// @param jobId The job.
    /// @param job The job storage pointer.
    /// @param result The agreed result.
    /// @param signerList The auditors that agreed and are still active, in ascending order.
    /// @return reportId The registry index of the recorded report.
    function _finalize(uint256 jobId, Job storage job, AuditResult calldata result, address[] memory signerList)
        private
        returns (uint256 reportId)
    {
        job.status = JobStatus.Fulfilled;

        reportId = registry.recordReport(
            ReportMeta({
                jobId: jobId, requester: job.requester, declaredRequesterKind: job.declaredRequesterKind, tier: job.tier
            }),
            result,
            signerList
        );
        job.reportId = reportId;

        emit AuditFulfilled(jobId, reportId, result.overallTrust, signerList);
    }

    /// @notice The auditors holding a position who are still in the active auditor set.
    /// @dev Preserves ascending order, because the stored array is kept sorted and this filters
    ///      it without reordering.
    /// @param jobId The job.
    /// @param digest The position.
    /// @return active The subset still authorised to sign.
    function _activeHolders(uint256 jobId, bytes32 digest) private view returns (address[] memory active) {
        address[] storage holders = _digestSigners[jobId][digest];
        uint256 total = holders.length;

        uint256 count = 0;
        for (uint256 i = 0; i < total; ++i) {
            if (auditors.isAuditor(holders[i])) ++count;
        }

        active = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < total; ++i) {
            address holder = holders[i];
            if (auditors.isAuditor(holder)) {
                active[j] = holder;
                unchecked {
                    ++j;
                }
            }
        }
    }

    /// @notice Disputes a job once no position can still reach the threshold.
    /// @dev The best any position can end at is its **active** holders now, plus every currently
    ///      active auditor who has not attested to this job at all. When that is below the
    ///      threshold for every position, waiting cannot help.
    ///
    ///      Both halves are membership-aware. Counting silence as `auditorCount - attestations`
    ///      goes wrong once the set rotates, because a removed auditor's vote still occupies a
    ///      slot; counting a position by its historical votes goes wrong the same way, because a
    ///      position whose holders were removed can never finalise (`_activeHolders` filters
    ///      them). An earlier version used the historical `bestAgreement` and left such a job
    ///      `Requested` until it expired, even when no position could reach the quorum.
    ///
    ///      A zero threshold means the registry is halted. Nothing is disputed then, because the
    ///      owner is expected to restore a quorum, and the job can still expire.
    /// @param jobId The job.
    /// @param job The job storage pointer.
    /// @param required The quorum threshold.
    function _disputeIfUnreachable(uint256 jobId, Job storage job, uint8 required) private {
        if (required == 0) return;
        address[] memory current = auditors.auditors();
        uint256 silent = 0;
        for (uint256 i = 0; i < current.length; ++i) {
            if (attestationOf[jobId][current[i]] == bytes32(0)) ++silent;
        }
        // Enough silent auditors to reach the quorum on their own: nothing to count.
        if (silent >= required) return;

        uint256 best = 0;
        bytes32[] storage digests = _jobDigests[jobId];
        for (uint256 i = 0; i < digests.length; ++i) {
            address[] storage holders = _digestSigners[jobId][digests[i]];
            uint256 active = 0;
            for (uint256 j = 0; j < holders.length; ++j) {
                if (auditors.isAuditor(holders[j])) ++active;
            }
            if (active > best) best = active;
        }

        if (best + silent >= required) return;

        job.status = JobStatus.Disputed;
        emit AuditDisputed(jobId, job.attestations, uint8(best), required);
        accessVault.restore(job.requester, job.tier, job.accessPeriodStartedAt);
    }

    /// @notice Inserts an address into an ascending array, keeping it sorted.
    /// @dev The arrays hold at most the auditor set, which is three, so the shift is trivial.
    /// @param list The array to insert into.
    /// @param value The address to insert.
    function _insertSorted(address[] storage list, address value) private {
        list.push(value);
        uint256 i = list.length - 1;
        while (i > 0 && list[i - 1] > value) {
            list[i] = list[i - 1];
            unchecked {
                --i;
            }
        }
        list[i] = value;
    }

    /// @notice Recovers and validates a sorted signature set against one digest.
    /// @dev Used for watchdog reports, which carry no per-job attestation state, so ascending order
    ///      is what rules out the same auditor being counted twice.
    /// @param digest The signed digest.
    /// @param signatures The signatures to verify.
    /// @return signers The recovered signers, in ascending address order.
    function _verifySorted(bytes32 digest, bytes[] calldata signatures)
        private
        view
        returns (address[] memory signers)
    {
        uint256 required = auditors.threshold();
        uint256 count = signatures.length;
        if (count < required || required == 0) revert QuorumNotMet(count, required);

        signers = new address[](count);
        address previous = address(0);
        for (uint256 i = 0; i < count; ++i) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer <= previous) revert SignersNotSorted(previous, signer);
            if (!auditors.isAuditor(signer)) revert NotAnAuditor(signer);
            signers[i] = signer;
            previous = signer;
        }
    }
}
