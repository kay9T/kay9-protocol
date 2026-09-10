// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {KAY9AuditorRegistry} from "./KAY9AuditorRegistry.sol";

/// @notice One committed batch of basic scans.
/// @dev The scan data itself is not on-chain. `root` commits to it, `uri` says where the batch
///      document lives, and `count` says how many scans it contains. Anyone can fetch the
///      document, recompute the leaves, rebuild the tree and check the root.
///
///      `count` is how many scans the batch holds, which is not necessarily how many were indexed
///      on-chain — see `commitScanBatch`. Every scan is in the tree either way; the index is a
///      convenience, not the record.
struct ScanBatch {
    bytes32 root;
    uint32 count;
    uint32 engineVersion;
    uint64 committedAt;
    uint64 committedBlock;
    address scanner;
    string uri;
}

/// @title KAY9ScanRegistry
/// @notice The permanent record of automatic basic scans, committed in Merkle batches.
///
/// @dev **This registry deliberately carries a weaker claim than KAY9Registry, and the difference
///      is the reason it is a separate contract rather than another function on that one.**
///
///      A deep or forensic report in `KAY9Registry` is a claim that two of three independent
///      auditors computed the same result and signed it. A basic scan is not a claim of that kind
///      at all. Basic scan reads only cheap public state at a stated block, it runs in the
///      visitor's own browser as readily as in a scanner, and anyone holding the asset id and the
///      block can recompute it exactly. So a single authorised scanner may commit a batch, and the
///      guarantee offered is reproducibility rather than consensus: the record says "this is what
///      the published engine computes for these assets at these blocks, and here is the hash so
///      you can check we published what we ran".
///
///      Putting both in one contract would have let a reader mistake one for the other, and the
///      whole product depends on that distinction being legible.
///
///      Batching is the design from the first day rather than a later migration. A basic scan is
///      automatic and unsolicited, so the number of them is set by how many tokens launch, not by
///      how many people pay; one transaction per scan makes the cost of watching a chain scale
///      with that chain's activity, which is the wrong shape. One transaction per batch makes it
///      scale with time instead. A batch of one is a legal batch, so a single urgent scan is not
///      a special case in the code.
/// @custom:security-contact security@kay9.io
contract KAY9ScanRegistry is Ownable2Step {
    /// @notice Emitted for every committed batch. The website's whole scan stream is these events.
    /// @param batchId The index of the new batch.
    /// @param root The Merkle root over the batch's scan leaves.
    /// @param count How many scans the batch contains.
    /// @param engineVersion The engine that produced them.
    /// @param uri Where the batch document lives, content-addressed.
    /// @param scanner The scanner that committed it.
    event ScanBatchCommitted(
        uint256 indexed batchId,
        bytes32 indexed root,
        uint32 count,
        uint32 engineVersion,
        string uri,
        address indexed scanner
    );

    /// @notice Emitted when an asset's most recent basic score changes.
    /// @dev Separate from the batch event and indexed by asset, so a reader can follow one token
    ///      without replaying every batch ever committed. The score itself is on-chain here
    ///      because it is the one number every surface shows, and making a reader fetch a batch
    ///      document to learn it would put an off-chain dependency on the front page.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier within that chain.
    /// @param batchId The batch that carried the scan.
    /// @param overallTrust The headline trust score, 0 worst to 100 most trustworthy.
    /// @param confidence The engine's confidence in it, 0 to 100.
    /// @param flags The flag bitmask.
    /// @param scannedAtBlock The block the scan was pinned to.
    event AssetScanned(
        bytes32 indexed chainKey,
        bytes32 indexed assetId,
        uint256 indexed batchId,
        uint8 overallTrust,
        uint8 confidence,
        uint64 flags,
        uint64 scannedAtBlock
    );

    /// @notice Emitted when governance authorises or removes a scanner.
    /// @param scanner The address.
    /// @param allowed Whether it may commit batches.
    event ScannerUpdated(address indexed scanner, bool allowed);

    /// @notice Thrown when a constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a caller that is neither an authorised scanner nor an auditor commits.
    /// @param caller The rejected caller.
    error NotAScanner(address caller);

    /// @notice Thrown when a batch would carry no scans.
    error EmptyBatch();

    /// @notice Thrown when a batch carries more scans than one transaction may commit.
    /// @param supplied The number of scans supplied.
    /// @param maximum The largest batch allowed.
    error BatchTooLarge(uint256 supplied, uint32 maximum);

    /// @notice Thrown when a batch carries no location for its document.
    error MissingUri();

    /// @notice Thrown when a batch claims to hold fewer scans than it indexes on-chain.
    /// @param count The batch's stated size.
    /// @param indexed_ The number of summaries supplied.
    error CountTooSmall(uint32 count, uint256 indexed_);

    /// @notice Thrown when a batch id does not exist.
    /// @param batchId The unknown batch.
    error UnknownBatch(uint256 batchId);

    /// @notice The most scans one transaction may index on-chain.
    /// @dev Bounds the loop, not the batch: a batch may commit a root over any number of scans,
    ///      and this caps how many of them also get a storage write and an event. Measured at
    ///      about 24,700 gas each, 500 is 12.4 million gas in one transaction.
    uint32 public constant MAX_BATCH = 500;

    /// @notice The auditor set. Its members may always commit, without a separate authorisation.
    /// @dev The auditors already run the engine for deep and forensic work, so requiring a second
    ///      registration for the cheapest tier would be bookkeeping with no security value.
    KAY9AuditorRegistry public immutable auditors;

    /// @notice Addresses authorised to commit batches, beyond the auditor set.
    mapping(address scanner => bool allowed) public isScanner;

    /// @notice Every batch ever committed, in commitment order.
    ScanBatch[] private _batches;

    /// @notice The most recent basic scan of one asset.
    /// @dev Packed into a single storage slot on purpose. Two separate mappings cost two cold
    ///      writes per asset, and at 20,000 gas each that was 85 per cent of what committing a
    ///      batch cost: a 500-scan batch measured 21.3 million gas, 42,531 per scan. One slot
    ///      halves the dominant cost of the only thing this contract does at volume.
    ///
    ///      `batchIdPlusOne` is offset by one so that zero means "never scanned", which is what
    ///      lets `latestScan` distinguish that from an asset that scored zero — the worst trust
    ///      score the engine can give.
    struct LatestScan {
        uint248 batchIdPlusOne;
        uint8 overallTrust;
    }

    /// @notice The most recent basic scan per asset.
    mapping(bytes32 assetKeyHash => LatestScan) private _latest;

    /// @notice Deploys the scan registry.
    /// @param owner_ The owner, which in production is the TimelockController.
    /// @param auditors_ The auditor set whose members may commit.
    constructor(address owner_, KAY9AuditorRegistry auditors_) Ownable(owner_) {
        if (address(auditors_) == address(0)) revert ZeroAddress();
        auditors = auditors_;
    }

    /// @notice The composite key that groups scans of the same asset.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier within that chain.
    /// @return The asset key.
    function assetKey(bytes32 chainKey, bytes32 assetId) public pure returns (bytes32) {
        return keccak256(abi.encode(chainKey, assetId));
    }

    /// @notice The leaf a scan contributes to its batch's Merkle tree.
    /// @dev The definition is part of the protocol, not an implementation detail: a third party
    ///      verifying a scan has to hash exactly these fields in exactly this order. It is
    ///      double-hashed so that a leaf can never be confused with an internal node, which is the
    ///      standard defence against a second-preimage attack on a Merkle tree.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @param overallTrust The headline trust score.
    /// @param confidence The engine's confidence.
    /// @param flags The flag bitmask.
    /// @param engineVersion The engine that produced the scan.
    /// @param scannedAtBlock The block the scan was pinned to.
    /// @param reportHash The keccak256 of the canonical scan document for this asset.
    /// @return The leaf hash.
    function scanLeaf(
        bytes32 chainKey,
        bytes32 assetId,
        uint8 overallTrust,
        uint8 confidence,
        uint64 flags,
        uint32 engineVersion,
        uint64 scannedAtBlock,
        bytes32 reportHash
    ) public pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        chainKey, assetId, overallTrust, confidence, flags, engineVersion, scannedAtBlock, reportHash
                    )
                )
            )
        );
    }

    /// @notice One asset's headline numbers, for the per-asset event a batch emits.
    struct ScanSummary {
        bytes32 chainKey;
        bytes32 assetId;
        uint8 overallTrust;
        uint8 confidence;
        uint64 flags;
        uint64 scannedAtBlock;
    }

    /// @notice Commits a batch of basic scans.
    ///
    /// @dev **Every scan in the batch is committed to `root`. Only the ones passed in `summaries`
    ///      are indexed on-chain.** That separation is a cost decision with a measured basis.
    ///
    ///      Measured on this contract: writing an asset's headline numbers costs about 24,700 gas,
    ///      almost all of it one cold storage write, while the root and the document location cost
    ///      about 150,000 gas for the whole batch however many scans it holds. At the gas price
    ///      observed on Robinhood Chain mainnet on 2026-09-08, indexing every scan on a chain
    ///      producing tens of thousands of launches a day would cost thousands of dollars a month,
    ///      and indexing the ones anybody has actually bought costs tens.
    ///
    ///      Nothing is lost by that. A scan left out of `summaries` is still in the tree, still
    ///      provable against the root with `verifyScan`, and still published in the batch document.
    ///      What it does not get is the one-call `latestScan` read, which exists so a badge or a
    ///      token page can ask about a token without fetching a document. Which scans deserve that
    ///      is an operational judgement — graduations and elevated risk, in practice — and it is
    ///      recorded in `docs/WATCHDOG.md` rather than fixed in the contract.
    ///
    ///      The contract does not verify that the summaries are the batch's leaves, and cannot:
    ///      checking would mean rebuilding the tree on-chain, which costs more than the record is
    ///      worth and would defeat the point of batching. What it does is publish both the root
    ///      and the summaries, so a disagreement between them is permanently visible to anyone who
    ///      fetches the document. A scanner that publishes summaries its own root does not support
    ///      is caught by the first person to check, and the record of it stays on-chain.
    /// @param root The Merkle root over the batch's leaves.
    /// @param count How many scans the batch holds. Never fewer than the summaries supplied.
    /// @param engineVersion The engine that produced the scans.
    /// @param uri Where the batch document lives, content-addressed.
    /// @param summaries The headline numbers for the scans that are also indexed on-chain.
    /// @return batchId The index of the new batch.
    function commitScanBatch(
        bytes32 root,
        uint32 count,
        uint32 engineVersion,
        string calldata uri,
        ScanSummary[] calldata summaries
    ) external returns (uint256 batchId) {
        if (!isScanner[msg.sender] && !auditors.isAuditor(msg.sender)) {
            revert NotAScanner(msg.sender);
        }

        uint256 indexed_ = summaries.length;
        if (count == 0) revert EmptyBatch();
        if (indexed_ > MAX_BATCH) revert BatchTooLarge(indexed_, MAX_BATCH);
        // A batch cannot index more scans than it contains. The count itself is not verifiable
        // on-chain — the document is what proves it — but a batch claiming to hold fewer scans
        // than it indexes is self-contradictory on its face and is refused here.
        if (indexed_ > count) revert CountTooSmall(count, indexed_);
        if (bytes(uri).length == 0) revert MissingUri();

        batchId = _batches.length;
        _batches.push(
            ScanBatch({
                root: root,
                count: count,
                engineVersion: engineVersion,
                committedAt: uint64(block.timestamp),
                committedBlock: uint64(block.number),
                scanner: msg.sender,
                uri: uri
            })
        );

        emit ScanBatchCommitted(batchId, root, count, engineVersion, uri, msg.sender);

        for (uint256 i = 0; i < indexed_; ++i) {
            ScanSummary calldata summary = summaries[i];
            bytes32 key = assetKey(summary.chainKey, summary.assetId);
            _latest[key] = LatestScan({batchIdPlusOne: uint248(batchId + 1), overallTrust: summary.overallTrust});
            emit AssetScanned(
                summary.chainKey,
                summary.assetId,
                batchId,
                summary.overallTrust,
                summary.confidence,
                summary.flags,
                summary.scannedAtBlock
            );
        }
    }

    /// @notice Checks a scan against a committed batch.
    /// @dev This is the function a third party calls to satisfy itself that a scan it was shown
    ///      really is in the record, without trusting kay9.io or any index.
    /// @param batchId The batch the scan is claimed to be in.
    /// @param leaf The scan's leaf, from `scanLeaf`.
    /// @param proof The Merkle proof, from the leaf upwards.
    /// @return True when the proof reconstructs the batch's root.
    function verifyScan(uint256 batchId, bytes32 leaf, bytes32[] calldata proof) external view returns (bool) {
        if (batchId >= _batches.length) revert UnknownBatch(batchId);
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            // Sorted pairs, so a proof carries no left-or-right flags and cannot be replayed
            // against a differently shaped tree.
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        return computed == _batches[batchId].root;
    }

    /// @notice The number of batches ever committed.
    /// @return The batch count.
    function batchCount() external view returns (uint256) {
        return _batches.length;
    }

    /// @notice A single batch.
    /// @param batchId The batch index.
    /// @return The batch.
    function getBatch(uint256 batchId) external view returns (ScanBatch memory) {
        if (batchId >= _batches.length) revert UnknownBatch(batchId);
        return _batches[batchId];
    }

    /// @notice The most recent basic scan of an asset.
    /// @dev The read a token page and a badge make. It answers with the batch so a caller can go
    ///      and verify, and with `scanned` so an unscanned asset is distinguishable from one that
    ///      scored zero, which is the worst possible trust score and would otherwise be
    ///      indistinguishable from no data at all.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @return scanned Whether the asset has ever been scanned.
    /// @return batchId The batch carrying the most recent scan.
    /// @return overallTrust The most recent headline score.
    function latestScan(bytes32 chainKey, bytes32 assetId)
        external
        view
        returns (bool scanned, uint256 batchId, uint8 overallTrust)
    {
        LatestScan memory stored = _latest[assetKey(chainKey, assetId)];
        if (stored.batchIdPlusOne == 0) return (false, 0, 0);
        return (true, uint256(stored.batchIdPlusOne) - 1, stored.overallTrust);
    }

    /// @notice Authorises or removes a scanner.
    /// @dev A scanner can only ever add to the record. It cannot alter or remove a committed batch,
    ///      and nothing it commits is treated as a consensus claim, so this is a much smaller
    ///      power than adding an auditor.
    /// @param scanner The address.
    /// @param allowed Whether it may commit batches.
    function setScanner(address scanner, bool allowed) external onlyOwner {
        if (scanner == address(0)) revert ZeroAddress();
        isScanner[scanner] = allowed;
        emit ScannerUpdated(scanner, allowed);
    }
}
