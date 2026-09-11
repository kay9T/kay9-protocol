// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";

/// @notice The fixed-size, on-chain part of an audit. The report body itself lives off-chain and is
///         pinned by reportURI; reportHash binds that document to this record.
/// @dev Trust scores run from 0 (worst observed) to 100 (nothing risky found). Higher is always
///      more trustworthy. The flag bitmask is documented in docs/CONTRACT_INTERFACES.md.
struct AuditResult {
    bytes32 chainKey;
    bytes32 assetId;
    uint8 overallTrust;
    uint8 contractTrust;
    uint8 liquidityTrust;
    uint8 holderTrust;
    uint8 insiderTrust;
    uint8 creatorTrust;
    uint8 tradingTrust;
    uint8 botTrust;
    uint64 flags;
    uint32 engineVersion;
    uint64 analyzedAt;
    bytes32 reportHash;
    string reportURI;
}

/// @notice Who asked for a report and under what access, recorded alongside it.
/// @dev None of this reaches the auditors. It is written by the hub so that a reader can see the
///      provenance of a record, which matters most when a token's own creator requested it.
struct ReportMeta {
    uint256 jobId;
    address requester;
    uint8 declaredRequesterKind;
    uint8 tier;
}

/// @notice One immutable entry of the report log.
struct ReportRecord {
    uint256 jobId;
    address requester;
    uint8 declaredRequesterKind;
    uint8 tier;
    AuditResult result;
    address[] signers;
    uint64 committedAt;
    uint64 committedBlock;
}

