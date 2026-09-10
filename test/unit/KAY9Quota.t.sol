// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AccessVault, Access} from "../../src/KAY9AccessVault.sol";
import {KAY9AuditHub, JobStatus} from "../../src/KAY9AuditHub.sol";
import {AuditResult} from "../../src/KAY9Registry.sol";

/// @notice A contract that requests audits, to prove the gate does not care what shape a caller is.
contract RequestingContract {
    /// @notice The hub to request from.
    KAY9AuditHub public immutable hub;

    /// @notice Binds the caller to a hub.
    /// @param hub_ The hub.
    constructor(KAY9AuditHub hub_) {
        hub = hub_;
    }

    /// @notice Requests an audit on its own behalf.
    /// @param chainKey The chain key.
    /// @param assetId The asset.
    /// @param tier The tier.
    /// @return The new job id.
    function request(bytes32 chainKey, bytes32 assetId, uint8 tier) external returns (uint256) {
        return hub.requestAudit(chainKey, assetId, tier, 3);
    }
}

/// @title KAY9QuotaTest
/// @notice Covers the allowance a lock buys: how many audits of which kind, when it resets, and
///         every way somebody might try to get one more than they locked for.
/// @dev The quota lives in the vault and is moved only by the hub, so these tests always drive it
///      through `requestAudit` rather than calling `consume` directly. That is the path a real
///      caller has, and it is the only one that proves the gate.
contract KAY9QuotaTest is Kay9TestBase {
    /// @notice A depositor with a deep period.
    address internal deepHolder = makeAddr("deepHolder");

    /// @notice A depositor with a forensic period.
    address internal forensicHolder = makeAddr("forensicHolder");

    /// @notice The chain key of the audited assets.
    bytes32 internal chainKey;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();
        chainKey = reportRegistry.CHAIN_ROBINHOOD();
        _seedAndWarm(2_500_000e18);
    }

    // -------------------------------------------------------------------------------------------
    // What a tier buys
    // -------------------------------------------------------------------------------------------

    /// @notice A deep period buys exactly four deep audits and no forensic one at all.
    function test_deepAccessBuysFourDeepAuditsAndNoForensicOne() public {
        _grantAccess(deepHolder, TIER_DEEP);
        assertEq(accessVault.deepRemaining(deepHolder), 4, "four deep audits");
        assertEq(accessVault.forensicRemaining(deepHolder), 0, "and no forensic one");
        assertFalse(accessVault.canRequest(deepHolder, TIER_FORENSIC), "which the view agrees about");

        for (uint256 i = 0; i < 4; ++i) {
            assertTrue(accessVault.canRequest(deepHolder, TIER_DEEP), "a deep audit is still available");
            vm.prank(deepHolder);
            hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, KIND_INDEPENDENT);
            assertEq(accessVault.deepRemaining(deepHolder), 3 - i, "one fewer each time");
        }

        assertFalse(accessVault.canRequest(deepHolder, TIER_DEEP), "the fifth is not available");
        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        hub.requestAudit(chainKey, bytes32(uint256(5)), TIER_DEEP, KIND_INDEPENDENT);

        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.TierNotPermitted.selector, TIER_DEEP, TIER_FORENSIC));
        hub.requestAudit(chainKey, bytes32(uint256(6)), TIER_FORENSIC, KIND_INDEPENDENT);

        assertEq(hub.jobCount(), 4, "exactly four jobs were created");
    }

    /// @notice A forensic period buys one forensic audit and four deep ones.
    function test_forensicAccessBuysOneForensicAndFourDeep() public {
        _grantAccess(forensicHolder, TIER_FORENSIC);
        assertEq(accessVault.deepRemaining(forensicHolder), 4, "four deep audits");
        assertEq(accessVault.forensicRemaining(forensicHolder), 1, "and one forensic one");

        vm.prank(forensicHolder);
        hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_FORENSIC, KIND_INDEPENDENT);
        assertEq(accessVault.forensicRemaining(forensicHolder), 0, "the forensic slot is spent");
        assertEq(accessVault.deepRemaining(forensicHolder), 4, "and the deep allowance is untouched");

        vm.prank(forensicHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_FORENSIC));
        hub.requestAudit(chainKey, bytes32(uint256(2)), TIER_FORENSIC, KIND_INDEPENDENT);

        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(forensicHolder);
            hub.requestAudit(chainKey, bytes32(i + 10), TIER_DEEP, KIND_INDEPENDENT);
        }
        assertEq(accessVault.deepRemaining(forensicHolder), 0, "and then four deep audits, no more");

        vm.prank(forensicHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        hub.requestAudit(chainKey, bytes32(uint256(20)), TIER_DEEP, KIND_INDEPENDENT);

        assertEq(hub.jobCount(), 5, "five jobs in total, exactly what the tier sells");
    }

    // -------------------------------------------------------------------------------------------
    // The gate cannot be walked around
    // -------------------------------------------------------------------------------------------

    /// @notice Another address cannot spend someone else's allowance, and holds none of its own.
    function test_quotaCannotBeSpentByAnotherAddress() public {
        _grantAccess(deepHolder, TIER_DEEP);
        address freeloader = makeAddr("freeloader");

        vm.prank(freeloader);
        vm.expectRevert(KAY9AccessVault.NoAccess.selector);
        hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, KIND_INDEPENDENT);

        assertEq(accessVault.deepRemaining(deepHolder), 4, "the holder's allowance is untouched");
        assertFalse(accessVault.canRequest(freeloader, TIER_DEEP), "and the freeloader has none");
        assertEq(hub.jobCount(), 0, "no job was created");
    }

    /// @notice A contract gets exactly the same answer as a wallet: its own allowance, or nothing.
    function test_aContractIsGatedLikeAnyOtherCaller() public {
        RequestingContract caller = new RequestingContract(hub);

        vm.expectRevert(KAY9AccessVault.NoAccess.selector);
        caller.request(chainKey, bytes32(uint256(1)), TIER_DEEP);

        // Given its own period, the same contract is served, and only up to its own allowance.
        _grantAccess(address(caller), TIER_DEEP);
        for (uint256 i = 0; i < 4; ++i) {
            caller.request(chainKey, bytes32(i + 1), TIER_DEEP);
        }
        assertEq(accessVault.deepRemaining(address(caller)), 0, "a contract gets four, like anyone else");

        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        caller.request(chainKey, bytes32(uint256(9)), TIER_DEEP);
    }

    /// @notice Consuming quota is the hub's privilege, so nobody can mint themselves an audit.
    function test_quotaCannotBeConsumedOrRestoredWithoutTheHub() public {
        _grantAccess(deepHolder, TIER_DEEP);
        uint64 startedAt = accessVault.accessOf(deepHolder).startedAt;

        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, deepHolder));
        accessVault.consume(deepHolder, TIER_DEEP);

        RequestingContract caller = new RequestingContract(hub);
        vm.prank(address(caller));
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, address(caller)));
        accessVault.restore(deepHolder, TIER_DEEP, startedAt);

        assertEq(accessVault.deepRemaining(deepHolder), 4, "the allowance is exactly what was locked for");
    }

    // -------------------------------------------------------------------------------------------
    // Resets
    // -------------------------------------------------------------------------------------------

    /// @notice The allowance resets only on renewal after expiry, never inside a period.
    function test_quotaOnlyResetsOnRenewalAfterExpiry() public {
        _grantAccess(deepHolder, TIER_DEEP);
        vm.prank(deepHolder);
        hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, KIND_INDEPENDENT);
        vm.prank(deepHolder);
        hub.requestAudit(chainKey, bytes32(uint256(2)), TIER_DEEP, KIND_INDEPENDENT);
        assertEq(accessVault.deepRemaining(deepHolder), 2, "two of four are spent");

        uint64 expiresAt = accessVault.accessOf(deepHolder).expiresAt;

        // Mid-period: renewal is refused, so the allowance cannot be refreshed.
        vm.warp(expiresAt - 1);
        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        accessVault.renew(TIER_DEEP, type(uint256).max);
        assertEq(accessVault.deepRemaining(deepHolder), 2, "still two");

        // Locking again is refused too, so a second period cannot be stacked on the first.
        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.AccessLive.selector, expiresAt));
        accessVault.lock(TIER_DEEP, type(uint256).max);
        assertEq(accessVault.deepRemaining(deepHolder), 2, "still two");

        // After expiry, the allowance is gone rather than reset.
        vm.warp(expiresAt);
        assertEq(accessVault.deepRemaining(deepHolder), 0, "an expired period grants nothing");
        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        hub.requestAudit(chainKey, bytes32(uint256(3)), TIER_DEEP, KIND_INDEPENDENT);

        // Renewal is what refreshes it.
        _warmBuffer();
        (uint256 required,) = accessVault.quoteLock(TIER_DEEP);
        uint256 held = accessVault.accessOf(deepHolder).lockedKay9;
        if (required > held) _fundKay9(deepHolder, required - held);
        vm.prank(deepHolder);
        accessVault.renew(TIER_DEEP, type(uint256).max);
        assertEq(accessVault.deepRemaining(deepHolder), 4, "a renewed period is a fresh allowance");
    }

    /// @notice An upgrade is not a reset: the deep audits already taken stay taken.
    function test_upgradingDoesNotResetTheDeepAllowance() public {
        _grantAccess(deepHolder, TIER_DEEP);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(deepHolder);
            hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, KIND_INDEPENDENT);
        }
        assertEq(accessVault.deepRemaining(deepHolder), 1, "three of four are spent");

        (uint256 forensicRequired,) = accessVault.quoteLock(TIER_FORENSIC);
        _fundKay9(deepHolder, forensicRequired);
        vm.prank(deepHolder);
        accessVault.upgrade(type(uint256).max);

        assertEq(accessVault.deepRemaining(deepHolder), 1, "the upgrade did not refill the deep allowance");
        assertEq(accessVault.forensicRemaining(deepHolder), 1, "it bought the forensic slot and nothing more");
    }

    // -------------------------------------------------------------------------------------------
    // Restoring a unit
    // -------------------------------------------------------------------------------------------

    /// @notice A restored unit is credited to the period it came from and is spendable again.
    function test_aRestoredUnitIsCreditedToTheSamePeriod() public {
        _grantAccess(deepHolder, TIER_DEEP);
        uint64 startedAt = accessVault.accessOf(deepHolder).startedAt;

        vm.prank(deepHolder);
        uint256 jobId = hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, KIND_INDEPENDENT);
        assertEq(accessVault.deepRemaining(deepHolder), 3, "the request spent a unit");

        vm.warp(vm.getBlockTimestamp() + hub.slaSeconds());
        hub.markExpired(jobId);

        assertEq(accessVault.deepRemaining(deepHolder), 4, "the unit came back");
        assertEq(accessVault.accessOf(deepHolder).startedAt, startedAt, "into the very same period");

        // And it is really spendable again, not just a number.
        vm.prank(deepHolder);
        hub.requestAudit(chainKey, bytes32(uint256(2)), TIER_DEEP, KIND_INDEPENDENT);
        assertEq(accessVault.deepRemaining(deepHolder), 3, "the restored unit was spendable");
    }

    /// @notice A unit taken from a period that has since been replaced is not credited to the new
    ///         one, so an expired job from last month is not a free audit this month.
    function test_aUnitFromAReplacedPeriodIsNotCreditedToTheNewOne() public {
        _grantAccess(deepHolder, TIER_DEEP);
        uint64 firstPeriod = accessVault.accessOf(deepHolder).startedAt;

        vm.prank(deepHolder);
        uint256 jobId = hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, KIND_INDEPENDENT);
        assertEq(hub.getJob(jobId).accessPeriodStartedAt, firstPeriod, "the job names the first period");

        // The period ends and is renewed into a fresh one, which spends nothing.
        vm.warp(accessVault.accessOf(deepHolder).expiresAt);
        vm.roll(vm.getBlockNumber() + 1);
        _warmBuffer();
        (uint256 required,) = accessVault.quoteLock(TIER_DEEP);
        uint256 held = accessVault.accessOf(deepHolder).lockedKay9;
        if (required > held) _fundKay9(deepHolder, required - held);
        vm.prank(deepHolder);
        accessVault.renew(TIER_DEEP, type(uint256).max);

        uint64 secondPeriod = accessVault.accessOf(deepHolder).startedAt;
        assertTrue(secondPeriod != firstPeriod, "the period really was replaced");
        assertEq(accessVault.deepRemaining(deepHolder), 4, "the new period starts full");

        // Only now is the old job expired. The credit must go nowhere.
        hub.markExpired(jobId);

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Expired), "the old job did expire");
        assertEq(accessVault.deepRemaining(deepHolder), 4, "and granted no fifth audit in the new period");
        assertEq(accessVault.accessOf(deepHolder).deepUsed, 0, "the new period's usage is untouched");

        // Which is to say: still four audits in the new period, not five.
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(deepHolder);
            hub.requestAudit(chainKey, bytes32(i + 30), TIER_DEEP, KIND_INDEPENDENT);
        }
        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        hub.requestAudit(chainKey, bytes32(uint256(40)), TIER_DEEP, KIND_INDEPENDENT);
    }

    /// @notice A restore into an account that has unlocked altogether is a silent no-op.
    function test_aUnitFromAnUnlockedPeriodIsNotCreditedAnywhere() public {
        _grantAccess(deepHolder, TIER_DEEP);
        vm.prank(deepHolder);
        uint256 jobId = hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, KIND_INDEPENDENT);

        vm.warp(accessVault.accessOf(deepHolder).expiresAt);
        vm.prank(deepHolder);
        accessVault.unlock();
        assertEq(accessVault.accessOf(deepHolder).lockedKay9, 0, "the period is gone");

        // The expiry still succeeds; it simply has nowhere to credit.
        hub.markExpired(jobId);
        Access memory access = accessVault.accessOf(deepHolder);
        assertEq(access.deepQuota, 0, "no allowance was invented");
        assertEq(access.deepUsed, 0, "and nothing was written into a dead record");
        assertEq(access.lockedKay9, 0, "and no principal was recreated");
        assertFalse(accessVault.canRequest(deepHolder, TIER_DEEP), "the account still cannot request");
    }

    /// @notice A disputed job restores its unit exactly once, to the period that paid for it.
    function test_aDisputedJobRestoresItsUnitOnce() public {
        _grantAccess(forensicHolder, TIER_FORENSIC);
        vm.prank(forensicHolder);
        uint256 jobId = hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_FORENSIC, KIND_INDEPENDENT);
        assertEq(accessVault.forensicRemaining(forensicHolder), 0, "the forensic unit is spent");

        address[] memory sorted = _sortedAuditors();
        for (uint256 i = 0; i < 3; ++i) {
            AuditResult memory result = _result(bytes32(uint256(1)));
            result.reportHash = keccak256(abi.encode("dissent", i));
            bytes[] memory signature = new bytes[](1);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(_keyOf(sorted[i]), this.callHashResult(jobId, result));
            signature[0] = abi.encodePacked(r, s, v);
            hub.attest(jobId, result, signature);
        }

        assertEq(uint8(hub.getJob(jobId).status), uint8(JobStatus.Disputed), "the job is disputed");
        assertEq(accessVault.forensicRemaining(forensicHolder), 1, "and the forensic unit came back");
        assertEq(accessVault.accessOf(forensicHolder).forensicUsed, 0, "exactly once");

        // Which the holder can then really spend.
        vm.prank(forensicHolder);
        hub.requestAudit(chainKey, bytes32(uint256(2)), TIER_FORENSIC, KIND_INDEPENDENT);
        assertEq(accessVault.forensicRemaining(forensicHolder), 0, "on a second forensic audit");
    }

    // -------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------

    /// @notice Changing a tier's allowance never changes a live period's allowance, in either
    ///         direction: the numbers a period opened with are the numbers it keeps.
    function test_governanceCannotChangeALivePeriodsAllowance() public {
        _grantAccess(deepHolder, TIER_DEEP);
        _grantAccess(forensicHolder, TIER_FORENSIC);

        vm.prank(deepHolder);
        hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, KIND_INDEPENDENT);

        // Governance cuts the deep tier to a single audit and inflates the forensic one.
        vm.startPrank(address(timelock));
        accessVault.setQuota(TIER_DEEP, 1, 0);
        accessVault.setQuota(TIER_FORENSIC, 9, 9);
        vm.stopPrank();

        assertEq(accessVault.deepRemaining(deepHolder), 3, "the live deep period keeps its four");
        assertEq(accessVault.accessOf(deepHolder).deepQuota, 4, "because the number is frozen in the record");
        assertEq(accessVault.deepRemaining(forensicHolder), 4, "and the live forensic period keeps its four");
        assertEq(accessVault.forensicRemaining(forensicHolder), 1, "and its single forensic slot");

        // The holder really does still get all four, whatever governance now says.
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(deepHolder);
            hub.requestAudit(chainKey, bytes32(i + 2), TIER_DEEP, KIND_INDEPENDENT);
        }
        assertEq(accessVault.deepRemaining(deepHolder), 0, "four in total");
        vm.prank(deepHolder);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        hub.requestAudit(chainKey, bytes32(uint256(99)), TIER_DEEP, KIND_INDEPENDENT);

        // The new numbers apply to the next period.
        address newcomer = makeAddr("newcomer");
        _grantAccess(newcomer, TIER_DEEP);
        assertEq(accessVault.deepRemaining(newcomer), 1, "a period opened after the change gets the new number");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @notice A minimal audit result for an asset.
    /// @param assetId The asset the result describes.
    /// @return result The result.
    function _result(bytes32 assetId) internal view returns (AuditResult memory result) {
        result = AuditResult({
            chainKey: chainKey,
            assetId: assetId,
            overallTrust: 50,
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
            reportHash: keccak256("quota"),
            reportURI: "ipfs://quota"
        });
    }

    /// @notice Bridges a memory result into the hub's calldata-typed hashing function.
    /// @param jobId The job id.
    /// @param result The result.
    /// @return The digest.
    function callHashResult(uint256 jobId, AuditResult calldata result) external view returns (bytes32) {
        return hub.hashResult(jobId, result);
    }
}
