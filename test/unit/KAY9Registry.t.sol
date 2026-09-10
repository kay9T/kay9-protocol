// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KAY9Registry, AuditResult, ReportMeta, ReportRecord} from "../../src/KAY9Registry.sol";

/// @title KAY9RegistryTest
/// @notice Direct tests for the append-only report log.
/// @dev The registry was previously exercised only through KAY9AuditHub.t.sol, which reaches
///      getReport, latest, reportCount, historyCount and the NotAuditHub revert but never touches
///      the two paging functions. Those are the ones a reader actually calls to walk an asset's
///      history, and `docs/REGISTRY_UPGRADE.md` records that shipping them untested was the
///      deciding factor against making them more complicated. So they are pinned here.
///
///      These tests deploy the registry standalone against a stand-in hub address rather than
///      inheriting Kay9TestBase, because nothing here needs the Uniswap stack and the point is to
///      isolate the log's own behaviour from the hub's.
contract KAY9RegistryTest is Test {
    KAY9Registry internal registry;

    address internal hub = makeAddr("auditHub");
    address internal stranger = makeAddr("stranger");
    address internal requester = makeAddr("requester");

    bytes32 internal constant CHAIN = keccak256("eip155:4663");
    bytes32 internal constant ASSET_A = bytes32(uint256(uint160(0xA11CE)));
    bytes32 internal constant ASSET_B = bytes32(uint256(uint160(0xB0B)));

    event ReportRecorded(
        uint256 indexed reportId,
        bytes32 indexed chainKey,
        bytes32 indexed assetId,
        uint256 jobId,
        uint8 overallTrust,
        bytes32 reportHash
    );

    function setUp() public {
        registry = new KAY9Registry(hub);
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _result(bytes32 assetId, uint8 overallTrust) internal pure returns (AuditResult memory) {
        return AuditResult({
            chainKey: CHAIN,
            assetId: assetId,
            overallTrust: overallTrust,
            contractTrust: 10,
            liquidityTrust: 20,
            holderTrust: 30,
            insiderTrust: 40,
            creatorTrust: 50,
            tradingTrust: 60,
            botTrust: 70,
            flags: 131_392,
            engineVersion: 1_001_000,
            analyzedAt: 1_788_754_337,
            reportHash: keccak256(abi.encode(assetId, overallTrust)),
            reportURI: "ipfs://bafyexample"
        });
    }

    function _signers() internal view returns (address[] memory signers) {
        signers = new address[](2);
        signers[0] = hub;
        signers[1] = stranger;
    }

    /// @dev The provenance the hub attaches to a requested deep audit.
    function _meta(uint256 jobId) internal view returns (ReportMeta memory) {
        return ReportMeta({jobId: jobId, requester: requester, declaredRequesterKind: 1, tier: 1});
    }

    /// @dev The provenance the hub attaches to an unsolicited watchdog report.
    function _watchdogMeta() internal pure returns (ReportMeta memory) {
        return ReportMeta({jobId: 0, requester: address(0), declaredRequesterKind: 0, tier: 0});
    }

    /// @dev Appends `count` reports for one asset and returns their ids in order.
    function _seed(bytes32 assetId, uint256 count) internal returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            vm.prank(hub);
            ids[i] = registry.recordReport(_meta(i + 1), _result(assetId, uint8(i)), _signers());
        }
    }

    // -----------------------------------------------------------------------
    // construction and access control
    // -----------------------------------------------------------------------

    function test_constructorRejectsZeroHub() public {
        vm.expectRevert(KAY9Registry.ZeroAuditHub.selector);
        new KAY9Registry(address(0));
    }

    function test_hubIsFixedAtConstruction() public view {
        assertEq(registry.auditHub(), hub);
    }

    function test_onlyTheHubCanAppend() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KAY9Registry.NotAuditHub.selector, stranger));
        registry.recordReport(_meta(1), _result(ASSET_A, 60), _signers());
    }

    function test_rejectsAReportWithNoSigners() public {
        vm.prank(hub);
        vm.expectRevert(KAY9Registry.NoSigners.selector);
        registry.recordReport(_meta(1), _result(ASSET_A, 60), new address[](0));
    }

    // -----------------------------------------------------------------------
    // appending
    // -----------------------------------------------------------------------

    function test_idsAreSequentialAndCountGrows() public {
        assertEq(registry.reportCount(), 0);
        uint256[] memory ids = _seed(ASSET_A, 3);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
        assertEq(ids[2], 2);
        assertEq(registry.reportCount(), 3);
    }

    function test_recordStoresEveryFieldIncludingCommitmentPoint() public {
        vm.warp(1_788_800_000);
        vm.roll(56_600_000);

        AuditResult memory input = _result(ASSET_A, 61);
        vm.prank(hub);
        uint256 reportId = registry.recordReport(_meta(77), input, _signers());

        ReportRecord memory record = registry.getReport(reportId);
        assertEq(record.jobId, 77);
        assertEq(record.requester, requester, "the provenance names the requester");
        assertEq(record.declaredRequesterKind, 1, "the declared kind is stored verbatim");
        assertEq(record.tier, 1, "the access tier is stored");
        assertEq(record.committedAt, 1_788_800_000);
        assertEq(record.committedBlock, 56_600_000);
        assertEq(record.signers.length, 2);
        assertEq(record.signers[0], hub);
        assertEq(record.result.chainKey, CHAIN);
        assertEq(record.result.assetId, ASSET_A);
        assertEq(record.result.overallTrust, 61);
        assertEq(record.result.botTrust, 70);
        assertEq(record.result.flags, 131_392);
        assertEq(record.result.engineVersion, 1_001_000);
        assertEq(record.result.analyzedAt, 1_788_754_337);
        assertEq(record.result.reportHash, input.reportHash);
        assertEq(record.result.reportURI, "ipfs://bafyexample");
    }

    function test_emitsReportRecorded() public {
        AuditResult memory input = _result(ASSET_A, 42);
        vm.expectEmit(true, true, true, true, address(registry));
        emit ReportRecorded(0, CHAIN, ASSET_A, 9, 42, input.reportHash);
        vm.prank(hub);
        registry.recordReport(_meta(9), input, _signers());
    }

    /// @notice An unsolicited watchdog report carries zeroed provenance and is otherwise normal.
    function test_unsolicitedReportUsesJobIdZero() public {
        vm.prank(hub);
        uint256 reportId = registry.recordReport(_watchdogMeta(), _result(ASSET_A, 55), _signers());
        ReportRecord memory record = registry.getReport(reportId);
        assertEq(record.jobId, 0);
        assertEq(record.requester, address(0), "nobody requested it");
        assertEq(record.declaredRequesterKind, 0, "no kind was declared");
        assertEq(record.tier, 0, "no access tier was consumed");
        assertEq(registry.historyCount(CHAIN, ASSET_A), 1);
    }

    // -----------------------------------------------------------------------
    // keys
    // -----------------------------------------------------------------------

    function test_assetKeyIsDeterministicAndSeparatesAssets() public view {
        assertEq(registry.assetKey(CHAIN, ASSET_A), registry.assetKey(CHAIN, ASSET_A));
        assertTrue(registry.assetKey(CHAIN, ASSET_A) != registry.assetKey(CHAIN, ASSET_B));
        // The same asset id on a different chain is a different asset.
        assertTrue(registry.assetKey(CHAIN, ASSET_A) != registry.assetKey(keccak256("eip155:56"), ASSET_A));
    }

    function test_evmAssetIdIsTheLeftPaddedAddress() public view {
        address token = 0x6CCe60df223EA78543D1AAa5dAa2e5ba91Feb0cB;
        assertEq(registry.evmAssetId(token), bytes32(uint256(uint160(token))));
    }

    // -----------------------------------------------------------------------
    // getReports paging  (previously untested)
    // -----------------------------------------------------------------------

    function test_getReportsReturnsTheRequestedWindow() public {
        _seed(ASSET_A, 5);
        ReportRecord[] memory page = registry.getReports(1, 3);
        assertEq(page.length, 3);
        assertEq(page[0].result.overallTrust, 1);
        assertEq(page[1].result.overallTrust, 2);
        assertEq(page[2].result.overallTrust, 3);
    }

    function test_getReportsTruncatesAtTheEndOfTheLog() public {
        _seed(ASSET_A, 5);
        ReportRecord[] memory page = registry.getReports(3, 100);
        assertEq(page.length, 2, "must stop at the end rather than revert");
        assertEq(page[0].result.overallTrust, 3);
        assertEq(page[1].result.overallTrust, 4);
    }

    function test_getReportsBeyondTheEndIsEmpty() public {
        _seed(ASSET_A, 3);
        assertEq(registry.getReports(3, 10).length, 0);
        assertEq(registry.getReports(999, 10).length, 0);
    }

    function test_getReportsWithZeroLimitIsEmpty() public {
        _seed(ASSET_A, 3);
        assertEq(registry.getReports(0, 0).length, 0);
    }

    function test_getReportsOnAnEmptyLogIsEmpty() public view {
        assertEq(registry.getReports(0, 10).length, 0);
    }

    function test_getReportsCoversTheWholeLog() public {
        _seed(ASSET_A, 4);
        ReportRecord[] memory page = registry.getReports(0, registry.reportCount());
        assertEq(page.length, 4);
        for (uint256 i = 0; i < page.length; ++i) {
            assertEq(page[i].result.overallTrust, uint8(i));
        }
    }

    /// @notice Any window is exactly the same records `getReport` returns one at a time.
    function testFuzz_getReportsAgreesWithGetReport(uint8 total, uint8 offset, uint8 limit) public {
        total = uint8(bound(total, 1, 12));
        _seed(ASSET_A, total);

        ReportRecord[] memory page = registry.getReports(offset, limit);

        uint256 expectedEnd = uint256(offset) + uint256(limit);
        if (expectedEnd > total) expectedEnd = total;
        uint256 expectedLength = offset >= total ? 0 : expectedEnd - offset;

        assertEq(page.length, expectedLength);
        for (uint256 i = 0; i < page.length; ++i) {
            assertEq(page[i].result.reportHash, registry.getReport(offset + i).result.reportHash);
        }
    }

    // -----------------------------------------------------------------------
    // history paging  (previously untested)
    // -----------------------------------------------------------------------

    function test_historyIsKeptPerAsset() public {
        _seed(ASSET_A, 2);
        _seed(ASSET_B, 3);

        assertEq(registry.historyCount(CHAIN, ASSET_A), 2);
        assertEq(registry.historyCount(CHAIN, ASSET_B), 3);
        assertEq(registry.reportCount(), 5, "the global log holds both");

        uint256[] memory a = registry.history(CHAIN, ASSET_A, 0, 10);
        assertEq(a.length, 2);
        assertEq(a[0], 0);
        assertEq(a[1], 1);

        uint256[] memory b = registry.history(CHAIN, ASSET_B, 0, 10);
        assertEq(b.length, 3);
        assertEq(b[0], 2, "asset B's ids are its own, not a re-numbering");
        assertEq(b[2], 4);
    }

    function test_historyReturnsTheRequestedWindow() public {
        _seed(ASSET_A, 5);
        uint256[] memory ids = registry.history(CHAIN, ASSET_A, 1, 2);
        assertEq(ids.length, 2);
        assertEq(ids[0], 1);
        assertEq(ids[1], 2);
    }

    function test_historyTruncatesAtTheEnd() public {
        _seed(ASSET_A, 3);
        uint256[] memory ids = registry.history(CHAIN, ASSET_A, 2, 50);
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
    }

    function test_historyBeyondTheEndIsEmpty() public {
        _seed(ASSET_A, 3);
        assertEq(registry.history(CHAIN, ASSET_A, 3, 10).length, 0);
        assertEq(registry.history(CHAIN, ASSET_A, 999, 10).length, 0);
    }

    function test_historyOfAnUnknownAssetIsEmpty() public view {
        assertEq(registry.historyCount(CHAIN, ASSET_B), 0);
        assertEq(registry.history(CHAIN, ASSET_B, 0, 10).length, 0);
    }

    function testFuzz_historyAgreesWithHistoryCount(uint8 total, uint8 offset, uint8 limit) public {
        total = uint8(bound(total, 1, 12));
        _seed(ASSET_A, total);

        uint256[] memory ids = registry.history(CHAIN, ASSET_A, offset, limit);

        uint256 expectedEnd = uint256(offset) + uint256(limit);
        if (expectedEnd > total) expectedEnd = total;
        uint256 expectedLength = offset >= total ? 0 : expectedEnd - offset;

        assertEq(ids.length, expectedLength);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(ids[i], offset + i, "history ids are the global report ids, in order");
        }
    }

    // -----------------------------------------------------------------------
    // latest
    // -----------------------------------------------------------------------

    function test_latestReturnsTheMostRecentReportForTheAsset() public {
        _seed(ASSET_A, 3);
        _seed(ASSET_B, 1);

        (bool exists, ReportRecord memory record) = registry.latest(CHAIN, ASSET_A);
        assertTrue(exists);
        assertEq(record.result.overallTrust, 2, "the newest, not the first");
        assertEq(record.result.assetId, ASSET_A);

        (bool existsB, ReportRecord memory recordB) = registry.latest(CHAIN, ASSET_B);
        assertTrue(existsB);
        assertEq(recordB.result.assetId, ASSET_B);
    }

    function test_latestOfAnUnauditedAssetReportsNoneRatherThanReverting() public view {
        (bool exists, ReportRecord memory record) = registry.latest(CHAIN, ASSET_B);
        assertFalse(exists);
        assertEq(record.result.assetId, bytes32(0));
        assertEq(record.committedAt, 0);
    }

    // -----------------------------------------------------------------------
    // append-only
    // -----------------------------------------------------------------------

    /// @notice There is no entry point that mutates or removes a record, and re-recording the same
    ///         asset appends rather than overwriting.
    function test_recordsAreOnlyEverAppended() public {
        _seed(ASSET_A, 1);
        bytes32 firstHash = registry.getReport(0).result.reportHash;

        vm.prank(hub);
        registry.recordReport(_meta(2), _result(ASSET_A, 99), _signers());

        assertEq(registry.reportCount(), 2);
        assertEq(registry.getReport(0).result.reportHash, firstHash, "the earlier record is untouched");
        assertEq(registry.getReport(0).result.overallTrust, 0);
        assertEq(registry.getReport(1).result.overallTrust, 99);
        assertEq(registry.historyCount(CHAIN, ASSET_A), 2);
    }

    function test_getReportOutOfRangeReverts() public {
        _seed(ASSET_A, 1);
        vm.expectRevert();
        registry.getReport(1);
    }

    // -----------------------------------------------------------------------
    // an unbounded limit saturates
    // -----------------------------------------------------------------------

    /// @notice `type(uint256).max` means "everything from here" in both paging functions.
    /// @dev These previously computed `offset + limit` under checked arithmetic, so a maximal limit
    ///      at any offset inside the log panicked instead of returning the tail. Passing a huge
    ///      limit to mean "no limit" is a common idiom and callers should not have to read
    ///      reportCount first just to avoid an overflow, so the addition is now unchecked with an
    ///      explicit wrap test. This test is the guard against that regressing.
    function test_unboundedLimitSaturatesToTheEndOfTheLog() public {
        _seed(ASSET_A, 3);

        assertEq(registry.getReports(0, type(uint256).max).length, 3, "the whole log");
        assertEq(registry.getReports(1, type(uint256).max).length, 2, "the tail, not a panic");
        assertEq(registry.getReports(2, type(uint256).max).length, 1);
        assertEq(registry.getReports(3, type(uint256).max).length, 0, "offset past the end is still empty");

        assertEq(registry.history(CHAIN, ASSET_A, 1, type(uint256).max).length, 2);
        assertEq(registry.history(CHAIN, ASSET_A, 3, type(uint256).max).length, 0);

        // A maximal limit returns exactly what an exact limit returns.
        ReportRecord[] memory saturated = registry.getReports(1, type(uint256).max);
        ReportRecord[] memory exact = registry.getReports(1, 2);
        assertEq(saturated.length, exact.length);
        assertEq(saturated[0].result.reportHash, exact[0].result.reportHash);
        assertEq(saturated[1].result.reportHash, exact[1].result.reportHash);
    }

    /// @notice Saturation holds for any offset and any limit, including the values that used to wrap.
    function testFuzz_pagingNeverRevertsOnAnyWindow(uint8 total, uint256 offset, uint256 limit) public {
        total = uint8(bound(total, 1, 8));
        _seed(ASSET_A, total);

        ReportRecord[] memory page = registry.getReports(offset, limit);
        uint256[] memory ids = registry.history(CHAIN, ASSET_A, offset, limit);

        uint256 expected;
        if (offset >= total) {
            expected = 0;
        } else {
            unchecked {
                uint256 end = offset + limit;
                if (end > total || end < offset) end = total;
                expected = end - offset;
            }
        }
        assertEq(page.length, expected);
        assertEq(ids.length, expected);
    }

    // -----------------------------------------------------------------------
    // chronology
    // -----------------------------------------------------------------------

    /// @notice Several reports about one asset are kept in the order they were committed, each with
    ///         its own commitment point, and the earlier ones are never rewritten.
    function test_multipleReportsForOneAssetKeepChronologicalOrder() public {
        uint256 baseTime = 1_788_900_000;
        uint8[3] memory scores = [uint8(11), uint8(22), uint8(33)];
        for (uint256 i = 0; i < 3; ++i) {
            vm.warp(baseTime + i * 1 days);
            vm.roll(60_000_000 + i * 1000);
            vm.prank(hub);
            registry.recordReport(_meta(i + 1), _result(ASSET_A, scores[i]), _signers());
        }

        uint256[] memory ids = registry.history(CHAIN, ASSET_A, 0, type(uint256).max);
        assertEq(ids.length, 3, "three records, not one overwritten three times");
        for (uint256 i = 0; i < 3; ++i) {
            ReportRecord memory record = registry.getReport(ids[i]);
            assertEq(ids[i], i, "history ids ascend with commitment order");
            assertEq(record.result.overallTrust, scores[i], "the score of that commitment");
            assertEq(record.committedAt, baseTime + i * 1 days, "each record keeps its own timestamp");
            assertEq(record.jobId, i + 1, "each record keeps its own job");
        }
    }

    // -----------------------------------------------------------------------
    // latestSummary and latestSummaryForToken
    // -----------------------------------------------------------------------

    /// @notice The three latest-reads describe the same record.
    function test_latestReadsAgreeWithEachOther() public {
        _seed(ASSET_A, 3);

        (bool exists, ReportRecord memory record) = registry.latest(CHAIN, ASSET_A);
        (
            bool summaryExists,
            uint256 reportId,
            uint8 overallTrust,
            uint64 flags,
            uint32 engineVersion,
            uint64 committedAt
        ) = registry.latestSummary(CHAIN, ASSET_A);

        assertEq(summaryExists, exists, "both agree the asset has a report");
        assertEq(reportId, 2, "the summary points at the newest record");
        assertEq(overallTrust, record.result.overallTrust, "same score");
        assertEq(flags, record.result.flags, "same flags");
        assertEq(engineVersion, record.result.engineVersion, "same engine");
        assertEq(committedAt, record.committedAt, "same commitment point");
    }

    /// @notice The token-address overload is the assetId overload with the conversion done for you.
    function test_latestSummaryForTokenMatchesLatestSummary() public {
        address tokenAddress = 0x6CCe60df223EA78543D1AAa5dAa2e5ba91Feb0cB;
        bytes32 assetId = registry.evmAssetId(tokenAddress);
        vm.prank(hub);
        registry.recordReport(_meta(5), _result(assetId, 64), _signers());

        (bool exists, uint256 reportId, uint8 overallTrust,,, uint64 committedAt) =
            registry.latestSummary(CHAIN, assetId);
        (bool tokenExists, uint256 tokenReportId, uint8 tokenTrust,,, uint64 tokenCommittedAt) =
            registry.latestSummaryForToken(CHAIN, tokenAddress);

        assertTrue(exists, "the asset has a report");
        assertEq(tokenExists, exists, "the overload agrees the asset has a report");
        assertEq(tokenReportId, reportId, "same record");
        assertEq(tokenTrust, overallTrust, "same score");
        assertEq(tokenCommittedAt, committedAt, "same commitment point");
    }

    /// @notice An unaudited asset reports nothing rather than reverting, in both summary reads.
    function test_latestSummaryOfAnUnauditedAssetIsEmpty() public view {
        (bool exists, uint256 reportId, uint8 overallTrust, uint64 flags, uint32 engineVersion, uint64 committedAt) =
            registry.latestSummary(CHAIN, ASSET_B);
        assertFalse(exists, "no report exists");
        assertEq(reportId, 0);
        assertEq(overallTrust, 0);
        assertEq(flags, 0);
        assertEq(engineVersion, 0);
        assertEq(committedAt, 0);

        (bool tokenExists,,,,,) = registry.latestSummaryForToken(CHAIN, address(0xdead));
        assertFalse(tokenExists, "no report exists for the token either");
    }

    // -----------------------------------------------------------------------
    // scoreHistory
    // -----------------------------------------------------------------------

    /// @notice The chart read returns the scores in commitment order, paired with their timestamps.
    function test_scoreHistoryIsInCommitmentOrder() public {
        uint256 baseTime = 1_788_900_000;
        for (uint256 i = 0; i < 4; ++i) {
            vm.warp(baseTime + i * 1 hours);
            vm.prank(hub);
            registry.recordReport(_meta(i + 1), _result(ASSET_A, uint8(70 - i * 10)), _signers());
        }

        (uint64[] memory committedAt, uint8[] memory overallTrust) =
            registry.scoreHistory(CHAIN, ASSET_A, 0, type(uint256).max);
        assertEq(committedAt.length, 4, "one point per report");
        assertEq(overallTrust.length, committedAt.length, "the two arrays are parallel");
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(overallTrust[i], uint8(70 - i * 10), "scores in commitment order, oldest first");
            assertEq(committedAt[i], baseTime + i * 1 hours, "timestamps in commitment order");
        }
    }

    /// @notice scoreHistory pages and saturates exactly the way history does.
    function test_scoreHistoryPagesLikeHistory() public {
        _seed(ASSET_A, 5);

        (uint64[] memory times, uint8[] memory scores) = registry.scoreHistory(CHAIN, ASSET_A, 1, 2);
        assertEq(scores.length, 2, "the requested window");
        assertEq(times.length, 2, "the two arrays are parallel");
        assertEq(scores[0], 1);
        assertEq(scores[1], 2);

        (, uint8[] memory truncated) = registry.scoreHistory(CHAIN, ASSET_A, 3, 100);
        assertEq(truncated.length, 2, "truncated at the end rather than reverting");

        (, uint8[] memory saturated) = registry.scoreHistory(CHAIN, ASSET_A, 1, type(uint256).max);
        assertEq(saturated.length, 4, "a maximal limit means the tail, not a panic");

        (, uint8[] memory pastEnd) = registry.scoreHistory(CHAIN, ASSET_A, 5, type(uint256).max);
        assertEq(pastEnd.length, 0, "offset past the end is empty");

        (uint64[] memory noneTimes, uint8[] memory noneScores) = registry.scoreHistory(CHAIN, ASSET_B, 0, 10);
        assertEq(noneTimes.length, 0, "an unknown asset has no points");
        assertEq(noneScores.length, 0, "and no scores");
    }

    /// @notice Any window of scoreHistory is exactly the same window history returns.
    function testFuzz_scoreHistoryAgreesWithHistory(uint8 total, uint256 offset, uint256 limit) public {
        total = uint8(bound(total, 1, 8));
        _seed(ASSET_A, total);

        uint256[] memory ids = registry.history(CHAIN, ASSET_A, offset, limit);
        (uint64[] memory times, uint8[] memory scores) = registry.scoreHistory(CHAIN, ASSET_A, offset, limit);

        assertEq(scores.length, ids.length, "the same number of points as ids");
        assertEq(times.length, ids.length, "the two arrays are parallel");
        for (uint256 i = 0; i < ids.length; ++i) {
            ReportRecord memory record = registry.getReport(ids[i]);
            assertEq(scores[i], record.result.overallTrust, "the score of that very record");
            assertEq(times[i], record.committedAt, "the commitment point of that very record");
        }
    }

    // -----------------------------------------------------------------------
    // the stored hash is the submitted hash
    // -----------------------------------------------------------------------

    /// @notice The report hash is stored byte for byte, so an off-chain document can be checked
    ///         against the record without trusting whoever served it.
    function test_reportHashIsStoredVerbatim() public {
        AuditResult memory input = _result(ASSET_A, 42);
        input.reportHash = keccak256("the canonical report body");
        vm.prank(hub);
        uint256 reportId = registry.recordReport(_meta(3), input, _signers());

        assertEq(
            registry.getReport(reportId).result.reportHash,
            keccak256("the canonical report body"),
            "the record holds the submitted hash"
        );
        (, ReportRecord memory record) = registry.latest(CHAIN, ASSET_A);
        assertEq(record.result.reportHash, input.reportHash, "and latest returns the same hash");
        assertEq(record.result.reportURI, input.reportURI, "with the URI that pins the document");
    }
}
