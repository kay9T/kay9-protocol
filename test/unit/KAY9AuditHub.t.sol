// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AuditHub, Job, JobStatus} from "../../src/KAY9AuditHub.sol";
import {KAY9AccessVault} from "../../src/KAY9AccessVault.sol";
import {AuditResult, ReportRecord} from "../../src/KAY9Registry.sol";
import {KAY9AuditorRegistry} from "../../src/KAY9AuditorRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice A vault stand-in that reports tier numbers of its own choosing, to prove the hub
///         refuses to be wired to a vault it does not agree with.
contract MockTierVault {
    /// @notice The deep tier this stand-in claims.
    uint8 private immutable _deep;

    /// @notice The forensic tier this stand-in claims.
    uint8 private immutable _forensic;

    /// @notice Sets the tier numbers to report.
    /// @param deep The deep tier.
    /// @param forensic The forensic tier.
    constructor(uint8 deep, uint8 forensic) {
        _deep = deep;
        _forensic = forensic;
    }

    /// @notice The deep tier this stand-in claims.
    /// @return The tier.
    // solhint-disable-next-line func-name-mixedcase
    function TIER_DEEP() external view returns (uint8) {
        return _deep;
    }

    /// @notice The forensic tier this stand-in claims.
    /// @return The tier.
    // solhint-disable-next-line func-name-mixedcase
    function TIER_FORENSIC() external view returns (uint8) {
        return _forensic;
    }
}

