// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AccessVault} from "../../src/KAY9AccessVault.sol";
import {KAY9AuditHub} from "../../src/KAY9AuditHub.sol";
import {KAY9Registry} from "../../src/KAY9Registry.sol";
import {AuditResult} from "../../src/KAY9Registry.sol";

/// @title KAY9HubBeforeTokenTest
/// @notice The hub in the state it spends its first months in: deployed, governing a registry, and
///         with no access vault because $KAY9 does not exist yet.
///
/// @dev This state exists because of an ordering constraint that cannot be worked around. The
///      watchdog goes live before the token; `KAY9Registry` binds to its hub **immutably**, so the
///      hub must be the final one from the first deployment; and the vault holds KAY9, so it cannot
///      be deployed until the token is. Something has to give, and what gives is that the vault
///      arrives later than the hub.
///
///      Two things must hold for that to be safe. Unsolicited quorum-signed reports have to work
///      from day one, or deep and forensic analysis cannot be shown to anybody before launch. And
///      the vault binding must be settable exactly once, or governance could later point the hub at
///      a vault that hands out quota nobody locked for.
contract KAY9HubBeforeTokenTest is Kay9TestBase {
    KAY9Registry internal earlyRegistry;
    KAY9AuditHub internal earlyHub;

    function setUp() public override {
        super.setUp();

        // The watchdog-phase deployment: a registry and a hub, and no vault anywhere.
        address predictedHub = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        earlyRegistry = new KAY9Registry(predictedHub);
        earlyHub =
            new KAY9AuditHub(address(timelock), address(earlyRegistry), auditorRegistry, KAY9AccessVault(address(0)));
        require(address(earlyHub) == predictedHub, "hub address prediction failed");
    }

    /// @notice A hub with no vault deploys, and says so.
    function test_deploysWithNoVault() public view {
        assertEq(address(earlyHub.accessVault()), address(0), "no vault before the token");
        assertEq(address(earlyHub.registry()), address(earlyRegistry));
        assertEq(earlyRegistry.auditHub(), address(earlyHub), "the registry is bound to it for good");
    }

    /// @notice An audit cannot be requested, because there is nothing to spend.
    function test_requestIsRefusedUntilAVaultIsSet() public {
        // The chain key is read first, deliberately. `vm.expectRevert` applies to the next call,
        // and an external read in the argument list is a call: leaving it inline would spend the
        // expectation on `CHAIN_ROBINHOOD()` and the test would fail for the wrong reason.
        bytes32 chainKey = earlyRegistry.CHAIN_ROBINHOOD();
        address caller = requesterAddress();
        vm.prank(caller);
        vm.expectRevert(KAY9AuditHub.AccessVaultNotSet.selector);
        earlyHub.requestAudit(chainKey, assetId(), 1, 1);
    }

    /// @notice A quorum can publish an unsolicited report from day one.
    /// @dev The whole point of the arrangement. Deep and forensic analysis has to be demonstrable
    ///      before anybody is asked to lock KAY9 for it, and this is the path that allows it: no
    ///      requester, no quota, no vault, two of three signatures checked against the auditor
    ///      registry that is already on chain.
    function test_aQuorumCanPublishBeforeThereIsAToken() public {
        AuditResult memory result = sampleResult();
        bytes[] memory signatures = signResult(earlyHub, 0, result);

        uint256 reportId = earlyHub.publishWatchdogReport(result, signatures);

        assertEq(earlyRegistry.reportCount(), 1, "the report is in the permanent record");
        (bool exists,) = earlyRegistry.latest(result.chainKey, result.assetId);
        assertTrue(exists);

        // A beta report is distinguishable from a requested one on chain, without asking anybody:
        // no job, no requester, no tier.
        assertEq(earlyRegistry.getReport(reportId).jobId, 0);
        assertEq(earlyRegistry.getReport(reportId).requester, address(0));
        assertEq(earlyRegistry.getReport(reportId).tier, 0);
    }

    /// @notice Governance binds the vault once, and requests open.
    function test_settingTheVaultOpensRequests() public {
        vm.prank(address(timelock));
        earlyHub.setAccessVault(accessVault);
        assertEq(address(earlyHub.accessVault()), address(accessVault));

        // The request now reaches the vault rather than being stopped at the hub, which is the
        // state change being asserted. The vault refuses it for its own reason: this vault was
        // built for a different hub and will not take instructions from any other.
        //
        // That refusal is worth stating as a production constraint. `KAY9AccessVault.consume` is
        // callable only by the one hub it was configured with, so at the token launch the vault
        // must be pointed at the hub that has been live all along. Deploying a fresh hub with the
        // vault would leave a registry bound to the old one and every report in it stranded.
        bytes32 chainKey = earlyRegistry.CHAIN_ROBINHOOD();
        address caller = requesterAddress();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, address(earlyHub)));
        earlyHub.requestAudit(chainKey, assetId(), 1, 1);
    }

    /// @notice The vault can be bound once and never again.
    function test_theVaultCannotBeRepointed() public {
        vm.prank(address(timelock));
        earlyHub.setAccessVault(accessVault);

        vm.prank(address(timelock));
        vm.expectRevert(KAY9AuditHub.AccessVaultAlreadySet.selector);
        earlyHub.setAccessVault(accessVault);
    }

    /// @notice Only governance may bind it.
    function test_onlyTheOwnerMayBindTheVault() public {
        vm.prank(requesterAddress());
        vm.expectRevert();
        earlyHub.setAccessVault(accessVault);
    }

    /// @notice The zero address is not a vault.
    function test_theVaultCannotBeBoundToZero() public {
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AuditHub.ZeroAddress.selector);
        earlyHub.setAccessVault(KAY9AccessVault(address(0)));
    }

    // ---------------------------------------------------------------------------------------
    // Helpers, kept thin so the assertions above read as the story they are.
    // ---------------------------------------------------------------------------------------

    /// @notice A result with the shape the registry expects; the numbers do not matter here.
    function sampleResult() internal view returns (AuditResult memory result) {
        result.chainKey = earlyRegistry.CHAIN_ROBINHOOD();
        result.assetId = assetId();
        result.overallTrust = 42;
        result.contractTrust = 10;
        result.liquidityTrust = 10;
        result.holderTrust = 10;
        result.insiderTrust = 10;
        result.creatorTrust = 10;
        result.tradingTrust = 10;
        result.botTrust = 10;
        result.flags = 0;
        result.engineVersion = 1;
        result.analyzedAt = uint64(block.timestamp);
        result.reportHash = keccak256("beta report");
        result.reportURI = "ipfs://beta";
    }

    /// @notice Two auditor signatures over a watchdog digest, in ascending signer order.
    function signResult(KAY9AuditHub target, uint256 jobId, AuditResult memory result)
        internal
        view
        returns (bytes[] memory signatures)
    {
        bytes32 digest = target.hashResult(jobId, result);
        address[] memory sorted = _sortedAuditors();
        signatures = new bytes[](2);
        for (uint256 i = 0; i < 2; ++i) {
            (uint8 v, bytes32 r, bytes32 sig) = vm.sign(_keyOf(sorted[i]), digest);
            signatures[i] = abi.encodePacked(r, sig, v);
        }
    }

    function requesterAddress() internal returns (address) {
        return makeAddr("someone");
    }

    function assetId() internal pure returns (bytes32) {
        return bytes32(uint256(uint160(0x1111111111111111111111111111111111111111)));
    }
}
