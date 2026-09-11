// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {KAY9Token} from "../../src/KAY9Token.sol";
import {KAY9TeamVesting} from "../../src/KAY9TeamVesting.sol";
import {KAY9AccessVault} from "../../src/KAY9AccessVault.sol";
import {KAY9AuditHub, JobStatus, Job} from "../../src/KAY9AuditHub.sol";
import {KAY9Registry, AuditResult} from "../../src/KAY9Registry.sol";

/// @title Kay9Handler
/// @notice Drives the protocol through the actions an outsider can take, so the invariant runs
///         exercise realistic sequences rather than random calldata.
/// @dev The paid path is gone: an actor locks KAY9 for an access period, spends quota on requests,
///      renews or unlocks when the period ends, and auditors either agree or contradict each other.
///      Every action is wrapped in try/catch because the sequences are random and most orderings
///      are legitimately refused.
contract Kay9Handler is CommonBase, StdCheats, StdUtils {
    /// @notice The KAY9 token.
    KAY9Token public immutable token;

    /// @notice The team vesting contract.
    KAY9TeamVesting public immutable vesting;

    /// @notice The access lock.
    KAY9AccessVault public immutable accessVault;

    /// @notice The audit hub.
    KAY9AuditHub public immutable hub;

    /// @notice The report log.
    KAY9Registry public immutable registry;

    /// @notice The job ids the handler has opened.
    uint256[] public jobIds;

    /// @notice The auditor keys, in ascending signer-address order.
    uint256[] public auditorKeys;

    /// @notice A pool of actors funded with KAY9.
    address[] public actors;

    /// @notice How many access periods were opened.
    uint256 public locks;

    /// @notice How many access periods were renewed.
    uint256 public renewals;

    /// @notice How many access periods were unlocked.
    uint256 public unlocks;

    /// @notice How many periods were raised from deep to forensic.
    uint256 public upgrades;

    /// @notice How many requests were accepted.
    uint256 public opened;

    /// @notice How many jobs were finalised.
    uint256 public fulfilled;

    /// @notice How many jobs ended in disagreement.
    uint256 public disputed;

    /// @notice How many jobs timed out.
    uint256 public expired;

    /// @notice How many locks were refused, usually because the oracle was unavailable.
    uint256 public lockFailures;

    /// @notice How many requests were refused, usually for want of quota.
    uint256 public requestFailures;

    /// @notice Binds the handler to the deployment.
    /// @param token_ The KAY9 token.
    /// @param vesting_ The team vesting contract.
    /// @param accessVault_ The access lock.
    /// @param hub_ The audit hub.
    /// @param registry_ The report log.
    /// @param sortedAuditorKeys The auditor keys, ordered by ascending signer address.
    /// @param actors_ The funded actors, which have already approved the vault.
    constructor(
        KAY9Token token_,
        KAY9TeamVesting vesting_,
        KAY9AccessVault accessVault_,
        KAY9AuditHub hub_,
        KAY9Registry registry_,
        uint256[] memory sortedAuditorKeys,
        address[] memory actors_
    ) {
        token = token_;
        vesting = vesting_;
        accessVault = accessVault_;
        hub = hub_;
        registry = registry_;
        auditorKeys = sortedAuditorKeys;
        actors = actors_;
    }

    /// @notice The number of jobs the handler has opened.
    /// @return The job count.
    function jobCount() external view returns (uint256) {
        return jobIds.length;
    }

    /// @notice The number of actors the handler drives.
    /// @return The actor count.
    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // -------------------------------------------------------------------------------------------
    // Access
    // -------------------------------------------------------------------------------------------

    /// @notice Opens an access period for an actor.
    /// @param actorSeed Selects the actor.
    /// @param tierSeed Selects the tier.
    function lockAccess(uint256 actorSeed, uint256 tierSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint8 tier = uint8(bound(tierSeed, 1, 2));
        vm.prank(actor);
        try accessVault.lock(tier, type(uint256).max) {
            ++locks;
        } catch {
            ++lockFailures;
        }
    }

    /// @notice Replaces an expired period with a fresh one.
    /// @param actorSeed Selects the actor.
    /// @param tierSeed Selects the tier.
    function renewAccess(uint256 actorSeed, uint256 tierSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint8 tier = uint8(bound(tierSeed, 1, 2));
        vm.prank(actor);
        try accessVault.renew(tier, type(uint256).max) {
            ++renewals;
        } catch {}
    }

    /// @notice Raises a live deep period to forensic.
    /// @param actorSeed Selects the actor.
    function upgradeAccess(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try accessVault.upgrade(type(uint256).max) {
            ++upgrades;
        } catch {}
    }

    /// @notice Withdraws an expired period's principal.
    /// @param actorSeed Selects the actor.
    function unlockAccess(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        vm.prank(actor);
        try accessVault.unlock() {
            ++unlocks;
        } catch {}
    }

    // -------------------------------------------------------------------------------------------
    // Jobs
    // -------------------------------------------------------------------------------------------

    /// @notice Requests an audit, which spends a quota unit when the actor has one.
    /// @param actorSeed Selects the requester.
    /// @param assetSeed Selects the audited asset.
    /// @param tierSeed Selects the tier.
    /// @param kindSeed Selects the declared requester kind.
    function requestAudit(uint256 actorSeed, uint256 assetSeed, uint256 tierSeed, uint256 kindSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint8 tier = uint8(bound(tierSeed, 1, 2));
        uint8 kind = uint8(bound(kindSeed, 0, 3));

        // The chain key is read before the prank, because an intervening view call would consume it.
        bytes32 chainKey = registry.CHAIN_ROBINHOOD();
        vm.prank(actor);
        try hub.requestAudit(chainKey, bytes32(assetSeed % 8), tier, kind) returns (uint256 jobId) {
            jobIds.push(jobId);
            ++opened;
        } catch {
            ++requestFailures;
        }
    }

    /// @notice Takes the canonical position on a job with one auditor, which is how a quorum forms
    ///         across separate transactions.
    /// @param jobSeed Selects the job.
    /// @param signerSeed Selects the auditor.
    function agreeOnJob(uint256 jobSeed, uint256 signerSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        Job memory job = hub.getJob(jobId);
        if (job.status != JobStatus.Requested) return;

        AuditResult memory result = _canonicalResult(job);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(auditorKeys[signerSeed % auditorKeys.length], this.hashResult(jobId, result));
        _attest(jobId, result, signatures);
    }

    /// @notice Takes the canonical position with two auditors at once, which is the relay path.
    /// @param jobSeed Selects the job.
    function agreeOnJobAsAPair(uint256 jobSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        Job memory job = hub.getJob(jobId);
        if (job.status != JobStatus.Requested) return;

        AuditResult memory result = _canonicalResult(job);
        bytes32 digest = this.hashResult(jobId, result);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(auditorKeys[0], digest);
        signatures[1] = _sign(auditorKeys[1], digest);
        _attest(jobId, result, signatures);
    }

    /// @notice Takes a position nobody else can hold, which is how a job becomes disputed.
    /// @param jobSeed Selects the job.
    /// @param signerSeed Selects the auditor.
    function contradictOnJob(uint256 jobSeed, uint256 signerSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        Job memory job = hub.getJob(jobId);
        if (job.status != JobStatus.Requested) return;

        uint256 index = signerSeed % auditorKeys.length;
        AuditResult memory result = _canonicalResult(job);
        result.reportHash = keccak256(abi.encode("dissent", jobId, index));
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(auditorKeys[index], this.hashResult(jobId, result));
        _attest(jobId, result, signatures);
    }

    /// @notice Expires a job whose service level has elapsed.
    /// @param jobSeed Selects the job.
    function markExpired(uint256 jobSeed) external {
        if (jobIds.length == 0) return;
        uint256 jobId = jobIds[jobSeed % jobIds.length];
        try hub.markExpired(jobId) {
            ++expired;
        } catch {}
    }

    /// @notice Commits an unsolicited report, which consumes no access at all.
    /// @param assetSeed Selects the asset.
    /// @param riskSeed Selects the reported risk.
    function publishWatchdogReport(uint256 assetSeed, uint8 riskSeed) external {
        AuditResult memory result = AuditResult({
            chainKey: registry.CHAIN_ROBINHOOD(),
            assetId: bytes32(assetSeed % 8),
            overallTrust: uint8(bound(riskSeed, 0, 100)),
            contractTrust: 0,
            liquidityTrust: 0,
            holderTrust: 0,
            insiderTrust: 0,
            creatorTrust: 0,
            tradingTrust: 0,
            botTrust: 0,
            flags: 0,
            engineVersion: 1,
            analyzedAt: uint64(vm.getBlockTimestamp()),
            reportHash: keccak256(abi.encode("watchdog", assetSeed, riskSeed, vm.getBlockTimestamp())),
            reportURI: "ipfs://invariant"
        });

        bytes32 digest = this.hashResult(0, result);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(auditorKeys[0], digest);
        signatures[1] = _sign(auditorKeys[1], digest);
        vm.prank(vm.addr(auditorKeys[0]));
        try hub.publishWatchdogReport(result, signatures) {} catch {}
    }

    // -------------------------------------------------------------------------------------------
    // Time and governance
    // -------------------------------------------------------------------------------------------

    /// @notice Moves the clock forward by up to two minutes.
    /// @param secondsToAdvance The number of seconds to move forward.
    function warp(uint32 secondsToAdvance) external {
        uint256 delta = bound(secondsToAdvance, 1, 120);
        vm.warp(vm.getBlockTimestamp() + delta);
        vm.roll(vm.getBlockNumber() + delta * 10);
    }

    /// @notice Moves the clock past the service level.
    function warpPastSla() external {
        vm.warp(vm.getBlockTimestamp() + 40 * 120);
        vm.roll(vm.getBlockNumber() + 40 * 1200);
    }

    /// @notice Moves the clock past a whole access period.
    function warpPastAccessPeriod() external {
        uint64 duration = accessVault.lockDuration();
        vm.warp(vm.getBlockTimestamp() + duration + 1);
        vm.roll(vm.getBlockNumber() + 1000);
    }

    /// @notice Governance moves a tier's requirement anywhere in its bounds. A live period must not
    ///         notice, and the vault must still hold exactly what it owes.
    /// @param tier The tier, bounded to the two that exist.
    /// @param kay9 The requirement, bounded to what the vault accepts.
    function setRequirement(uint8 tier, uint256 kay9) external {
        uint8 t = uint8(bound(tier, 1, 2));
        uint256 lo = t == 1 ? accessVault.MIN_REQUIREMENT() : accessVault.requirementOf(1);
        uint256 hi = t == 1 ? accessVault.requirementOf(2) : accessVault.MAX_REQUIREMENT();
        uint256 amount = bound(kay9, lo, hi);
        vm.prank(accessVault.owner());
        accessVault.setRequirement(t, amount);
    }

    /// @notice Releases whatever the team schedule has unlocked.
    function releaseVesting() external {
        try vesting.release() {} catch {}
    }

    /// @notice Burns some of an actor's balance, which is the only supply-reducing user action.
    /// @param actorSeed Selects the actor.
    /// @param amount The amount to burn.
    function burn(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(actor);
        if (balance == 0) return;
        // Burns are capped so a run cannot bankrupt an actor and starve the access path.
        uint256 toBurn = bound(amount, 1, balance / 100 + 1);
        vm.prank(actor);
        token.burn(toBurn);
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Bridges a memory result into the hub's calldata-typed hashing function.
    /// @param jobId The job id.
    /// @param result The result.
    /// @return The digest.
    function hashResult(uint256 jobId, AuditResult calldata result) external view returns (bytes32) {
        return hub.hashResult(jobId, result);
    }

    /// @notice Attests and books whichever terminal state the call produced.
    /// @param jobId The job.
    /// @param result The result being attested.
    /// @param signatures The signatures over it.
    function _attest(uint256 jobId, AuditResult memory result, bytes[] memory signatures) private {
        vm.prank(vm.addr(auditorKeys[0]));
        try hub.attest(jobId, result, signatures) {
            JobStatus status = hub.getJob(jobId).status;
            if (status == JobStatus.Fulfilled) ++fulfilled;
            if (status == JobStatus.Disputed) ++disputed;
        } catch {}
    }

    /// @notice The one result every honest auditor would sign for a job, so that two of them
    ///         attesting in different transactions reach the same digest.
    /// @param job The job being attested.
    /// @return result The canonical result.
    function _canonicalResult(Job memory job) private pure returns (AuditResult memory result) {
        result = AuditResult({
            chainKey: job.chainKey,
            assetId: job.assetId,
            overallTrust: uint8(uint256(job.assetId) % 101),
            contractTrust: 0,
            liquidityTrust: 0,
            holderTrust: 0,
            insiderTrust: 0,
            creatorTrust: 0,
            tradingTrust: 0,
            botTrust: 0,
            flags: 0,
            engineVersion: 1,
            analyzedAt: job.requestedAt,
            reportHash: keccak256(abi.encode("canonical", job.chainKey, job.assetId, job.requestedAt)),
            reportURI: "ipfs://invariant"
        });
    }

    /// @notice Produces a 65-byte signature over a digest.
    /// @param key The signing key.
    /// @param digest The digest.
    /// @return The signature.
    function _sign(uint256 key, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