/// @title KAY9AuditHubTest
/// @notice Covers the request gate, the attestation quorum, the dispute and expiry paths and the
///         signature rules of the audit protocol.
/// @dev No KAY9 changes hands in the hub, so the thing a request spends is a quota unit and the
///      thing a failed job must give back is that same unit. Every settlement assertion is written
///      against the registry record rather than an event, because the record is what survives.
contract KAY9AuditHubTest is Kay9TestBase {
    /// @notice A requester holding a forensic access period.
    address internal requester = makeAddr("requester");

    /// @notice A second requester, used where two provenances must be compared.
    address internal creator = makeAddr("creator");

    /// @notice An account that holds no access period at all.
    address internal outsider = makeAddr("outsider");

    /// @notice The chain key of the audited asset.
    bytes32 internal chainKey;

    /// @notice The asset identifier of the audited asset.
    bytes32 internal assetId = bytes32(uint256(uint160(0x1234567890AbcdEF1234567890aBcdef12345678)));

    /// @notice The chain id to restore after a cross-chain digest is computed.
    /// @dev Storage, not a local: the optimizer treats CHAINID as constant inside a call and would
    ///      re-read it after `vm.chainId` had already moved it.
    uint256 internal originalChainId;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();
        chainKey = reportRegistry.CHAIN_ROBINHOOD();
        _grantAccess(requester, TIER_FORENSIC);
    }

    // -------------------------------------------------------------------------------------------
    // The request gate
    // -------------------------------------------------------------------------------------------

    /// @notice A request debits one quota unit, records the job and charges nothing.
    function test_requestSpendsQuotaAndNothingElse() public {
        uint256 vaultBalance = token.balanceOf(address(accessVault));

        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);

        assertEq(jobId, 1, "job ids start at one");
        assertEq(token.balanceOf(address(hub)), 0, "the hub never holds KAY9");
        assertEq(token.balanceOf(address(accessVault)), vaultBalance, "and the lock is not touched");
        assertEq(accessVault.deepRemaining(requester), 3, "exactly one deep unit was spent");
        assertEq(accessVault.forensicRemaining(requester), 1, "the forensic unit is untouched");

        Job memory job = hub.getJob(jobId);
        assertEq(job.requester, requester, "the requester is recorded");
        assertEq(job.chainKey, chainKey, "the chain key is recorded");
        assertEq(job.assetId, assetId, "the asset is recorded");
        assertEq(job.tier, TIER_DEEP, "the tier is recorded");
        assertEq(job.declaredRequesterKind, KIND_INDEPENDENT, "the declared kind is recorded");
        assertEq(job.requestedAt, uint64(vm.getBlockTimestamp()), "the request time is recorded");
        assertEq(
            job.accessPeriodStartedAt,
            accessVault.accessOf(requester).startedAt,
            "the job remembers which period paid for it"
        );
        assertEq(uint8(job.status), uint8(JobStatus.Requested), "the job is open");
        assertEq(job.attestations, 0, "nobody has spoken yet");
        assertEq(hub.jobExpiresAt(jobId), job.requestedAt + hub.slaSeconds(), "the service level is set");
    }

    /// @notice A caller with no access period cannot request, whoever it is.
    function test_requestWithoutAccessReverts() public {
        vm.prank(outsider);
        vm.expectRevert(KAY9AccessVault.NoAccess.selector);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);
        assertEq(hub.jobCount(), 0, "no job was created");
    }

    /// @notice A deep period cannot buy a forensic audit.
    function test_requestWithTheWrongTierReverts() public {
        _grantAccess(creator, TIER_DEEP);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.TierNotPermitted.selector, TIER_DEEP, TIER_FORENSIC));
        hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);

        assertEq(accessVault.deepRemaining(creator), 4, "and the refused request cost nothing");
    }

    /// @notice An exhausted allowance cannot be stretched.
    function test_requestWithNoQuotaLeftReverts() public {
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(requester);
            hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, KIND_INDEPENDENT);
        }
        assertEq(accessVault.deepRemaining(requester), 0, "the deep allowance is spent");

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);

        // The forensic unit is a different allowance and is still there.
        vm.prank(requester);
        hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);
        assertEq(accessVault.forensicRemaining(requester), 0, "the forensic allowance is spent too");
    }

    /// @notice A tier the protocol does not have is refused by the hub before the vault is asked.
    function test_requestWithAnInvalidTierReverts() public {
        vm.startPrank(requester);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.InvalidTier.selector, uint8(0)));
        hub.requestAudit(chainKey, assetId, 0, KIND_INDEPENDENT);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.InvalidTier.selector, uint8(3)));
        hub.requestAudit(chainKey, assetId, 3, KIND_INDEPENDENT);
        vm.stopPrank();

        assertEq(accessVault.deepRemaining(requester), 4, "nothing was spent");
        assertEq(hub.jobCount(), 0, "and no job was created");
    }

    /// @notice A requester kind outside the documented set is refused.
    function test_requestWithAnInvalidRequesterKindReverts() public {
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.InvalidRequesterKind.selector, uint8(4)));
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 4);

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.InvalidRequesterKind.selector, type(uint8).max));
        hub.requestAudit(chainKey, assetId, TIER_DEEP, type(uint8).max);

        assertEq(accessVault.deepRemaining(requester), 4, "nothing was spent");
    }

    /// @notice Every documented requester kind is accepted and stored exactly as declared.
    function test_declaredRequesterKindIsRecordedVerbatim() public {
        uint8[4] memory kinds = [KIND_UNKNOWN, KIND_INDEPENDENT, KIND_CREATOR, KIND_INTEGRATION];

        for (uint256 i = 0; i < kinds.length; ++i) {
            address caller = makeAddr(string(abi.encodePacked("kindCaller", i)));
            _grantAccess(caller, TIER_DEEP);
            vm.prank(caller);
            uint256 jobId = hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, kinds[i]);
            assertEq(hub.getJob(jobId).declaredRequesterKind, kinds[i], "the hub stores what was declared");

            AuditResult memory result = _result();
            result.assetId = bytes32(i + 1);
            bytes[] memory hoistedSignatures1 = _sign(jobId, result, 2);
            vm.prank(auditorAddresses[0]);
            uint256 reportId = hub.attest(jobId, result, hoistedSignatures1);
            assertEq(
                reportRegistry.getReport(reportId).declaredRequesterKind,
                kinds[i],
                "and the declaration reaches the permanent record"
            );
            assertEq(reportRegistry.getReport(reportId).requester, caller, "next to who actually asked");
            assertEq(reportRegistry.getReport(reportId).tier, TIER_DEEP, "and the tier it was requested under");
        }
    }

    /// @notice Pausing stops new requests and nothing else.
    function test_pauseOnlyBlocksNewRequests() public {
        _outliveGovernance();
        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);

        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setRequestsPaused, (true)));

        vm.prank(requester);
        vm.expectRevert(KAY9AuditHub.RequestsArePaused.selector);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);

        // The already-open job still settles while paused.
        AuditResult memory result = _result();
        bytes[] memory hoistedSignatures2 = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, hoistedSignatures2);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "results are never pausable");
    }

    // -------------------------------------------------------------------------------------------
    // Requester neutrality
    // -------------------------------------------------------------------------------------------

    /// @notice A creator-declared request and an independent one travel the identical code path:
    ///         the two records differ in their provenance fields and in nothing else.
    function test_creatorAndIndependentRequestsAreIdenticalExceptForMetadata() public {
        _grantAccess(creator, TIER_DEEP);

        vm.prank(requester);
        uint256 independentJob = hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);
        vm.prank(creator);
        uint256 creatorJob = hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_CREATOR);

        // The very same finding, signed by the very same quorum, for both jobs.
        AuditResult memory result = _result();
        bytes[] memory hoistedSignatures3 = _sign(independentJob, result, 2);
        vm.prank(auditorAddresses[0]);
        uint256 independentReport = hub.attest(independentJob, result, hoistedSignatures3);
        bytes[] memory hoistedSignatures4 = _sign(creatorJob, result, 2);
        vm.prank(auditorAddresses[0]);
        uint256 creatorReport = hub.attest(creatorJob, result, hoistedSignatures4);

        ReportRecord memory a = reportRegistry.getReport(independentReport);
        ReportRecord memory b = reportRegistry.getReport(creatorReport);

        assertEq(b.result.overallTrust, a.result.overallTrust, "the score does not depend on who asked");
        assertEq(b.result.contractTrust, a.result.contractTrust, "nor any sub-score");
        assertEq(b.result.creatorTrust, a.result.creatorTrust, "least of all the creator sub-score");
        assertEq(b.result.flags, a.result.flags, "nor the flags");
        assertEq(b.result.reportHash, a.result.reportHash, "nor the report itself");
        assertEq(b.result.reportURI, a.result.reportURI, "nor where it is pinned");
        assertEq(b.signers.length, a.signers.length, "the same quorum signed both");
        assertEq(b.signers[0], a.signers[0], "the same auditors");
        assertEq(b.signers[1], a.signers[1], "the same auditors");
        assertEq(b.tier, a.tier, "at the same tier");
        assertEq(b.committedAt, a.committedAt, "in the same block");

        // And the only differences are the provenance the hub is asked to record.
        assertEq(a.declaredRequesterKind, KIND_INDEPENDENT, "one declared itself independent");
        assertEq(b.declaredRequesterKind, KIND_CREATOR, "the other declared itself the creator");
        assertEq(a.requester, requester, "and they are different callers");
        assertEq(b.requester, creator, "and they are different callers");
        assertTrue(a.jobId != b.jobId, "with different jobs");
    }

    // -------------------------------------------------------------------------------------------
    // Quorum
    // -------------------------------------------------------------------------------------------

    /// @notice One signature is recorded as a position but does not finalise a job.
    function test_oneSignatureDoesNotFinalise() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);
        address[] memory signers = _signerSet(2);

        bytes[] memory hoistedSignatures5 = _sign(jobId, result, 1);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, result, hoistedSignatures5);

        assertEq(reportId, 0, "nothing was recorded");
        assertEq(reportRegistry.reportCount(), 0, "the log did not grow");
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "the job is still open");
        assertEq(hub.getJob(jobId).attestations, 1, "one auditor has spoken");
        assertEq(hub.digestVotes(jobId, digest), 1, "one vote for that position");
        assertEq(hub.attestationOf(jobId, signers[0]), digest, "and it is on the record");
        assertEq(hub.bestAgreement(jobId), 1, "the best agreement so far is one");
    }

    /// @notice Two agreeing signatures in one transaction finalise the job.
    function test_twoAgreeingSignaturesFinaliseInOneTransaction() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        address[] memory signers = _signerSet(2);

        bytes[] memory hoistedSignatures6 = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, result, hoistedSignatures6);

        Job memory job = hub.getJob(jobId);
        assertEq(uint8(job.status), uint8(JobStatus.Fulfilled), "the job settled");
        assertEq(job.reportId, reportId, "and points at its record");
        assertEq(job.attestations, 2, "two auditors spoke");

        ReportRecord memory record = reportRegistry.getReport(reportId);
        assertEq(record.jobId, jobId, "the record names the job");
        assertEq(record.result.reportHash, result.reportHash, "and holds the signed report hash");
        assertEq(record.signers.length, 2, "with both signers");
        assertEq(record.signers[0], signers[0], "in ascending order");
        assertEq(record.signers[1], signers[1], "in ascending order");
        assertEq(token.balanceOf(address(hub)), 0, "and no KAY9 moved");
    }

    /// @notice Two auditors that pinned byte-identical content to different backends still agree.
    /// @dev R17 in KAY9-REVIEW.md: `reportURI` says only where a copy of the report body currently
    ///      lives, not what the report says, so it is deliberately excluded from `RESULT_TYPEHASH`.
    ///      Before that fix, two structs differing only in `reportURI` hashed to different digests,
    ///      so quorum could never form once independent operators' pinning behaviour merely
    ///      differed — not even a failure on either side, just two different (but equally valid)
    ///      storage backends.
    function test_differentReportURIsStillReachQuorum() public {
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(2);

        AuditResult memory pinnedToIpfs = _result();
        pinnedToIpfs.reportURI = "ipfs://bafyone";
        AuditResult memory pinnedLocally = _result();
        pinnedLocally.reportURI = "kay9://local/deadbeef";

        bytes[] memory fromFirst = new bytes[](1);
        fromFirst[0] = _signDigest(_keyOf(signers[0]), _hash(jobId, pinnedToIpfs));
        bytes[] memory fromSecond = new bytes[](1);
        fromSecond[0] = _signDigest(_keyOf(signers[1]), _hash(jobId, pinnedLocally));

        // Both signatures verify against whichever struct is actually submitted, because the
        // reportURI each signer happened to have pinned to never entered the digest either signed.
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, pinnedToIpfs, fromFirst);
        assertEq(reportId, 0, "one position does not settle anything yet");
        vm.prank(auditorAddresses[0]);
        reportId = hub.attest(jobId, pinnedToIpfs, fromSecond);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the job settled");
        ReportRecord memory record = reportRegistry.getReport(reportId);
        assertEq(record.signers.length, 2, "both auditors are credited");
        assertEq(record.result.reportURI, pinnedToIpfs.reportURI, "the submitted struct's URI is what is recorded");
    }

    /// @notice The same quorum reached across two separate transactions settles identically.
    function test_twoSeparateAttestationsFinalise() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);
        address[] memory signers = _signerSet(2);

        bytes[] memory first = new bytes[](1);
        first[0] = _signDigest(_keyOf(signers[0]), digest);
        vm.prank(auditorAddresses[0]);
        assertEq(hub.attest(jobId, result, first), 0, "the first position does not settle anything");
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "the job is still open");

        bytes[] memory second = new bytes[](1);
        second[0] = _signDigest(_keyOf(signers[1]), digest);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, result, second);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the second position settles it");
        assertEq(hub.digestVotes(jobId, digest), 2, "both votes are on the same position");
        assertEq(reportRegistry.getReport(reportId).signers.length, 2, "and both signers are recorded");
        assertEq(reportRegistry.getReport(reportId).signers[0], signers[0], "in ascending order");
        assertEq(reportRegistry.getReport(reportId).signers[1], signers[1], "in ascending order");
    }

    /// @notice An auditor takes at most one position per job.
    function test_anAuditorCannotAttestTwice() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        address[] memory signers = _signerSet(1);

        bytes[] memory signatures = _sign(jobId, result, 1);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, signatures);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.AlreadyAttested.selector, jobId, signers[0]));
        hub.attest(jobId, result, signatures);

        // Not even by changing its mind about the result.
        AuditResult memory other = _result();
        other.overallTrust = 99;
        bytes[] memory changedMind = new bytes[](1);
        changedMind[0] = _signDigest(_keyOf(signers[0]), _hash(jobId, other));
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.AlreadyAttested.selector, jobId, signers[0]));
        hub.attest(jobId, other, changedMind);

        assertEq(hub.getJob(jobId).attestations, 1, "still exactly one position");
    }

    /// @notice The same auditor twice inside one transaction is refused too.
    function test_theSameAuditorTwiceInOneCallIsRefused() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);
        address[] memory signers = _signerSet(1);

        bytes[] memory duplicated = new bytes[](2);
        duplicated[0] = _signDigest(_keyOf(signers[0]), digest);
        duplicated[1] = duplicated[0];

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.AlreadyAttested.selector, jobId, signers[0]));
        hub.attest(jobId, result, duplicated);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "nothing settled");
    }

    /// @notice A signature from outside the auditor set is refused.
    function test_aNonAuditorSignatureIsRefused() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signDigest(_keyOf(_signerSet(1)[0]), digest);
        signatures[1] = _signDigest(0xBADA55, digest);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.NotAnAuditor.selector, vm.addr(0xBADA55)));
        hub.attest(jobId, result, signatures);
    }

    /// @notice An auditor removed from the set can no longer take a position.
    function test_aRemovedAuditorCannotAttest() public {
        _outliveGovernance();
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(3);
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));

        AuditResult memory result = _result();
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signDigest(_keyOf(signers[0]), _hash(jobId, result));

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.NotAnAuditor.selector, signers[0]));
        hub.attest(jobId, result, signatures);
    }

    /// @notice An empty signature array is refused rather than treated as a no-op.
    function test_attestWithNoSignaturesIsRefused() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(KAY9AuditHub.NoSignatures.selector);
        hub.attest(jobId, result, new bytes[](0));
    }

    /// @notice A job that does not exist cannot be attested or expired.
    function test_unknownJobsAreRejected() public {
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(99, result, 2);
        assertEq(hub.jobExpiresAt(99), 0, "an unknown job has no expiry");

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.UnknownJob.selector, uint256(99)));
        hub.attest(99, result, signatures);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.UnknownJob.selector, uint256(99)));
        hub.markExpired(99);
    }

    // -------------------------------------------------------------------------------------------
    // Replay resistance
    // -------------------------------------------------------------------------------------------

    /// @notice A signature for one job cannot be replayed onto another.
    function test_noReplayAcrossJobs() public {
        uint256 first = _openJob();
        uint256 second = _openJob();

        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(first, result, 2);

        // The digest of the second job is different, so the recovered address is not an auditor.
        vm.prank(auditorAddresses[0]);
        vm.expectPartialRevert(KAY9AuditHub.NotAnAuditor.selector);
        hub.attest(second, result, signatures);
        assertEq(uint8(hub.getJob(second).status), uint8(JobStatus.Requested), "the second job is untouched");
    }

    /// @notice A signature made against another chain's domain is not accepted here.
    function test_noReplayAcrossChains() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes32 digestHere = _hash(jobId, result);

        // The chain id is kept in storage rather than a local, because the optimizer treats
        // CHAINID as constant within a call and would re-read it after vm.chainId had moved it,
        // which would silently restore the wrong chain and make the assertion below vacuous.
        originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);
        bytes32 digestElsewhere = _hash(jobId, result);
        vm.chainId(originalChainId);
        assertEq(block.chainid, originalChainId, "the original chain id is restored");
        assertTrue(digestHere != digestElsewhere, "the chain id is part of the digest");
        assertEq(_hash(jobId, result), digestHere, "and the local digest is the original one again");

        bytes[] memory foreign = new bytes[](1);
        foreign[0] = _signDigest(_keyOf(_signerSet(1)[0]), digestElsewhere);
        vm.prank(auditorAddresses[0]);
        vm.expectPartialRevert(KAY9AuditHub.NotAnAuditor.selector);
        hub.attest(jobId, result, foreign);
    }

    /// @notice A signature made against another deployment of the hub is not accepted here.
    function test_noReplayAcrossDeployments() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();

        KAY9AuditHub other = new KAY9AuditHub(address(timelock), address(reportRegistry), auditorRegistry, accessVault);
        bytes32 digestThere = this.callHashResultOn(other, jobId, result);
        assertTrue(digestThere != _hash(jobId, result), "the hub address is part of the digest");

        bytes[] memory foreign = new bytes[](1);
        foreign[0] = _signDigest(_keyOf(_signerSet(1)[0]), digestThere);
        vm.prank(auditorAddresses[0]);
        vm.expectPartialRevert(KAY9AuditHub.NotAnAuditor.selector);
        hub.attest(jobId, result, foreign);
    }

    /// @notice A result about another asset than the job named is refused.
    function test_aResultMustDescribeTheJobsAsset() public {
        uint256 jobId = _openJob();

        AuditResult memory otherAsset = _result();
        otherAsset.assetId = bytes32(uint256(999));
        bytes[] memory otherAssetSignatures = _sign(jobId, otherAsset, 2);

        AuditResult memory otherChain = _result();
        otherChain.chainKey = reportRegistry.CHAIN_BNB();
        bytes[] memory otherChainSignatures = _sign(jobId, otherChain, 2);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(KAY9AuditHub.ResultAssetMismatch.selector);
        hub.attest(jobId, otherAsset, otherAssetSignatures);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(KAY9AuditHub.ResultAssetMismatch.selector);
        hub.attest(jobId, otherChain, otherChainSignatures);

        assertEq(reportRegistry.reportCount(), 0, "nothing about another asset was recorded");
    }

    // -------------------------------------------------------------------------------------------
    // Disputes
    // -------------------------------------------------------------------------------------------

    /// @notice Three auditors with three different answers dispute the job, the quota unit comes
    ///         back, and every conflicting position stays readable.
    function test_threeDifferentResultsDisputeTheJob() public {
        uint256 jobId = _openJob();
        assertEq(accessVault.deepRemaining(requester), 3, "the request spent a unit");

        address[] memory signers = _signerSet(3);
        bytes32[] memory digests = new bytes32[](3);

        for (uint256 i = 0; i < 3; ++i) {
            AuditResult memory result = _result();
            result.overallTrust = uint8(10 + i * 30);
            result.reportHash = keccak256(abi.encode("disagreement", i));
            digests[i] = _hash(jobId, result);

            bytes[] memory signature = new bytes[](1);
            signature[0] = _signDigest(_keyOf(signers[i]), digests[i]);
            vm.prank(auditorAddresses[0]);
            hub.attest(jobId, result, signature);

            if (i < 2) {
                assertEq(
                    uint8(hub.getJob(jobId).status),
                    uint8(JobStatus.Requested),
                    "agreement is still arithmetically reachable"
                );
            }
        }

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Disputed), "the job is disputed");
        assertEq(hub.getJob(jobId).attestations, 3, "all three spoke");
        assertEq(hub.bestAgreement(jobId), 1, "and no two agreed");
        assertEq(reportRegistry.reportCount(), 0, "nothing contradictory was recorded");
        assertEq(accessVault.deepRemaining(requester), 4, "the quota unit came back");

        for (uint256 i = 0; i < 3; ++i) {
            assertEq(hub.attestationOf(jobId, signers[i]), digests[i], "each auditor's position is readable");
            assertEq(hub.digestVotes(jobId, digests[i]), 1, "each position has exactly one vote");
            assertEq(hub.digestSigners(jobId, digests[i]).length, 1, "and exactly one signer");
            assertEq(hub.digestSigners(jobId, digests[i])[0], signers[i], "who is that auditor");
            for (uint256 j = i + 1; j < 3; ++j) {
                assertTrue(digests[i] != digests[j], "the positions really are different");
            }
        }
    }

    /// @notice A disputed job is closed: it can never be finalised or expired afterwards.
    function test_aDisputedJobCannotThenBeFinalised() public {
        uint256 jobId = _disputedJob();
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 2);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.WrongJobStatus.selector, jobId, JobStatus.Disputed));
        hub.attest(jobId, result, signatures);

        vm.warp(vm.getBlockTimestamp() + hub.slaSeconds());
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.WrongJobStatus.selector, jobId, JobStatus.Disputed));
        hub.markExpired(jobId);

        assertEq(accessVault.deepRemaining(requester), 4, "and the unit is restored exactly once");
    }

    /// @notice A fulfilled job is closed: it can never be disputed or expired afterwards.
    function test_aFulfilledJobCannotBeDisputedOrExpired() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes[] memory hoistedSignatures7 = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, hoistedSignatures7);

        address[] memory signers = _signerSet(3);
        AuditResult memory dissent = _result();
        dissent.overallTrust = 7;
        bytes[] memory late = new bytes[](1);
        late[0] = _signDigest(_keyOf(signers[2]), _hash(jobId, dissent));

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.WrongJobStatus.selector, jobId, JobStatus.Fulfilled));
        hub.attest(jobId, dissent, late);

        vm.warp(vm.getBlockTimestamp() + hub.slaSeconds());
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.WrongJobStatus.selector, jobId, JobStatus.Fulfilled));
        hub.markExpired(jobId);

        assertEq(accessVault.deepRemaining(requester), 3, "a fulfilled job keeps its quota unit spent");
        assertEq(reportRegistry.reportCount(), 1, "and its single record");
    }

    /// @notice Two of three agreeing still finalises even after one auditor has dissented.
    function test_oneDissenterDoesNotBlockAQuorum() public {
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(3);

        AuditResult memory dissent = _result();
        dissent.overallTrust = 3;
        bytes[] memory dissenting = new bytes[](1);
        dissenting[0] = _signDigest(_keyOf(signers[2]), _hash(jobId, dissent));
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, dissent, dissenting);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "one dissent does not close the job");

        AuditResult memory agreed = _result();
        bytes[] memory hoistedSignatures8 = _sign(jobId, agreed, 2);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, agreed, hoistedSignatures8);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the majority position wins");
        ReportRecord memory record = reportRegistry.getReport(reportId);
        assertEq(record.result.overallTrust, agreed.overallTrust, "the recorded score is the agreed one");
        assertEq(record.signers.length, 2, "only the auditors that agreed are credited");
        assertEq(hub.attestationOf(jobId, signers[2]), _hash(jobId, dissent), "the dissent stays on the record");
    }

    // -------------------------------------------------------------------------------------------
    // The auditor set changing mid-job
    // -------------------------------------------------------------------------------------------

    /// @notice An auditor removed after it attested cannot carry the job over the line on the vote
    ///         it cast before removal: the job stays open instead.
    function test_aRemovedAuditorCannotCarryAJobOverTheLine() public {
        _outliveGovernance();
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(3);
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);

        bytes[] memory fromFirst = new bytes[](1);
        fromFirst[0] = _signDigest(_keyOf(signers[0]), digest);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, fromFirst);

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));

        bytes[] memory fromSecond = new bytes[](1);
        fromSecond[0] = _signDigest(_keyOf(signers[1]), digest);
        vm.prank(auditorAddresses[0]);
        assertEq(hub.attest(jobId, result, fromSecond), 0, "the stale vote did not finalise the job");

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "the job is still open");
        assertEq(reportRegistry.reportCount(), 0, "and nothing was written to the permanent log");
        assertEq(hub.digestVotes(jobId, digest), 2, "the removed auditor's vote is still counted as cast");
        assertEq(hub.attestationOf(jobId, signers[0]), digest, "and its position is not rewritten");
        assertEq(hub.digestSigners(jobId, digest).length, 2, "nor deleted from the position's holders");
    }

    /// @notice A third, still active auditor finalises the same position, and the removed one is
    ///         absent from the permanent record.
    function test_aThirdActiveAuditorFinalisesWithoutTheRemovedOne() public {
        _outliveGovernance();
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(3);
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);

        bytes[] memory fromFirst = new bytes[](1);
        fromFirst[0] = _signDigest(_keyOf(signers[0]), digest);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, fromFirst);

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));

        bytes[] memory fromSecond = new bytes[](1);
        fromSecond[0] = _signDigest(_keyOf(signers[1]), digest);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, fromSecond);

        bytes[] memory fromThird = new bytes[](1);
        fromThird[0] = _signDigest(_keyOf(signers[2]), digest);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, result, fromThird);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "two active auditors settled it");
        ReportRecord memory record = reportRegistry.getReport(reportId);
        assertEq(record.signers.length, 2, "exactly two signers are credited");
        assertEq(record.signers[0], signers[1], "the second auditor");
        assertEq(record.signers[1], signers[2], "and the third");
        assertTrue(record.signers[0] != signers[0], "the removed auditor is not in the record");
        assertTrue(record.signers[1] != signers[0], "the removed auditor is not in the record");
        assertTrue(record.signers[0] < record.signers[1], "and the array is still ascending");
    }

    /// @notice Removing an auditor after a job has settled changes nothing about the record.
    function test_removingAnAuditorAfterFinalisationChangesNothing() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes[] memory hoistedSignatures9 = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, result, hoistedSignatures9);

        address[] memory signers = _signerSet(2);
        ReportRecord memory before = reportRegistry.getReport(reportId);

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));

        ReportRecord memory after_ = reportRegistry.getReport(reportId);
        assertEq(after_.signers.length, before.signers.length, "the record still names both signers");
        assertEq(after_.signers[0], signers[0], "including the one that has since been removed");
        assertEq(after_.signers[1], signers[1], "and the one that has not");
        assertEq(after_.result.reportHash, before.result.reportHash, "the result is untouched");
        assertEq(after_.committedAt, before.committedAt, "and so is when it was committed");
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the job is still fulfilled");
    }

    /// @notice R21 — rotation must not let a removed auditor's stale vote hide that an active,
    ///         still-silent auditor could still bring the job to quorum.
    /// @dev The scenario from the external review: the first holder of a position is replaced
    ///      mid-job, the second auditor votes a different result, and the replacement votes a
    ///      third, different result. Historically `job.attestations` reaches the auditor count —
    ///      the removed auditor's stale vote still counted toward it — even though the surviving
    ///      original auditor has not voted at all and could still match either live position.
    ///      A job in that state must stay open, not dispute.
    function test_rotationDoesNotDisputeAJobTheSurvivingAuditorCouldStillSettle() public {
        _outliveGovernance();
        address[] memory signers = _signerSet(3);
        uint256 extraKey = 0xD00D;
        address extra = vm.addr(extraKey);

        uint256 jobId = _openJob();

        // The first holder votes, then is replaced.
        AuditResult memory resultX = _result();
        resultX.overallTrust = 10;
        resultX.reportHash = keccak256(abi.encode("rotation", "x"));
        _attestAlone(jobId, resultX, _keyOf(signers[0]), _hash(jobId, resultX));

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.addAuditor, (extra)));

        // The second original auditor votes a different result.
        AuditResult memory resultY = _result();
        resultY.overallTrust = 40;
        resultY.reportHash = keccak256(abi.encode("rotation", "y"));
        _attestAlone(jobId, resultY, _keyOf(signers[1]), _hash(jobId, resultY));

        // signers[2] — the surviving original auditor — never votes here. It is the one this test
        // is about: still active, still silent, and still able to bring either live position to
        // quorum.

        // The replacement votes a third, different result.
        AuditResult memory resultZ = _result();
        resultZ.overallTrust = 70;
        resultZ.reportHash = keccak256(abi.encode("rotation", "z"));
        _attestAlone(jobId, resultZ, extraKey, _hash(jobId, resultZ));

        assertEq(hub.getJob(jobId).attestations, 3, "three attestations recorded, one from a removed auditor");
        assertEq(auditorRegistry.auditorCount(), 3, "the active set is still three members");
        assertEq(hub.bestAgreement(jobId), 1, "no two positions agree yet");
        assertEq(
            uint8(hub.getJob(jobId).status),
            uint8(JobStatus.Requested),
            "quorum is still reachable through the surviving silent auditor and must not dispute"
        );

        // Proof it really was reachable: the surviving auditor matches the second original vote.
        bytes[] memory fromSurvivor = new bytes[](1);
        fromSurvivor[0] = _signDigest(_keyOf(signers[2]), _hash(jobId, resultY));
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.attest(jobId, resultY, fromSurvivor);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the job settles");
        ReportRecord memory record = reportRegistry.getReport(reportId);
        assertEq(record.signers.length, 2, "exactly the two who agreed");
    }

    /// @notice The same rotation, but now genuinely unreachable: every active auditor has voted
    ///         and no two agree. This must still dispute — the fix narrows a false dispute, it
    ///         does not stop disputing jobs that truly cannot reach quorum.
    function test_rotationStillDisputesWhenEveryActiveAuditorHasSpokenAndNoneAgree() public {
        _outliveGovernance();
        address[] memory signers = _signerSet(3);
        uint256 extraKey = 0xD00D;
        address extra = vm.addr(extraKey);

        uint256 jobId = _openJob();

        AuditResult memory resultX = _result();
        resultX.overallTrust = 10;
        resultX.reportHash = keccak256(abi.encode("rotation-full", "x"));
        _attestAlone(jobId, resultX, _keyOf(signers[0]), _hash(jobId, resultX));

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.addAuditor, (extra)));

        AuditResult memory resultY = _result();
        resultY.overallTrust = 40;
        resultY.reportHash = keccak256(abi.encode("rotation-full", "y"));
        _attestAlone(jobId, resultY, _keyOf(signers[1]), _hash(jobId, resultY));

        AuditResult memory resultZ = _result();
        resultZ.overallTrust = 70;
        resultZ.reportHash = keccak256(abi.encode("rotation-full", "z"));
        _attestAlone(jobId, resultZ, _keyOf(signers[2]), _hash(jobId, resultZ));

        // Now the extra auditor votes a fourth, distinct result — every currently active auditor
        // (signers[1], signers[2], extra) has spoken, and no two of them agree.
        AuditResult memory resultW = _result();
        resultW.overallTrust = 90;
        resultW.reportHash = keccak256(abi.encode("rotation-full", "w"));
        _attestAlone(jobId, resultW, extraKey, _hash(jobId, resultW));

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Disputed), "nobody left to reach quorum");
        assertEq(reportRegistry.reportCount(), 0, "nothing contradictory was recorded");
    }

    /// @notice Filtering a removed auditor out of the middle of a position keeps the signer array
    ///         in ascending address order, which is what the registry and every reader assume.
    function test_theFilteredSignerArrayStaysAscending() public {
        _outliveGovernance();
        uint256 extraKey = 0xD00D;
        address extra = vm.addr(extraKey);
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.addAuditor, (extra)));
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.setThreshold, (3)));

        (address[] memory members, uint256[] memory keys) = _sortedMembership(extraKey);
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes32 digest = _hash(jobId, result);

        _attestAlone(jobId, result, keys[0], digest);
        _attestAlone(jobId, result, keys[1], digest);

        // The middle holder leaves the set with its vote already recorded.
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (members[1])));

        _attestAlone(jobId, result, keys[2], digest);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "two active holders are not three");

        _attestAlone(jobId, result, keys[3], digest);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the third active holder settles it");

        ReportRecord memory record = reportRegistry.getReport(hub.getJob(jobId).reportId);
        assertEq(record.signers.length, 3, "three signers, not four");
        assertEq(record.signers[0], members[0], "the first holder");
        assertEq(record.signers[1], members[2], "then the third, the removed one having been dropped");
        assertEq(record.signers[2], members[3], "then the fourth");
        assertTrue(record.signers[0] < record.signers[1], "still ascending across the gap");
        assertTrue(record.signers[1] < record.signers[2], "still ascending across the gap");
    }

    /// @notice A job whose remaining auditor leaves the set can no longer finalise and is not
    ///         disputed either, because a dispute is only ever evaluated inside `attest`. The
    ///         service level is the way out, and it returns the quota unit.
    /// @dev This is the one state a third party's timing can leave a job in that the auditors did
    ///      not choose. It costs the requester nothing, which is what makes it acceptable.
    function test_aJobNobodyCanStillFinaliseWaitsForTheSlaRatherThanDisputing() public {
        _outliveGovernance();
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(3);

        AuditResult memory first = _result();
        AuditResult memory second = _result();
        second.overallTrust = 9;
        second.reportHash = keccak256("the other reading");

        _attestAlone(jobId, first, _keyOf(signers[0]), _hash(jobId, first));
        _attestAlone(jobId, second, _keyOf(signers[1]), _hash(jobId, second));
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "the third auditor could still agree");

        // The only auditor that has not spoken leaves the set.
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[2])));

        bytes[] memory tooLate = new bytes[](1);
        tooLate[0] = _signDigest(_keyOf(signers[2]), _hash(jobId, first));
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.NotAnAuditor.selector, signers[2]));
        hub.attest(jobId, first, tooLate);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "the job is still open, not disputed");
        assertEq(reportRegistry.reportCount(), 0, "and nothing was recorded");

        // The service level is the only remaining exit, and it costs the requester nothing.
        vm.warp(hub.jobExpiresAt(jobId));
        hub.markExpired(jobId);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Expired), "the job expired");
        assertEq(accessVault.deepRemaining(requester), 4, "and the quota unit came back");
    }

    /// @notice The order a third party submits two disagreeing positions in cannot change the
    ///         outcome: the same two signatures leave the job in the same state either way.
    /// @dev A relay can only ever submit the position an auditor actually signed, and adding a
    ///      signature never increases `bestAgreement + silent`, so no ordering can tip a job into a
    ///      state a different ordering would have avoided.
    function test_theOrderOfTwoDisagreeingPositionsDoesNotMatter() public {
        address[] memory signers = _signerSet(2);
        AuditResult memory first = _result();
        AuditResult memory second = _result();
        second.overallTrust = 9;
        second.reportHash = keccak256("the other reading");

        uint256 forwards = _openJob();
        _attestAlone(forwards, first, _keyOf(signers[0]), _hash(forwards, first));
        _attestAlone(forwards, second, _keyOf(signers[1]), _hash(forwards, second));

        uint256 backwards = _openJob();
        _attestAlone(backwards, second, _keyOf(signers[1]), _hash(backwards, second));
        _attestAlone(backwards, first, _keyOf(signers[0]), _hash(backwards, first));

        Job memory forwardsJob = hub.getJob(forwards);
        Job memory backwardsJob = hub.getJob(backwards);
        assertEq(uint8(backwardsJob.status), uint8(forwardsJob.status), "the same status");
        assertEq(uint8(forwardsJob.status), uint8(JobStatus.Requested), "which is still open");
        assertEq(backwardsJob.attestations, forwardsJob.attestations, "the same number of positions");
        assertEq(hub.bestAgreement(backwards), hub.bestAgreement(forwards), "the same best agreement");
        assertEq(
            hub.digestVotes(backwards, _hash(backwards, first)),
            hub.digestVotes(forwards, _hash(forwards, first)),
            "the same votes for the first reading"
        );
        assertEq(
            hub.digestVotes(backwards, _hash(backwards, second)),
            hub.digestVotes(forwards, _hash(forwards, second)),
            "the same votes for the second reading"
        );
        assertEq(reportRegistry.reportCount(), 0, "and neither ordering recorded anything");
    }

    /// @notice A job that is not about to finalise costs no membership re-check at all: the active
    ///         filter runs only on the finalising path.
    function test_theActiveFilterOnlyRunsWhenAPositionCouldFinalise() public {
        uint256 jobId = _openJob();
        address[] memory signers = _signerSet(1);
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 1);

        // One signature under a threshold of two: the only membership check is the one that
        // authenticates the signer itself.
        vm.expectCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.isAuditor, (signers[0])), 1);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, signatures);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "and the job did not finalise");
    }

    // -------------------------------------------------------------------------------------------
    // Expiry
    // -------------------------------------------------------------------------------------------

    /// @notice A job nobody answered expires only after the service level, and gives the unit back.
    function test_markExpiredRevertsBeforeTheSlaAndRestoresQuotaAfterIt() public {
        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);
        assertEq(accessVault.forensicRemaining(requester), 0, "the forensic unit is spent");

        uint64 expiresAt = hub.jobExpiresAt(jobId);
        vm.warp(expiresAt - 1);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.NotExpired.selector, jobId, expiresAt));
        hub.markExpired(jobId);
        assertEq(accessVault.forensicRemaining(requester), 0, "and it stays spent until the SLA elapses");

        vm.warp(expiresAt);
        hub.markExpired(jobId);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Expired), "the job expired");
        assertEq(accessVault.forensicRemaining(requester), 1, "the unit came back");
        assertEq(reportRegistry.reportCount(), 0, "and nothing was recorded");

        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.WrongJobStatus.selector, jobId, JobStatus.Expired));
        hub.markExpired(jobId);
        assertEq(accessVault.forensicRemaining(requester), 1, "so the unit cannot be restored twice");
    }

    /// @notice R22 — a job's deadline is the SLA in force when it was requested, and a later
    ///         governance change in either direction must not move it.
    /// @dev Before this, markExpired and jobExpiresAt both recomputed `requestedAt + slaSeconds`
    ///      against the live global, so a `setSla` call while a job was pending silently moved
    ///      every pending job's deadline away from the one its own `AuditRequested` event already
    ///      promised. This checks both directions: SLA raised, and SLA lowered.
    function test_changingTheSlaDoesNotMoveAPendingJobsOwnDeadline() public {
        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);
        uint64 originalExpiry = hub.jobExpiresAt(jobId);
        assertEq(originalExpiry, uint64(block.timestamp) + 6 hours, "the default SLA is six hours");

        // Governance raises the SLA. The job's own deadline must not move out with it.
        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (12 hours)));
        assertEq(hub.jobExpiresAt(jobId), originalExpiry, "raising the SLA must not push this job's deadline back");

        vm.warp(originalExpiry);
        hub.markExpired(jobId);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Expired), "it expires on its own original schedule");
        assertEq(accessVault.forensicRemaining(requester), 1, "and the quota unit came back");
    }

    /// @notice The other direction: governance lowering the SLA must not make a job that was
    ///         requested under a longer one expire early.
    /// @dev Timelocked governance calls warp 48 hours forward in `_governanceCall` (the real
    ///      timelock delay), which alone exceeds this job's six-hour SLA — so "shortly after the
    ///      change" cannot mean "still within the original window" in wall-clock terms here. What
    ///      is checked instead, and what actually matters, is the deadline **value** itself: it
    ///      must still be the original one both immediately after the change and at the moment
    ///      `markExpired` is actually called, regardless of what the live `slaSeconds` has become.
    function test_loweringTheSlaDoesNotExpireAPendingJobEarly() public {
        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);
        uint64 originalExpiry = hub.jobExpiresAt(jobId);

        // Governance lowers the SLA to its floor. A job requested under the six-hour default must
        // still run the six hours it was promised, not the new one-hour floor.
        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (1 hours)));
        assertEq(hub.jobExpiresAt(jobId), originalExpiry, "lowering the SLA must not pull this job's deadline forward");

        vm.warp(originalExpiry - 1);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.NotExpired.selector, jobId, originalExpiry));
        hub.markExpired(jobId);
        assertEq(accessVault.forensicRemaining(requester), 0, "the unit stays spent, the job is not expired yet");

        vm.warp(originalExpiry);
        hub.markExpired(jobId);
        assertEq(accessVault.forensicRemaining(requester), 1, "and restores exactly on its own original schedule");
    }

    /// @notice A job requested after the SLA change runs under the new value, not the old one — the
    ///         freeze is per job at the moment of its own request, nothing more.
    function test_aJobRequestedAfterAnSlaChangeUsesTheNewValue() public {
        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (2 days)));

        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);

        assertEq(
            hub.jobExpiresAt(jobId), uint64(block.timestamp) + 2 days, "it takes the SLA in force at its own request"
        );
    }

    /// @notice An expired job can no longer be settled.
    /// @notice The deadline is hard: a result is accepted up to the last second before it and
    ///         refused from the deadline on, which is exactly when `markExpired` opens.
    /// @dev Before this the two overlapped from the deadline onwards, and whichever transaction
    ///      landed first decided whether a late result spent the requester's unit or the missed
    ///      deadline returned it.
    function test_theDeadlineSplitsAttestAndMarkExpiredWithNoOverlap() public {
        uint256 jobId = _openJob();
        uint64 expiresAt = hub.jobExpiresAt(jobId);
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 2);

        // One second before: only a result is possible.
        vm.warp(expiresAt - 1);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.NotExpired.selector, jobId, expiresAt));
        hub.markExpired(jobId);
        uint256 snapshot = vm.snapshotState();
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, signatures);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "accepted in the last second");
        vm.revertToState(snapshot);

        // At the deadline: only expiry is possible.
        vm.warp(expiresAt);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.JobExpired.selector, jobId, expiresAt));
        hub.attest(jobId, result, signatures);

        // And after it.
        vm.warp(expiresAt + 1);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.JobExpired.selector, jobId, expiresAt));
        hub.attest(jobId, result, signatures);

        hub.markExpired(jobId);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Expired), "the missed deadline expires the job");
        assertEq(reportRegistry.reportCount(), 0, "and the late result was never recorded");
    }

    /// @notice A late result cannot spend the requester's unit: the unit always comes back.
    function test_aLateResultNeverSpendsTheQuotaUnit() public {
        vm.prank(requester);
        uint256 jobId = hub.requestAudit(chainKey, assetId, TIER_FORENSIC, KIND_INDEPENDENT);
        assertEq(accessVault.forensicRemaining(requester), 0, "spent on request");

        vm.warp(hub.jobExpiresAt(jobId));
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert();
        hub.attest(jobId, result, signatures);

        hub.markExpired(jobId);
        assertEq(accessVault.forensicRemaining(requester), 1, "returned, whatever order the two calls came in");
    }

    /// @notice The deadline a job is held to is the one it was promised, not the current SLA.
    function test_theHardDeadlineIsTheJobsOwnNotTheCurrentSla() public {
        uint256 jobId = _openJob();
        uint64 promised = hub.jobExpiresAt(jobId);
        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (30 days)));
        assertEq(hub.jobExpiresAt(jobId), promised, "raising the SLA does not extend a pending job");

        vm.warp(promised);
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.JobExpired.selector, jobId, promised));
        hub.attest(jobId, result, signatures);
    }

    function test_anExpiredJobCannotBeFulfilled() public {
        uint256 jobId = _openJob();
        vm.warp(vm.getBlockTimestamp() + hub.slaSeconds());
        hub.markExpired(jobId);

        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 2);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.WrongJobStatus.selector, jobId, JobStatus.Expired));
        hub.attest(jobId, result, signatures);
    }

    // -------------------------------------------------------------------------------------------
    // Watchdog reports
    // -------------------------------------------------------------------------------------------

    /// @notice An unsolicited report needs no job, no requester and no access period.
    function test_watchdogReportAppendsWithoutAJob() public {
        AuditResult memory result = _result();
        bytes[] memory hoistedSignatures10 = _sign(0, result, 2);
        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.publishWatchdogReport(result, hoistedSignatures10);

        ReportRecord memory record = reportRegistry.getReport(reportId);
        assertEq(record.jobId, 0, "no job settled it");
        assertEq(record.requester, address(0), "nobody requested it");
        assertEq(record.declaredRequesterKind, KIND_UNKNOWN, "and nobody declared anything");
        assertEq(record.tier, 0, "no access tier was consumed");
        assertEq(record.result.reportHash, result.reportHash, "the signed report is the recorded one");
        assertEq(hub.jobCount(), 0, "no job was created");
        assertEq(accessVault.deepRemaining(requester), 4, "and nobody's allowance was touched");
    }

    /// @notice A watchdog report needs a sorted, non-duplicated, quorum-sized signature set.
    function test_watchdogReportNeedsSortedQuorumSignatures() public {
        AuditResult memory result = _result();
        bytes32 digest = hub.hashResult(0, result);
        address[] memory signers = _signerSet(2);
        bytes[] memory tooFew = _sign(0, result, 1);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.QuorumNotMet.selector, uint256(1), uint256(2)));
        hub.publishWatchdogReport(result, tooFew);

        bytes[] memory reversed = new bytes[](2);
        reversed[0] = _signDigest(_keyOf(signers[1]), digest);
        reversed[1] = _signDigest(_keyOf(signers[0]), digest);
        vm.prank(auditorAddresses[0]);
        vm.expectPartialRevert(KAY9AuditHub.SignersNotSorted.selector);
        hub.publishWatchdogReport(result, reversed);

        bytes[] memory duplicated = new bytes[](2);
        duplicated[0] = _signDigest(_keyOf(signers[0]), digest);
        duplicated[1] = duplicated[0];
        vm.prank(auditorAddresses[0]);
        vm.expectPartialRevert(KAY9AuditHub.SignersNotSorted.selector);
        hub.publishWatchdogReport(result, duplicated);

        assertEq(reportRegistry.reportCount(), 0, "none of those reached the log");
    }

    /// @notice The same signed watchdog report cannot be committed twice.
    function test_watchdogReportCannotBeCommittedTwice() public {
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(0, result, 2);
        vm.prank(auditorAddresses[0]);
        hub.publishWatchdogReport(result, signatures);

        bytes32 digest = hub.hashResult(0, result);
        assertTrue(hub.watchdogReportCommitted(digest), "the digest is remembered");

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.DuplicateWatchdogReport.selector, digest));
        hub.publishWatchdogReport(result, signatures);
        assertEq(reportRegistry.reportCount(), 1, "the log did not grow");
    }

    // -------------------------------------------------------------------------------------------
    // The log is never overwritten
    // -------------------------------------------------------------------------------------------

    /// @notice Three reports about one asset are three records, in order, with the third as latest.
    function test_reportHistoryIsNeverOverwritten() public {
        uint8[3] memory scores = [uint8(10), uint8(55), uint8(90)];
        uint256[] memory reportIds = new uint256[](3);

        for (uint256 i = 0; i < 3; ++i) {
            _advance(60);
            AuditResult memory result = _result();
            result.overallTrust = scores[i];
            result.analyzedAt = uint64(vm.getBlockTimestamp());
            result.reportHash = keccak256(abi.encode("re-audit", i));
            bytes[] memory hoistedSignatures11 = _sign(0, result, 2);
            vm.prank(auditorAddresses[0]);
            reportIds[i] = hub.publishWatchdogReport(result, hoistedSignatures11);
        }

        assertEq(reportRegistry.reportCount(), 3, "three records, not one rewritten three times");
        assertEq(reportRegistry.historyCount(chainKey, assetId), 3, "all three belong to the asset");

        uint256[] memory ids = reportRegistry.history(chainKey, assetId, 0, type(uint256).max);
        assertEq(ids.length, 3, "history returns all three");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(ids[i], reportIds[i], "in commitment order");
            assertEq(reportRegistry.getReport(ids[i]).result.overallTrust, scores[i], "with its own score");
        }

        (bool exists, ReportRecord memory newest) = reportRegistry.latest(chainKey, assetId);
        assertTrue(exists, "the asset has a latest report");
        assertEq(newest.result.overallTrust, scores[2], "and it is the third one");
        (,, uint8 summaryRisk,,,) = reportRegistry.latestSummary(chainKey, assetId);
        assertEq(summaryRisk, scores[2], "the summary agrees");
    }

    // -------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------

    /// @notice Only the timelock changes the service level or the pause flag, within bounds.
    function test_governanceIsTimelocked() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setSla(1 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        hub.setRequestsPaused(true);

        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (2 days)));
        assertEq(hub.slaSeconds(), 2 days, "the service level was set");

        // Both bounds are read before the cheatcode is armed, because an intervening view call
        // would consume the expectation.
        uint64 belowMin = hub.MIN_SLA() - 1;
        uint64 aboveMax = hub.MAX_SLA() + 1;

        vm.startPrank(address(timelock));
        vm.expectRevert(KAY9AuditHub.InvalidSla.selector);
        hub.setSla(belowMin);
        vm.expectRevert(KAY9AuditHub.InvalidSla.selector);
        hub.setSla(aboveMax);
        vm.stopPrank();
    }

    /// @notice The auditor set enforces its own bounds.
    function test_auditorRegistryRules() public {
        assertEq(auditorRegistry.auditorCount(), 3, "three auditors");
        assertEq(auditorRegistry.threshold(), 2, "and a threshold of two");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        auditorRegistry.addAuditor(makeAddr("intruder"));

        // Every argument is read before the expectRevert cheatcode is armed, because an intervening
        // view call would consume the expectation.
        address existing = auditorRegistry.auditors()[0];

        vm.startPrank(address(timelock));
        vm.expectRevert(KAY9AuditorRegistry.ZeroAuditor.selector);
        auditorRegistry.addAuditor(address(0));
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditorRegistry.AlreadyAuditor.selector, existing));
        auditorRegistry.addAuditor(existing);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditorRegistry.InvalidThreshold.selector, uint8(4), 3));
        auditorRegistry.setThreshold(4);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditorRegistry.InvalidThreshold.selector, uint8(0), 3));
        auditorRegistry.setThreshold(0);

        // Removing an auditor below the threshold halts the registry rather than lowering it.
        auditorRegistry.setThreshold(3);
        auditorRegistry.removeAuditor(existing);
        vm.stopPrank();
        assertFalse(auditorRegistry.isAuditor(existing), "the auditor is gone");
        assertEq(auditorRegistry.auditorCount(), 2, "two remain");
        assertEq(auditorRegistry.threshold(), 0, "halted, not lowered");
        assertTrue(auditorRegistry.isHalted(), "until the owner names a new quorum");
    }

    /// @notice The hub refuses to be wired to a vault that numbers the tiers differently, because
    ///         a silent disagreement would sell one tier and consume another.
    function test_constructorRejectsAVaultWhoseTiersDisagree() public {
        MockTierVault bothWrong = new MockTierVault(7, 8);
        vm.expectRevert(KAY9AuditHub.TierMismatch.selector);
        new KAY9AuditHub(
            address(timelock), address(reportRegistry), auditorRegistry, KAY9AccessVault(address(bothWrong))
        );

        MockTierVault forensicWrong = new MockTierVault(TIER_DEEP, 9);
        vm.expectRevert(KAY9AuditHub.TierMismatch.selector);
        new KAY9AuditHub(
            address(timelock), address(reportRegistry), auditorRegistry, KAY9AccessVault(address(forensicWrong))
        );

        MockTierVault deepWrong = new MockTierVault(6, TIER_FORENSIC);
        vm.expectRevert(KAY9AuditHub.TierMismatch.selector);
        new KAY9AuditHub(
            address(timelock), address(reportRegistry), auditorRegistry, KAY9AccessVault(address(deepWrong))
        );

        assertEq(hub.TIER_DEEP(), accessVault.TIER_DEEP(), "the deployed pair agrees about the deep tier");
        assertEq(hub.TIER_FORENSIC(), accessVault.TIER_FORENSIC(), "and about the forensic tier");
    }

    /// @notice Asset keys and identifiers follow the documented convention.
    function test_assetIdentity() public view {
        assertEq(reportRegistry.assetKey(chainKey, assetId), keccak256(abi.encode(chainKey, assetId)), "asset key");
        assertEq(
            reportRegistry.evmAssetId(0x1234567890AbcdEF1234567890aBcdef12345678),
            bytes32(uint256(uint160(0x1234567890AbcdEF1234567890aBcdef12345678))),
            "evm asset id"
        );
        assertEq(reportRegistry.CHAIN_ROBINHOOD(), keccak256("eip155:4663"), "robinhood chain key");
        assertEq(reportRegistry.CHAIN_BNB(), keccak256("eip155:56"), "bnb chain key");
        assertEq(reportRegistry.CHAIN_SOLANA(), keccak256("solana:mainnet"), "solana chain key");
    }

    // -------------------------------------------------------------------------------------------
    // Who may submit
    // -------------------------------------------------------------------------------------------

    /// @notice Only an active auditor may land signatures, because the one unsigned field of a
    ///         result — `reportURI` — is chosen by whoever lands the finalising transaction.
    /// @dev The signatures are valid for the poisoned result too, since the URI is not in the
    ///      digest. That is precisely the threat: a stranger holding two honest signatures from the
    ///      relay could otherwise write a pointer of their choosing into the permanent record.
    function test_onlyAnActiveAuditorMaySubmitSignatures() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(jobId, result, 2);

        AuditResult memory poisoned = result;
        poisoned.reportURI = "https://not-the-report.example";

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.SubmitterNotAnAuditor.selector, outsider));
        hub.attest(jobId, poisoned, signatures);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "nothing landed");

        // The timelock is governance, not an auditor, and gets the same answer.
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.SubmitterNotAnAuditor.selector, address(timelock)));
        hub.attest(jobId, poisoned, signatures);

        // An auditor carrying a peer's agreeing signature is the ordinary path, and the record
        // carries the URI that auditor submitted.
        address[] memory signers = _signerSet(2);
        vm.prank(signers[1]);
        uint256 reportId = hub.attest(jobId, result, signatures);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the auditor finalised it");
        assertEq(reportRegistry.getReport(reportId).result.reportURI, result.reportURI, "the honest URI");

        // The same rule covers the unsolicited path.
        vm.warp(block.timestamp + 1);
        AuditResult memory watchdog = _result();
        bytes[] memory watchdogSignatures = _sign(0, watchdog, 2);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.SubmitterNotAnAuditor.selector, outsider));
        hub.publishWatchdogReport(watchdog, watchdogSignatures);

        vm.prank(signers[0]);
        hub.publishWatchdogReport(watchdog, watchdogSignatures);
        assertEq(reportRegistry.reportCount(), 2, "the auditor's submission landed");
    }

    /// @notice An auditor removed through the timelock loses the right to submit along with the
    ///         right to sign, so a compromised key cannot even relay honest signatures.
    function test_aRemovedAuditorCannotSubmitEither() public {
        uint256 jobId = _openJob();
        AuditResult memory result = _result();
        address[] memory sorted = _sortedAuditors();
        bytes[] memory signatures = _sign(jobId, result, 2);

        address removed = sorted[2];
        vm.prank(address(timelock));
        auditorRegistry.removeAuditor(removed);

        vm.prank(removed);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.SubmitterNotAnAuditor.selector, removed));
        hub.attest(jobId, result, signatures);

        vm.prank(sorted[0]);
        uint256 reportId = hub.attest(jobId, result, signatures);
        assertGt(reportId + 1, 0, "the remaining auditors still finalise");
    }

    /// @notice `markExpired` needs no auditor: nothing reaches the log through it.
    function test_anyoneMayStillExpireAJob() public {
        uint256 jobId = _openJob();
        vm.warp(hub.jobExpiresAt(jobId));
        vm.prank(outsider);
        hub.markExpired(jobId);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Expired), "expired by a stranger");
    }

    // -------------------------------------------------------------------------------------------
    // Hub migration
    // -------------------------------------------------------------------------------------------

    /// @notice A job that is pending when governance points the vault at a new hub still expires
    ///         and disputes on the old one, and its unit still comes back.
    /// @dev Before the vault learned to remember a retired hub, `restore` reverted `NotTheAuditHub`
    ///      for the old hub, which made `markExpired` and the disputing `attest` revert forever and
    ///      left the job open with its unit stranded.
    function test_aJobPendingAcrossAHubMigrationStillExpiresAndRefunds() public {
        uint256 expiring = _openJob();
        uint256 disputing = _openJob();
        assertEq(accessVault.deepRemaining(requester), 2, "two units spent");

        address hubV2 = makeAddr("hubV2");
        vm.prank(address(timelock));
        accessVault.setAuditHub(hubV2);
        assertTrue(accessVault.isRetiredHub(address(hub)), "the old hub is retired, not forgotten");

        // The old hub cannot spend anything any more.
        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, address(hub)));
        hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);

        // But its pending jobs still reach their terminal states and hand their units back. The
        // dispute first, while results are still accepted; the expiry once the deadline arrives.
        address[] memory signers = _signerSet(3);
        for (uint256 i = 0; i < 3; ++i) {
            AuditResult memory result = _result();
            result.reportHash = keccak256(abi.encode("migration dissent", i));
            _attestAlone(disputing, result, _keyOf(signers[i]), _hash(disputing, result));
        }
        assertEq(uint8(hub.getJob(disputing).status), uint8(JobStatus.Disputed));
        assertEq(accessVault.deepRemaining(requester), 3, "the disputed unit came back");

        vm.warp(hub.jobExpiresAt(expiring));
        hub.markExpired(expiring);
        assertEq(uint8(hub.getJob(expiring).status), uint8(JobStatus.Expired));
        assertEq(accessVault.deepRemaining(requester), 4, "the expired unit came back too");
    }

    // -------------------------------------------------------------------------------------------
    // Watchdog-stack review fixes (2026-09-25)
    // -------------------------------------------------------------------------------------------

    /// @notice A position that meets a lowered threshold can be settled, though no auditor can
    ///         add a vote to it.
    function test_aLoweredThresholdIsSettledByFinalizeAgreed() public {
        _outliveGovernance();
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.setThreshold, (3)));
        address[] memory signers = _signerSet(3);
        uint256 jobId = _openJob();

        AuditResult memory x = _result();
        _attestAlone(jobId, x, _keyOf(signers[0]), _hash(jobId, x));
        _attestAlone(jobId, x, _keyOf(signers[1]), _hash(jobId, x));
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "two of three is not a quorum yet");

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.setThreshold, (2)));

        vm.prank(auditorAddresses[0]);
        uint256 reportId = hub.finalizeAgreed(jobId, x);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Fulfilled), "the agreed position settles");
        assertEq(reportRegistry.getReport(reportId).signers.length, 2, "signed by the two who agreed");
    }

    /// @notice `finalizeAgreed` refuses a position below the quorum, and a stranger.
    function test_finalizeAgreedNeedsAQuorumAndAnAuditor() public {
        address[] memory signers = _signerSet(3);
        uint256 jobId = _openJob();
        AuditResult memory x = _result();
        _attestAlone(jobId, x, _keyOf(signers[0]), _hash(jobId, x));

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.QuorumNotMet.selector, uint256(1), uint256(2)));
        hub.finalizeAgreed(jobId, x);

        vm.prank(requester);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.SubmitterNotAnAuditor.selector, requester));
        hub.finalizeAgreed(jobId, x);
    }

    /// @notice When the only agreeing auditors are removed and the rest split, the job disputes.
    /// @dev The scenario from the watchdog review: five auditors at threshold three, two agree,
    ///      both are removed, and the remaining three vote so that no position can reach three.
    ///      Counting the removed votes, the old check saw an agreement of two plus one silent
    ///      auditor and left the job open.
    function test_rotationDisputesWhenOnlyRemovedAuditorsAgreed() public {
        uint256 dKey = 0xD00D;
        uint256 eKey = 0xE00E;
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.addAuditor, (vm.addr(dKey))));
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.addAuditor, (vm.addr(eKey))));
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.setThreshold, (3)));
        _outliveGovernance();

        address[] memory signers = _signerSet(3);
        uint256 jobId = _openJob();

        AuditResult memory x = _result();
        x.reportHash = keccak256("x");
        _attestAlone(jobId, x, _keyOf(signers[0]), _hash(jobId, x));
        _attestAlone(jobId, x, _keyOf(signers[1]), _hash(jobId, x));

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[0])));
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (signers[1])));

        AuditResult memory y = _result();
        y.reportHash = keccak256("y");
        bytes[] memory one = new bytes[](1);
        one[0] = _signDigest(_keyOf(signers[2]), _hash(jobId, y));
        vm.prank(signers[2]);
        hub.attest(jobId, y, one);
        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Requested), "two silent auditors could still agree");

        AuditResult memory z = _result();
        z.reportHash = keccak256("z");
        one[0] = _signDigest(dKey, _hash(jobId, z));
        vm.prank(signers[2]);
        hub.attest(jobId, z, one);

        assertEq(
            uint8(hub.getJob(jobId).status),
            uint8(JobStatus.Disputed),
            "no position can reach three active votes, so the job disputes"
        );
    }

    /// @notice An older signed report cannot be published after a newer one to become `latest`.
    function test_aStaleWatchdogReportCannotBecomeLatest() public {
        vm.warp(block.timestamp + 1 days);
        AuditResult memory older = _result();
        older.analyzedAt = uint64(block.timestamp - 1 hours);
        older.overallTrust = 90;
        older.reportHash = keccak256("older");
        AuditResult memory newer = _result();
        newer.overallTrust = 10;
        newer.reportHash = keccak256("newer");

        bytes[] memory newerSignatures = _sign(0, newer, 2);
        bytes[] memory olderSignatures = _sign(0, older, 2);

        vm.prank(auditorAddresses[0]);
        hub.publishWatchdogReport(newer, newerSignatures);

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(
            abi.encodeWithSelector(KAY9AuditHub.StaleWatchdogReport.selector, older.analyzedAt, newer.analyzedAt)
        );
        hub.publishWatchdogReport(older, olderSignatures);

        (, uint64 latestAnalyzedAt) = reportRegistry.latestAnalyzedAt(chainKey, assetId);
        assertEq(latestAnalyzedAt, newer.analyzedAt, "the newer report stays latest");
    }

    /// @notice A result analysed in the future, or with a score above 100, is refused.
    function test_aFutureOrOutOfRangeResultIsRefused() public {
        AuditResult memory future = _result();
        future.analyzedAt = uint64(block.timestamp + 1);
        bytes[] memory futureSignatures = _sign(0, future, 2);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.AnalyzedInFuture.selector, future.analyzedAt));
        hub.publishWatchdogReport(future, futureSignatures);

        AuditResult memory tooHigh = _result();
        tooHigh.botTrust = 101;
        bytes[] memory tooHighSignatures = _sign(0, tooHigh, 2);
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(KAY9AuditHub.ScoreOutOfRange.selector);
        hub.publishWatchdogReport(tooHigh, tooHighSignatures);
    }

    /// @notice Ownership of the hub cannot be renounced.
    function test_hubRenounceIsDisabled() public {
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AuditHub.RenounceDisabled.selector);
        hub.renounceOwnership();
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Gives every job opened after this a deadline that outlives a timelock round.
    /// @dev Governance takes 48 hours, the default SLA is six, and a result is refused from the
    ///      deadline on. A test about what a rotation does to a pending job therefore has to
    ///      promise that job longer than a rotation takes, or the job is simply over by the time
    ///      the rotation lands - which is the honest outcome under the default, and a different test.
    function _outliveGovernance() internal {
        // Seven days: longer than two timelock rounds, shorter than the requester's access period,
        // so a unit handed back at the deadline still lands in a live period.
        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (7 days)));
    }

    /// @notice Opens a deep job against the requester's forensic period.
    /// @return jobId The new job id.
    function _openJob() internal returns (uint256 jobId) {
        vm.prank(requester);
        jobId = hub.requestAudit(chainKey, assetId, TIER_DEEP, KIND_INDEPENDENT);
    }

    /// @notice Opens a job and drives it to Disputed with three mutually different results.
    /// @return jobId The disputed job id.
    function _disputedJob() internal returns (uint256 jobId) {
        jobId = _openJob();
        address[] memory signers = _signerSet(3);
        for (uint256 i = 0; i < 3; ++i) {
            AuditResult memory result = _result();
            result.overallTrust = uint8(10 + i * 30);
            result.reportHash = keccak256(abi.encode("disagreement", i));
            bytes[] memory signature = new bytes[](1);
            signature[0] = _signDigest(_keyOf(signers[i]), _hash(jobId, result));
            vm.prank(auditorAddresses[0]);
            hub.attest(jobId, result, signature);
        }
    }

    /// @notice Records one auditor's position on a job, on its own.
    /// @param jobId The job.
    /// @param result The result being attested.
    /// @param key The signing key.
    /// @param digest The digest of that result for that job.
    function _attestAlone(uint256 jobId, AuditResult memory result, uint256 key, bytes32 digest) internal {
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signDigest(key, digest);
        vm.prank(auditorAddresses[0]);
        hub.attest(jobId, result, signatures);
    }

    /// @notice The auditor set plus one extra member, in ascending address order, with their keys.
    /// @param extraKey The extra member's private key.
    /// @return members The four addresses, ascending.
    /// @return keys The matching private keys, in the same order.
    function _sortedMembership(uint256 extraKey)
        internal
        view
        returns (address[] memory members, uint256[] memory keys)
    {
        members = new address[](4);
        keys = new uint256[](4);
        for (uint256 i = 0; i < 3; ++i) {
            members[i] = auditorAddresses[i];
            keys[i] = auditorKeys[i];
        }
        members[3] = vm.addr(extraKey);
        keys[3] = extraKey;

        for (uint256 i = 0; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                if (members[j] < members[i]) {
                    (members[i], members[j]) = (members[j], members[i]);
                    (keys[i], keys[j]) = (keys[j], keys[i]);
                }
            }
        }
    }

    /// @notice A representative audit result.
    /// @return result The result.
    function _result() internal view returns (AuditResult memory result) {
        result = AuditResult({
            chainKey: chainKey,
            assetId: assetId,
            overallTrust: 42,
            contractTrust: 10,
            liquidityTrust: 20,
            holderTrust: 30,
            insiderTrust: 40,
            creatorTrust: 50,
            tradingTrust: 60,
            botTrust: 70,
            flags: 0x1234,
            engineVersion: 1,
            analyzedAt: uint64(vm.getBlockTimestamp()),
            reportHash: keccak256("report"),
            reportURI: "ipfs://bafybeigdyrztktx5b5m2y4sog6f6cnbxvhc7g4rl6vzqxk2xk6xk6xk6xk"
        });
    }

    /// @notice Signs a result with the lowest `count` auditor addresses, in ascending order.
    /// @param jobId The job id bound into the digest.
    /// @param result The result to sign.
    /// @param count The number of signatures.
    /// @return signatures The signatures.
    function _sign(uint256 jobId, AuditResult memory result, uint256 count)
        internal
        view
        returns (bytes[] memory signatures)
    {
        bytes32 digest = _hash(jobId, result);
        address[] memory signers = _signerSet(count);
        signatures = new bytes[](count);
        for (uint256 i = 0; i < count; ++i) {
            signatures[i] = _signDigest(_keyOf(signers[i]), digest);
        }
    }

    /// @notice The lowest `count` auditor addresses, in ascending order.
    /// @param count The number of addresses.
    /// @return set The addresses.
    function _signerSet(uint256 count) internal view returns (address[] memory set) {
        address[] memory sorted = _sortedAuditors();
        set = new address[](count);
        for (uint256 i = 0; i < count; ++i) {
            set[i] = sorted[i];
        }
    }

    /// @notice The EIP-712 digest for a result held in memory.
    /// @param jobId The job id.
    /// @param result The result.
    /// @return The digest.
    function _hash(uint256 jobId, AuditResult memory result) internal view returns (bytes32) {
        return this.callHashResult(jobId, result);
    }

    /// @notice Bridges a memory result into the hub's calldata-typed hashing function.
    /// @param jobId The job id.
    /// @param result The result.
    /// @return The digest.
    function callHashResult(uint256 jobId, AuditResult calldata result) external view returns (bytes32) {
        return hub.hashResult(jobId, result);
    }

    /// @notice Bridges a memory result into another hub's calldata-typed hashing function.
    /// @param target The hub whose domain the digest binds to.
    /// @param jobId The job id.
    /// @param result The result.
    /// @return The digest.
    function callHashResultOn(KAY9AuditHub target, uint256 jobId, AuditResult calldata result)
        external
        view
        returns (bytes32)
    {
        return target.hashResult(jobId, result);
    }

    /// @notice Produces a 65-byte signature over a digest.
    /// @param key The signing key.
    /// @param digest The digest.
    /// @return The signature.
    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
