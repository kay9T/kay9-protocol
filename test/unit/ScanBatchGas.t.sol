// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {KAY9AuditorRegistry} from "../../src/KAY9AuditorRegistry.sol";
import {KAY9ScanRegistry} from "../../src/KAY9ScanRegistry.sol";

/// @notice Measures what committing a batch actually costs, because the batch size is a cost
///         decision and picking it without measuring would be guessing.
contract ScanBatchGasTest is Test {
    KAY9ScanRegistry internal scans;
    address internal scanner = address(0x5CA1);
    bytes32 internal constant CHAIN = keccak256("eip155:4663");

    function setUp() public {
        address[] memory set = new address[](1);
        set[0] = address(0xA1);
        KAY9AuditorRegistry auditors = new KAY9AuditorRegistry(address(this), set, 1);
        scans = new KAY9ScanRegistry(address(this), auditors);
        scans.setScanner(scanner, true);
    }

    function _batch(uint256 n) internal pure returns (KAY9ScanRegistry.ScanSummary[] memory out) {
        out = new KAY9ScanRegistry.ScanSummary[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = KAY9ScanRegistry.ScanSummary({
                chainKey: CHAIN,
                assetId: bytes32(uint256(i + 1)),
                overallTrust: uint8(i % 100),
                confidence: 80,
                flags: 8,
                scannedAtBlock: 1000
            });
        }
    }

    /// @notice What a batch costs when it indexes nothing: the fixed part of every commit.
    function test_gasForRootOnlyBatch() public {
        KAY9ScanRegistry.ScanSummary[] memory none = new KAY9ScanRegistry.ScanSummary[](0);
        vm.prank(scanner);
        uint256 before = gasleft();
        scans.commitScanBatch(bytes32(uint256(99)), 10_000, 3, "ipfs://root-only", none);
        console2.log("root-only batch gas", before - gasleft());
    }

    function test_gasPerBatchSize() public {
        uint256[5] memory sizes = [uint256(1), 10, 50, 100, 500];
        for (uint256 i = 0; i < sizes.length; ++i) {
            KAY9ScanRegistry.ScanSummary[] memory summaries = _batch(sizes[i]);
            vm.prank(scanner);
            uint256 before = gasleft();
            scans.commitScanBatch(bytes32(uint256(i + 1)), uint32(summaries.length), 3, "ipfs://batch", summaries);
            uint256 used = before - gasleft();
            console2.log("size", sizes[i]);
            console2.log("  gas total   ", used);
            console2.log("  gas per scan", used / sizes[i]);
        }
    }
}
