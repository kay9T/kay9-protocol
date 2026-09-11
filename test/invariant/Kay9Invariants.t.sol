// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {Kay9Handler} from "./Kay9Handler.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {KAY9AccessVault, Access} from "../../src/KAY9AccessVault.sol";
import {KAY9AuditHub, Job, JobStatus} from "../../src/KAY9AuditHub.sol";
import {ReportRecord} from "../../src/KAY9Registry.sol";

/// @title Kay9Invariants
/// @notice The properties that must hold no matter what sequence of public actions is taken.
contract Kay9Invariants is Kay9TestBase {
    /// @notice The action driver.
    Kay9Handler internal handler;

    /// @notice The supply at deployment, which is the permanent ceiling.
    uint256 internal initialSupply;

    /// @notice The highest report count seen so far, used to prove the log never shrinks.
    uint256 internal highWaterReportCount;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();

        // A one-hour service level keeps the expiry path reachable inside an invariant run, and the
        // shortest legal access period keeps renewal and unlocking reachable too.
        _governanceCall(address(hub), abi.encodeCall(KAY9AuditHub.setSla, (1 hours)));
        _governanceCall(address(accessVault), abi.encodeCall(KAY9AccessVault.setLockDuration, (7 days)));

        initialSupply = token.totalSupply();

        address[] memory actors = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", i)));
            _fundKay9(actors[i], 5_000_000e18);
            vm.prank(actors[i]);
            token.approve(address(accessVault), type(uint256).max);
        }

        address[] memory sorted = _sortedAuditors();
        uint256[] memory sortedKeys = new uint256[](3);
        for (uint256 i = 0; i < 3; ++i) {
            sortedKeys[i] = _keyOf(sorted[i]);
        }

        handler =
            new Kay9Handler(token, vesting, accessVault, hub, reportRegistry, sortedKeys, actors);
        targetContract(address(handler));
    }

    /// @notice The supply is minted once and can only ever go down.
    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), initialSupply, "supply never exceeds the genesis mint");
        assertEq(initialSupply, 1_000_000_000e18, "the genesis mint is exactly one billion");
    }

    /// @notice The team can never release more than the schedule has unlocked.
    function invariant_vestingNeverOverReleases() public view {
        uint256 released = vesting.released();
        assertLe(released, vesting.unlocked(), "released never exceeds unlocked");
        assertLe(vesting.unlocked(), vesting.TOTAL_ALLOCATION(), "unlocked never exceeds the allocation");
        assertEq(
            token.balanceOf(address(vesting)),
            vesting.TOTAL_ALLOCATION() - released,
            "the vesting balance is exactly the unreleased remainder"
        );
    }

    /// @notice The vault can always pay back every principal it holds.
    /// @dev "At least" rather than "exactly", because anyone can push tokens into any ERC20 holder;
    ///      what must never happen is the vault owing more than it has.
    function invariant_vaultIsAlwaysSolvent() public view {
        assertGe(
            token.balanceOf(address(accessVault)),
            accessVault.totalLocked(),
            "the vault holds at least every principal it owes"
        );
    }

    /// @notice The hub never holds KAY9, because nothing is ever paid to it.
    function invariant_hubHoldsNoKay9() public view {
        assertEq(token.balanceOf(address(hub)), 0, "the hub is not a treasury");
    }

    /// @notice No account ever spends more audits than its live period granted it.
    function invariant_quotaUsedNeverExceedsQuotaGranted() public view {
        uint256 count = handler.actorCount();
        uint256 locked;
        for (uint256 i = 0; i < count; ++i) {
            address actor = handler.actors(i);
            Access memory access = accessVault.accessOf(actor);
            assertLe(access.deepUsed, access.deepQuota, "deep audits used never exceed the deep allowance");
            assertLe(
                access.forensicUsed, access.forensicQuota, "forensic audits used never exceed the forensic allowance"
            );
            if (access.lockedKay9 == 0) {
                assertEq(access.deepUsed, 0, "an account with no period has spent nothing");
                assertEq(access.forensicUsed, 0, "an account with no period has spent nothing");
            }
            locked += access.lockedKay9;
        }
        assertEq(locked, accessVault.totalLocked(), "totalLocked is exactly the sum of the live principals");
    }

    /// @notice Every job is in exactly one state, and a fulfilled job always has its record.
    function invariant_jobsHaveExactlyOneOutcome() public view {
        uint256 count = handler.jobCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 jobId = handler.jobIds(i);
            Job memory job = hub.getJob(jobId);
            assertTrue(job.status != JobStatus.None, "an opened job always exists");

            if (job.status == JobStatus.Fulfilled) {
                assertLt(job.reportId, reportRegistry.reportCount(), "a fulfilled job points into the log");
                ReportRecord memory record = reportRegistry.getReport(job.reportId);
                assertEq(record.jobId, jobId, "and the record it points at is its own");
                assertEq(record.requester, job.requester, "with the requester the job recorded");
                assertEq(record.tier, job.tier, "and the tier the job consumed");
                assertGt(record.signers.length, 0, "a record always names the quorum that signed it");
            } else {
                assertEq(job.reportId, 0, "only a fulfilled job has a report");
            }
        }
    }

    /// @notice The report log only ever grows.
    function invariant_registryIsAppendOnly() public {
        uint256 count = reportRegistry.reportCount();
        assertGe(count, highWaterReportCount, "the report log never shrinks");
        highWaterReportCount = count;
    }

    /// @notice The genesis vault never gains tokens it did not start with.
    function invariant_genesisCannotBeRefilled() public view {
        assertLe(token.balanceOf(address(genesis)), genesis.LAUNCH_ALLOCATION());
    }

    /// @notice The liquidity lock never holds a position it has already released.
    function invariant_lockNeverReclaims() public view {
        uint256 count = lock.lockedCount();
        for (uint256 i = 0; i < count; ++i) {
            uint256 tokenId = lock.lockedTokenIds(i);
            if (lock.isLocked(tokenId)) {
                assertEq(
                    IERC721(address(uni.positionManager)).ownerOf(tokenId),
                    address(uni.feeSplitter),
                    "locked stays locked"
                );
            }
        }
    }

    /// @notice The handler really can drive the protocol through every state the invariants police.
    /// @dev The invariant runs are random, so a coverage assertion inside `afterInvariant` would be
    ///      flaky. Proving reachability deterministically here is what stops the invariants above
    ///      from passing vacuously on a run that happened to lock nothing and open no jobs.
    function test_handlerReachesEveryState() public {
        // A period opens and a request spends a unit of it.
        handler.lockAccess(0, 2);
        assertEq(handler.locks(), 1, "an access period was opened");
        assertGt(accessVault.totalLocked(), 0, "the principal is held");

        handler.requestAudit(0, 1, 1, 1);
        assertEq(handler.opened(), 1, "a request was accepted");
        assertEq(handler.requestFailures(), 0, "the access gate let it through");
        assertEq(accessVault.deepRemaining(handler.actors(0)), 3, "and it cost a quota unit");

        // Two agreeing auditors settle it.
        handler.agreeOnJobAsAPair(0);
        assertEq(handler.fulfilled(), 1, "the job settled");
        assertEq(reportRegistry.reportCount(), 1, "and left a record");

        // Three contradicting auditors dispute the next one and the unit comes back.
        handler.requestAudit(0, 2, 1, 1);
        assertEq(handler.opened(), 2, "a second request was accepted");
        for (uint256 i = 0; i < 3; ++i) {
            handler.contradictOnJob(1, i);
        }
        assertEq(handler.disputed(), 1, "the second job was disputed");
        assertEq(accessVault.deepRemaining(handler.actors(0)), 3, "the disputed unit was restored");

        // A job nobody answers expires and gives its unit back too.
        handler.requestAudit(0, 3, 1, 1);
        handler.warpPastSla();
        handler.markExpired(2);
        assertEq(handler.expired(), 1, "the third job expired");
        assertEq(accessVault.deepRemaining(handler.actors(0)), 3, "the expired unit was restored");

        // The period ends, is renewed, and is finally unlocked in full.
        handler.warpPastAccessPeriod();
        handler.renewAccess(0, 1);
        assertEq(handler.renewals(), 1, "the period was renewed");
        assertEq(accessVault.deepRemaining(handler.actors(0)), 4, "with a fresh allowance");

        handler.warpPastAccessPeriod();
        uint256 balanceBefore = token.balanceOf(handler.actors(0));
        uint256 principal = accessVault.accessOf(handler.actors(0)).lockedKay9;
        handler.unlockAccess(0);
        assertEq(handler.unlocks(), 1, "the period was unlocked");
        assertEq(token.balanceOf(handler.actors(0)) - balanceBefore, principal, "and returned the whole principal");
        assertEq(accessVault.totalLocked(), 0, "the vault owes nothing");

        // And an upgrade is reachable from a deep period.
        handler.lockAccess(1, 1);
        handler.upgradeAccess(1);
        assertEq(handler.upgrades(), 1, "a deep period was upgraded to forensic");
        assertEq(accessVault.forensicRemaining(handler.actors(1)), 1, "which bought a forensic slot");

        // The watchdog path appends without any access at all.
        handler.publishWatchdogReport(5, 20);
        assertEq(reportRegistry.reportCount(), 2, "an unsolicited report was appended");
    }
}
