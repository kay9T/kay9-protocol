// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {KAY9AuditorRegistry} from "../../src/KAY9AuditorRegistry.sol";
import {KAY9ScanRegistry, ScanBatch} from "../../src/KAY9ScanRegistry.sol";

/// @title KAY9ScanRegistryTest
/// @notice Proves that the automatic basic-scan record is append-only, that only an authorised
///         scanner may add to it, and above all that a scan cannot be shown as
///         committed unless it really is in the batch it claims.
/// @dev The Merkle checks are the important ones. Everything else in this contract is bookkeeping;
///      `verifyScan` is the part a third party relies on instead of trusting kay9.io, so a proof
///      implementation that accepted a forged leaf would quietly void the whole guarantee.
contract KAY9ScanRegistryTest is Test {
    KAY9AuditorRegistry internal auditors;
    KAY9ScanRegistry internal scans;

    address internal owner = address(0xB0B);
    address internal auditor = address(0xA1);
    address internal scanner = address(0x5CA1);
    address internal stranger = address(0xBAD);
    address internal guardian = address(0x6A2D);

    bytes32 internal constant CHAIN = keccak256("eip155:4663");

    function setUp() public {
        address[] memory set = new address[](1);
        set[0] = auditor;
        auditors = new KAY9AuditorRegistry(owner, set, 1);
        address[] memory initial = new address[](1);
        initial[0] = scanner;
        scans = new KAY9ScanRegistry(owner, guardian, initial);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _assetId(uint160 raw) internal pure returns (bytes32) {
        return bytes32(uint256(raw));
    }

    function _summary(uint160 raw, uint8 score) internal pure returns (KAY9ScanRegistry.ScanSummary memory) {
        return KAY9ScanRegistry.ScanSummary({
            chainKey: CHAIN,
            assetId: _assetId(raw),
            overallTrust: score,
            confidence: 90,
            flags: 1 << 3,
            scannedAtBlock: 1_000
        });
    }

    /// @notice The leaf for one of the summaries above, computed here rather than by the contract.
    /// @dev Deliberately not a call to `scans.scanLeaf`. A helper that calls the contract would be
    ///      an external call, and `vm.prank` applies to the next call only, so building a leaf as an
    ///      argument to a pranked commit would silently spend the prank and the commit would arrive
    ///      from the test contract. `test_theLeafDefinitionIsStable` pins the contract's definition
    ///      against a written-out expectation, so this copy cannot drift unnoticed.
    function _leaf(uint160 raw, uint8 score) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        CHAIN,
                        bytes32(uint256(raw)),
                        score,
                        uint8(90),
                        uint64(1) << 3,
                        uint32(3),
                        uint64(1_000),
                        keccak256("body")
                    )
                )
            )
        );
    }

    /// @notice Hashes a sorted pair the way the contract does.
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    // ---------------------------------------------------------------------------------------
    // Authorisation
    // ---------------------------------------------------------------------------------------

    /// @notice An authorised scanner may commit.
    function test_scannerMayCommit() public {
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(1, 40);
        vm.prank(scanner);
        uint256 batchId = scans.commitScanBatch(_leaf(1, 40), uint32(one.length), 3, "ipfs://batch-0", one);
        assertEq(batchId, 0, "the first batch is index zero");
        assertEq(scans.batchCount(), 1, "and the log grew by one");
    }

    /// @notice An auditor is not a scanner by default: one auditor key cannot move a headline
    ///         score that the report path needs a quorum for.
    function test_anAuditorIsNotAScannerByDefault() public {
        assertTrue(auditors.isAuditor(auditor), "the auditor is an auditor");
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(2, 10);
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.NotAScanner.selector, auditor));
        scans.commitScanBatch(_leaf(2, 10), uint32(one.length), 3, "ipfs://batch-1", one);
    }

    /// @notice The constructor names the owner and the scanners, so the deploying key never owns it.
    function test_theOwnerAndScannersAreSetAtDeployment() public view {
        assertEq(scans.owner(), owner, "owned by governance from the first block");
        assertEq(scans.guardian(), guardian, "the guardian is fixed");
        assertTrue(scans.isScanner(scanner), "the initial scanner is authorised");
        assertFalse(scans.isScanner(address(this)), "the deploying contract is not");
    }

    /// @notice The guardian revokes a scanner at once, without the timelock.
    function test_theGuardianRevokesAScannerAtOnce() public {
        vm.prank(guardian);
        scans.revokeScanner(scanner);
        assertFalse(scans.isScanner(scanner), "revoked");

        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(2, 10);
        vm.prank(scanner);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.NotAScanner.selector, scanner));
        scans.commitScanBatch(_leaf(2, 10), uint32(one.length), 3, "ipfs://batch-1", one);
    }

    /// @notice Nobody but the guardian can revoke, and the guardian cannot authorise.
    function test_onlyTheGuardianRevokesAndItCannotAuthorise() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.NotGuardian.selector, stranger));
        scans.revokeScanner(scanner);

        vm.prank(guardian);
        vm.expectRevert();
        scans.setScanner(stranger, true);
    }

    /// @notice The owner can replace the guardian, and the old one loses its power.
    function test_theOwnerReplacesTheGuardian() public {
        address next = address(0x6A2E);
        vm.prank(guardian);
        vm.expectRevert();
        scans.setGuardian(next);

        vm.prank(owner);
        scans.setGuardian(next);
        assertEq(scans.guardian(), next);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.NotGuardian.selector, guardian));
        scans.revokeScanner(scanner);

        vm.prank(next);
        scans.revokeScanner(scanner);
        assertFalse(scans.isScanner(scanner));
    }

    /// @notice Ownership cannot be renounced.
    function test_renounceIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(KAY9ScanRegistry.RenounceDisabled.selector);
        scans.renounceOwnership();
    }

    /// @notice A summary score above 100 is refused.
    function test_aScoreAbove100IsRefused() public {
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(2, 101);
        vm.prank(scanner);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.ScoreOutOfRange.selector, uint8(101)));
        scans.commitScanBatch(bytes32(uint256(1)), 1, 3, "ipfs://batch-1", one);
    }

    /// @notice A batch cannot claim to hold more than MAX_BATCH scans, whatever it indexes.
    function test_aBatchCannotClaimMoreThanTheCap() public {
        uint32 max = scans.MAX_BATCH();
        KAY9ScanRegistry.ScanSummary[] memory none = new KAY9ScanRegistry.ScanSummary[](0);
        vm.prank(scanner);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.BatchTooLarge.selector, uint256(max) + 1, max));
        scans.commitScanBatch(bytes32(uint256(1)), max + 1, 3, "ipfs://claims-too-much", none);
    }

    /// @notice Nobody else may commit.
    function test_strangerCannotCommit() public {
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(3, 55);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.NotAScanner.selector, stranger));
        scans.commitScanBatch(_leaf(3, 55), uint32(one.length), 3, "ipfs://batch-2", one);
    }

    /// @notice A removed scanner cannot commit again, and its old batches stand.
    function test_removingAScannerDoesNotRewriteHistory() public {
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(4, 20);
        vm.prank(scanner);
        scans.commitScanBatch(_leaf(4, 20), uint32(one.length), 3, "ipfs://batch-3", one);

        vm.prank(owner);
        scans.setScanner(scanner, false);

        vm.prank(scanner);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.NotAScanner.selector, scanner));
        scans.commitScanBatch(_leaf(5, 20), uint32(one.length), 3, "ipfs://batch-4", one);

        assertEq(scans.batchCount(), 1, "the batch it committed while authorised is still there");
        assertEq(scans.getBatch(0).scanner, scanner, "and still names who committed it");
    }

    /// @notice Only the owner may authorise a scanner.
    function test_onlyOwnerAuthorisesScanners() public {
        vm.prank(stranger);
        vm.expectRevert();
        scans.setScanner(stranger, true);
    }

    // ---------------------------------------------------------------------------------------
    // Batch shape
    // ---------------------------------------------------------------------------------------

    /// @notice A batch must carry at least one scan.
    function test_emptyBatchIsRefused() public {
        KAY9ScanRegistry.ScanSummary[] memory none = new KAY9ScanRegistry.ScanSummary[](0);
        vm.prank(scanner);
        vm.expectRevert(KAY9ScanRegistry.EmptyBatch.selector);
        scans.commitScanBatch(bytes32(uint256(1)), uint32(none.length), 3, "ipfs://empty", none);
    }

    /// @notice A batch must say where its document is, or the root commits to nothing findable.
    function test_batchWithoutAUriIsRefused() public {
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(6, 30);
        vm.prank(scanner);
        vm.expectRevert(KAY9ScanRegistry.MissingUri.selector);
        scans.commitScanBatch(_leaf(6, 30), uint32(one.length), 3, "", one);
    }

    /// @notice A batch larger than the cap is refused, with its own error.
    function test_oversizeBatchIsRefused() public {
        uint32 max = scans.MAX_BATCH();
        KAY9ScanRegistry.ScanSummary[] memory many = new KAY9ScanRegistry.ScanSummary[](uint256(max) + 1);
        for (uint256 i = 0; i < many.length; ++i) {
            many[i] = _summary(uint160(i + 100), 50);
        }
        vm.prank(scanner);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.BatchTooLarge.selector, uint256(max) + 1, max));
        scans.commitScanBatch(bytes32(uint256(9)), uint32(many.length), 3, "ipfs://too-big", many);
    }

    /// @notice A batch of one is a legal batch, so an urgent single scan needs no special path.
    function test_aBatchOfOneIsLegal() public {
        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(7, 12);
        bytes32 leaf = _leaf(7, 12);
        vm.prank(scanner);
        uint256 batchId = scans.commitScanBatch(leaf, uint32(one.length), 3, "ipfs://single", one);

        // With one leaf the root is the leaf, so the proof is empty.
        bytes32[] memory noProof = new bytes32[](0);
        assertTrue(scans.verifyScan(batchId, leaf, noProof), "a single-leaf batch verifies with no proof");
    }

    // ---------------------------------------------------------------------------------------
    // Merkle verification, the part a third party actually relies on
    // ---------------------------------------------------------------------------------------

    /// @notice Every leaf of a four-scan batch verifies against the committed root.
    function test_everyLeafInABatchVerifies() public {
        bytes32 a = _leaf(11, 10);
        bytes32 b = _leaf(12, 20);
        bytes32 c = _leaf(13, 30);
        bytes32 d = _leaf(14, 40);

        bytes32 ab = _pair(a, b);
        bytes32 cd = _pair(c, d);
        bytes32 root = _pair(ab, cd);

        KAY9ScanRegistry.ScanSummary[] memory four = new KAY9ScanRegistry.ScanSummary[](4);
        four[0] = _summary(11, 10);
        four[1] = _summary(12, 20);
        four[2] = _summary(13, 30);
        four[3] = _summary(14, 40);

        vm.prank(scanner);
        uint256 batchId = scans.commitScanBatch(root, uint32(four.length), 3, "ipfs://four", four);

        bytes32[] memory proofA = new bytes32[](2);
        proofA[0] = b;
        proofA[1] = cd;
        assertTrue(scans.verifyScan(batchId, a, proofA), "leaf a verifies");

        bytes32[] memory proofD = new bytes32[](2);
        proofD[0] = c;
        proofD[1] = ab;
        assertTrue(scans.verifyScan(batchId, d, proofD), "leaf d verifies");
    }

    /// @notice A scan that is not in the batch does not verify, however plausible it looks.
    function test_aForgedScanDoesNotVerify() public {
        bytes32 a = _leaf(21, 10);
        bytes32 b = _leaf(22, 20);
        bytes32 root = _pair(a, b);

        KAY9ScanRegistry.ScanSummary[] memory two = new KAY9ScanRegistry.ScanSummary[](2);
        two[0] = _summary(21, 10);
        two[1] = _summary(22, 20);
        vm.prank(scanner);
        uint256 batchId = scans.commitScanBatch(root, uint32(two.length), 3, "ipfs://two", two);

        // The same asset with a flattering score is a different leaf and must not verify.
        bytes32 flattering = _leaf(21, 1);
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        assertFalse(scans.verifyScan(batchId, flattering, proof), "a better score is not in this batch");

        // An asset that was never scanned at all must not verify either.
        bytes32 absent = _leaf(99, 10);
        assertFalse(scans.verifyScan(batchId, absent, proof), "an unscanned asset is not in this batch");
    }

    /// @notice A proof from one batch does not verify against another.
    function test_aProofDoesNotTransferBetweenBatches() public {
        bytes32 a = _leaf(31, 10);
        bytes32 b = _leaf(32, 20);
        bytes32 rootOne = _pair(a, b);

        KAY9ScanRegistry.ScanSummary[] memory two = new KAY9ScanRegistry.ScanSummary[](2);
        two[0] = _summary(31, 10);
        two[1] = _summary(32, 20);
        vm.prank(scanner);
        uint256 first = scans.commitScanBatch(rootOne, uint32(two.length), 3, "ipfs://first", two);

        KAY9ScanRegistry.ScanSummary[] memory other = new KAY9ScanRegistry.ScanSummary[](1);
        other[0] = _summary(33, 30);
        vm.prank(scanner);
        uint256 second = scans.commitScanBatch(_leaf(33, 30), uint32(other.length), 3, "ipfs://second", other);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = b;
        assertTrue(scans.verifyScan(first, a, proof), "the proof works against its own batch");
        assertFalse(scans.verifyScan(second, a, proof), "and not against another");
    }

    /// @notice Verifying against a batch that does not exist reverts rather than answering false.
    /// @dev False would be indistinguishable from "not in the batch", and a caller checking an id
    ///      it got wrong deserves to be told rather than quietly shown a negative.
    function test_verifyingAnUnknownBatchReverts() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.UnknownBatch.selector, uint256(7)));
        scans.verifyScan(7, bytes32(uint256(1)), proof);
    }

    /// @notice The leaf definition is stable, because third parties hash it themselves.
    function test_theLeafDefinitionIsStable() public view {
        bytes32 expected = keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        CHAIN,
                        bytes32(uint256(0x1234)),
                        uint8(42),
                        uint8(80),
                        uint64(5),
                        uint32(3),
                        uint64(900),
                        keccak256("report")
                    )
                )
            )
        );
        assertEq(
            scans.scanLeaf(CHAIN, bytes32(uint256(0x1234)), 42, 80, 5, 3, 900, keccak256("report")),
            expected,
            "the leaf is a double keccak of the fields in the documented order"
        );

        // And the copy this test file hashes for itself agrees with the contract, so a change to
        // one without the other fails here rather than turning every proof test green on a tree
        // nobody would ever build in production.
        assertEq(
            _leaf(11, 10),
            scans.scanLeaf(CHAIN, _assetId(11), 10, 90, uint64(1) << 3, 3, 1_000, keccak256("body")),
            "the test's leaf helper matches the contract's"
        );
    }

    // ---------------------------------------------------------------------------------------
    // Latest score, and the difference between zero and unscanned
    // ---------------------------------------------------------------------------------------

    /// @notice An unscanned asset reports as unscanned, not as the worst possible score.
    function test_unscannedIsDistinguishableFromZero() public view {
        (bool scanned, uint256 batchId, uint8 score) = scans.latestScan(CHAIN, _assetId(0xDEAD));
        assertFalse(scanned, "never scanned");
        assertEq(batchId, 0, "and no batch");
        assertEq(score, 0, "and the score is meaningless, which is why `scanned` exists");
    }

    /// @notice A later scan supersedes an earlier one, and both batches remain.
    function test_aLaterScanSupersedesWithoutErasing() public {
        KAY9ScanRegistry.ScanSummary[] memory first = new KAY9ScanRegistry.ScanSummary[](1);
        first[0] = _summary(41, 88);
        vm.prank(scanner);
        uint256 batchOne = scans.commitScanBatch(_leaf(41, 88), uint32(first.length), 3, "ipfs://before", first);

        KAY9ScanRegistry.ScanSummary[] memory second = new KAY9ScanRegistry.ScanSummary[](1);
        second[0] = _summary(41, 43);
        vm.prank(scanner);
        uint256 batchTwo = scans.commitScanBatch(_leaf(41, 43), uint32(second.length), 3, "ipfs://after", second);

        (bool scanned, uint256 batchId, uint8 score) = scans.latestScan(CHAIN, _assetId(41));
        assertTrue(scanned, "the asset has been scanned");
        assertEq(score, 43, "the latest score is the one that shows");
        assertEq(batchId, batchTwo, "and it points at the batch that carried it");

        assertEq(scans.batchCount(), 2, "both batches are still in the log");
        assertEq(scans.getBatch(batchOne).root, _leaf(41, 88), "including the earlier root");
    }

    /// @notice The log only ever grows.
    function test_theLogOnlyGrows() public {
        for (uint160 i = 1; i <= 5; ++i) {
            KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
            one[0] = _summary(i, uint8(i * 10));
            vm.prank(scanner);
            scans.commitScanBatch(_leaf(i, uint8(i * 10)), uint32(one.length), 3, "ipfs://n", one);
            assertEq(scans.batchCount(), i, "one more batch each time");
        }
    }

    // ---------------------------------------------------------------------------------------
    // Committing more scans than are indexed
    // ---------------------------------------------------------------------------------------

    /// @notice A scan left out of the on-chain index is still committed to the root.
    /// @dev This is the whole point of separating the two. Indexing an asset costs a cold storage
    ///      write; committing it to the root costs nothing extra. So a batch of ten thousand scans
    ///      can be committed for the price of one transaction, with only the handful anybody has
    ///      actually bought given the one-call `latestScan` read — and every one of the ten
    ///      thousand is still provable by anybody holding the batch document.
    function test_aScanOutsideTheIndexIsStillProvable() public {
        bytes32 indexedLeaf = _leaf(61, 10);
        bytes32 unindexedLeaf = _leaf(62, 90);
        bytes32 root = _pair(indexedLeaf, unindexedLeaf);

        KAY9ScanRegistry.ScanSummary[] memory one = new KAY9ScanRegistry.ScanSummary[](1);
        one[0] = _summary(61, 10);

        vm.prank(scanner);
        uint256 batchId = scans.commitScanBatch(root, 2, 3, "ipfs://two-one-indexed", one);

        assertEq(scans.getBatch(batchId).count, 2, "the batch says it holds two scans");

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = indexedLeaf;
        assertTrue(scans.verifyScan(batchId, unindexedLeaf, proof), "the unindexed scan verifies");

        (bool scanned,,) = scans.latestScan(CHAIN, _assetId(62));
        assertFalse(scanned, "and is not in the on-chain index, which is what made it cheap");

        (bool indexedScanned,, uint8 score) = scans.latestScan(CHAIN, _assetId(61));
        assertTrue(indexedScanned);
        assertEq(score, 10);
    }

    /// @notice A batch cannot claim to hold fewer scans than it indexes.
    function test_aBatchCannotIndexMoreThanItHolds() public {
        KAY9ScanRegistry.ScanSummary[] memory two = new KAY9ScanRegistry.ScanSummary[](2);
        two[0] = _summary(71, 10);
        two[1] = _summary(72, 20);
        vm.prank(scanner);
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.CountTooSmall.selector, uint32(1), uint256(2)));
        scans.commitScanBatch(bytes32(uint256(7)), 1, 3, "ipfs://contradictory", two);
    }

    /// @notice A batch may commit a root over scans and index none of them.
    /// @dev The cheapest legal commit: a root, a count and a document, for a fixed cost whatever
    ///      the batch holds. Nothing about it is second class — every scan in it is provable.
    function test_aBatchMayIndexNothing() public {
        KAY9ScanRegistry.ScanSummary[] memory none = new KAY9ScanRegistry.ScanSummary[](0);
        vm.prank(scanner);
        uint256 batchId = scans.commitScanBatch(_leaf(81, 40), 500, 3, "ipfs://root-only", none);
        assertEq(scans.getBatch(batchId).count, 500);

        bytes32[] memory noProof = new bytes32[](0);
        assertTrue(scans.verifyScan(batchId, _leaf(81, 40), noProof), "still provable against the root");
    }

    /// @notice Reading a batch that does not exist reverts.
    function test_readingAnUnknownBatchReverts() public {
        vm.expectRevert(abi.encodeWithSelector(KAY9ScanRegistry.UnknownBatch.selector, uint256(3)));
        scans.getBatch(3);
    }
}