/// @title KAY9Registry
/// @notice The append-only log of committed audit results. Entries are written only by the audit
///         hub and are never modified or deleted afterwards, so the history of an asset is a
///         permanent record that survives the website.
/// @dev Assets are identified across chains by a CAIP-2 chain key hash plus a 32-byte asset id, so
///      the same structure holds EVM contracts and Solana mints. A re-audit of an asset appends;
///      it never replaces. `latest` therefore means "most recent snapshot", and every reader is
///      expected to render `committedAt` next to it.
/// @custom:security-contact security@kay9.io
contract KAY9Registry is BlockNumberish {
    /// @notice Emitted for every appended report.
    /// @param reportId The index of the new record.
    /// @param chainKey The CAIP-2 chain key hash of the audited asset.
    /// @param assetId The asset identifier within that chain.
    /// @param jobId The job this result settles, or 0 for an unsolicited watchdog report.
    /// @param overallTrust The headline trust score.
    /// @param reportHash The keccak256 of the canonical off-chain report.
    event ReportRecorded(
        uint256 indexed reportId,
        bytes32 indexed chainKey,
        bytes32 indexed assetId,
        uint256 jobId,
        uint8 overallTrust,
        bytes32 reportHash
    );

    /// @notice Thrown when the audit hub address is the zero address.
    error ZeroAuditHub();

    /// @notice Thrown when a caller other than the audit hub tries to append a report.
    /// @param caller The rejected caller.
    error NotAuditHub(address caller);

    /// @notice Thrown when a report is submitted with no signers.
    error NoSigners();

    /// @notice The only address allowed to append reports.
    address public immutable auditHub;

    /// @notice CAIP-2 chain key for Robinhood Chain mainnet.
    bytes32 public constant CHAIN_ROBINHOOD = keccak256("eip155:4663");

    /// @notice CAIP-2 chain key for Robinhood Chain testnet.
    bytes32 public constant CHAIN_ROBINHOOD_TESTNET = keccak256("eip155:46630");

    /// @notice CAIP-2 chain key for BNB Smart Chain.
    bytes32 public constant CHAIN_BNB = keccak256("eip155:56");

    /// @notice CAIP-2 chain key for Solana mainnet.
    bytes32 public constant CHAIN_SOLANA = keccak256("solana:mainnet");

    /// @notice Every report ever recorded, in commitment order.
    ReportRecord[] private _reports;

    /// @notice Report ids per asset, in commitment order.
    mapping(bytes32 assetKeyHash => uint256[] reportIds) private _history;

    /// @notice Binds the registry to its audit hub.
    /// @param auditHub_ The hub allowed to append reports.
    constructor(address auditHub_) {
        if (auditHub_ == address(0)) revert ZeroAuditHub();
        auditHub = auditHub_;
    }

    /// @notice The composite key that groups reports about the same asset.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier within that chain.
    /// @return The asset key.
    function assetKey(bytes32 chainKey, bytes32 assetId) public pure returns (bytes32) {
        return keccak256(abi.encode(chainKey, assetId));
    }

    /// @notice The 32-byte asset id of an EVM contract address.
    /// @param token The contract address.
    /// @return The asset id.
    function evmAssetId(address token) public pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    /// @notice Appends a report. Callable only by the audit hub.
    /// @param meta The provenance of the record: job, requester, declared kind and access tier.
    /// @param result The committed result.
    /// @param signers The quorum that signed it, in ascending address order.
    /// @return reportId The index of the new record.
    function recordReport(ReportMeta calldata meta, AuditResult calldata result, address[] calldata signers)
        external
        returns (uint256 reportId)
    {
        if (msg.sender != auditHub) revert NotAuditHub(msg.sender);
        if (signers.length == 0) revert NoSigners();

        reportId = _reports.length;
        _reports.push(
            ReportRecord({
                jobId: meta.jobId,
                requester: meta.requester,
                declaredRequesterKind: meta.declaredRequesterKind,
                tier: meta.tier,
                result: result,
                signers: signers,
                committedAt: uint64(block.timestamp),
                committedBlock: uint64(_getBlockNumberish())
            })
        );
        _history[assetKey(result.chainKey, result.assetId)].push(reportId);

        emit ReportRecorded(
            reportId, result.chainKey, result.assetId, meta.jobId, result.overallTrust, result.reportHash
        );
    }

    /// @notice The total number of recorded reports.
    /// @return The report count.
    function reportCount() external view returns (uint256) {
        return _reports.length;
    }

    /// @notice A single report record.
    /// @param reportId The record index.
    /// @return The record.
    function getReport(uint256 reportId) external view returns (ReportRecord memory) {
        return _reports[reportId];
    }

    /// @notice A page of report records, in commitment order.
    /// @dev Returns the window [offset, offset + limit), truncated at the end of the log. Callers
    ///      that want newest-first paging compute the offset themselves from reportCount.
    ///
    ///      `limit` saturates: `type(uint256).max` means "to the end of the log". The addition is
    ///      deliberately unchecked so that a caller passing a maximal limit gets the tail rather
    ///      than an overflow panic, and the `end < offset` test catches the wrap that unchecked
    ///      arithmetic then allows.
    /// @param offset The first index to return.
    /// @param limit The maximum number of records to return.
    /// @return page The records in the requested window.
    function getReports(uint256 offset, uint256 limit) external view returns (ReportRecord[] memory page) {
        uint256 total = _reports.length;
        if (offset >= total) return new ReportRecord[](0);
        uint256 end = _clampEnd(offset, limit, total);
        page = new ReportRecord[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _reports[i];
        }
    }

    /// @notice The number of reports recorded about one asset.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @return The history length.
    function historyCount(bytes32 chainKey, bytes32 assetId) external view returns (uint256) {
        return _history[assetKey(chainKey, assetId)].length;
    }

    /// @notice A page of report ids for one asset, in commitment order.
    /// @dev `limit` saturates exactly as it does in getReports: `type(uint256).max` means "to the
    ///      end of this asset's history" rather than an overflow panic.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @param offset The first index to return.
    /// @param limit The maximum number of ids to return.
    /// @return reportIds The ids in the requested window.
    function history(bytes32 chainKey, bytes32 assetId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory reportIds)
    {
        uint256[] storage ids = _history[assetKey(chainKey, assetId)];
        uint256 total = ids.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = _clampEnd(offset, limit, total);
        reportIds = new uint256[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            reportIds[i - offset] = ids[i];
        }
    }

    /// @notice The most recent report about one asset.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @return exists Whether any report exists for the asset.
    /// @return record The latest record, or a zeroed struct.
    function latest(bytes32 chainKey, bytes32 assetId) external view returns (bool exists, ReportRecord memory record) {
        uint256[] storage ids = _history[assetKey(chainKey, assetId)];
        uint256 total = ids.length;
        if (total == 0) return (false, record);
        return (true, _reports[ids[total - 1]]);
    }

    /// @notice The headline numbers of the most recent report about one asset.
    /// @dev This is the read a wallet, DEX, launchpad or embedded badge makes: one call, no arrays
    ///      of structs, no report body. It exists so that consuming KAY9 risk data never requires
    ///      an off-chain API or a KAY9-operated frontend.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @return exists Whether any report exists.
    /// @return reportId The index of the latest record.
    /// @return overallTrust The headline trust score, 0 worst to 100 most trustworthy.
    /// @return flags The flag bitmask.
    /// @return engineVersion The engine that produced it.
    /// @return committedAt When it was committed. A reader must always show this.
    function latestSummary(bytes32 chainKey, bytes32 assetId)
        public
        view
        returns (
            bool exists,
            uint256 reportId,
            uint8 overallTrust,
            uint64 flags,
            uint32 engineVersion,
            uint64 committedAt
        )
    {
        uint256[] storage ids = _history[assetKey(chainKey, assetId)];
        uint256 total = ids.length;
        if (total == 0) return (false, 0, 0, 0, 0, 0);
        reportId = ids[total - 1];
        ReportRecord storage record = _reports[reportId];
        return (
            true,
            reportId,
            record.result.overallTrust,
            record.result.flags,
            record.result.engineVersion,
            record.committedAt
        );
    }

    /// @notice latestSummary for an EVM token address, saving the caller the assetId conversion.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param token The token contract address.
    /// @return exists Whether any report exists.
    /// @return reportId The index of the latest record.
    /// @return overallTrust The headline trust score.
    /// @return flags The flag bitmask.
    /// @return engineVersion The engine that produced it.
    /// @return committedAt When it was committed.
    function latestSummaryForToken(bytes32 chainKey, address token)
        external
        view
        returns (
            bool exists,
            uint256 reportId,
            uint8 overallTrust,
            uint64 flags,
            uint32 engineVersion,
            uint64 committedAt
        )
    {
        return latestSummary(chainKey, evmAssetId(token));
    }

    /// @notice The score of every report about one asset, in commitment order.
    /// @dev The read behind a risk-over-time chart. Two parallel arrays rather than a struct array
    ///      so the response stays small enough to fetch a long history in one call.
    /// @param chainKey The CAIP-2 chain key hash.
    /// @param assetId The asset identifier.
    /// @param offset The first index to return.
    /// @param limit The maximum number of points to return; saturating.
    /// @return committedAt The commitment timestamps.
    /// @return overallTrust The trust scores at those timestamps.
    function scoreHistory(bytes32 chainKey, bytes32 assetId, uint256 offset, uint256 limit)
        external
        view
        returns (uint64[] memory committedAt, uint8[] memory overallTrust)
    {
        uint256[] storage ids = _history[assetKey(chainKey, assetId)];
        uint256 total = ids.length;
        if (offset >= total) return (new uint64[](0), new uint8[](0));
        uint256 end = _clampEnd(offset, limit, total);
        uint256 count = end - offset;
        committedAt = new uint64[](count);
        overallTrust = new uint8[](count);
        for (uint256 i = offset; i < end; ++i) {
            ReportRecord storage record = _reports[ids[i]];
            committedAt[i - offset] = record.committedAt;
            overallTrust[i - offset] = record.result.overallTrust;
        }
    }

    /// @notice The saturating end index of a page.
    /// @dev The addition is unchecked so a maximal limit reads as "to the end" rather than
    ///      panicking; the wrap that allows is then caught by the `end < offset` test.
    /// @param offset The first index.
    /// @param limit The requested count.
    /// @param total The length of the collection.
    /// @return end The exclusive end index.
    function _clampEnd(uint256 offset, uint256 limit, uint256 total) private pure returns (uint256 end) {
        unchecked {
            end = offset + limit;
        }
        if (end > total || end < offset) end = total;
    }
}
