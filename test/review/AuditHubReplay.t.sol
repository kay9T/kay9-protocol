// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AuditHub} from "../../src/KAY9AuditHub.sol";
import {AuditResult} from "../../src/KAY9Registry.sol";

/// @title AuditHubReplayTest
/// @notice A watchdog report consumes nothing, so one valid signature set must not be replayable
///         into the permanent report log an unbounded number of times.
contract AuditHubReplayTest is Kay9TestBase {
    bytes32 internal constant CHAIN_KEY = keccak256("eip155:4663");
    bytes32 internal constant ASSET_ID = bytes32(uint256(uint160(0xBEEF)));

    function test_watchdogReportCannotBeReplayed() public {
        AuditResult memory result = _result();
        bytes[] memory signatures = _sign(0, result, 2);

        vm.prank(auditorAddresses[0]);
        hub.publishWatchdogReport(result, signatures);
        assertEq(reportRegistry.reportCount(), 1);

        bytes32 digest = hub.hashResult(0, result);
        assertTrue(hub.watchdogReportCommitted(digest), "digest recorded");

        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.DuplicateWatchdogReport.selector, digest));
        hub.publishWatchdogReport(result, signatures);

        // A different signer subset over the same payload is the same digest, so it is refused too.
        bytes[] memory otherSignatures = new bytes[](3);
        address[] memory sorted = _sortedAuditors();
        for (uint256 i = 0; i < 3; ++i) {
            otherSignatures[i] = _signDigest(_keyOf(sorted[i]), digest);
        }
        vm.prank(auditorAddresses[0]);
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditHub.DuplicateWatchdogReport.selector, digest));
        hub.publishWatchdogReport(result, otherSignatures);

        assertEq(reportRegistry.reportCount(), 1, "log did not grow");

        // A genuinely new report still goes through.
        result.analyzedAt += 1;
        bytes[] memory hoistedSignatures1 = _sign(0, result, 2);
        vm.prank(auditorAddresses[0]);
        hub.publishWatchdogReport(result, hoistedSignatures1);
        assertEq(reportRegistry.reportCount(), 2);
    }

    function _result() internal view returns (AuditResult memory result) {
        result = AuditResult({
            chainKey: CHAIN_KEY,
            assetId: ASSET_ID,
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
            reportURI: "ipfs://bafy"
        });
    }

    function _sign(uint256 jobId, AuditResult memory result, uint256 count)
        internal
        view
        returns (bytes[] memory signatures)
    {
        bytes32 digest = hub.hashResult(jobId, result);
        address[] memory sorted = _sortedAuditors();
        signatures = new bytes[](count);
        for (uint256 i = 0; i < count; ++i) {
            signatures[i] = _signDigest(_keyOf(sorted[i]), digest);
        }
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
