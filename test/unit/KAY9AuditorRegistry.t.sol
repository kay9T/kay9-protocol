// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AuditorRegistry} from "../../src/KAY9AuditorRegistry.sol";

/// @title KAY9AuditorRegistryTest
/// @notice The auditor set's own invariant: the threshold is always a quorum the set can actually
///         meet, and the one state where it cannot — no auditors at all — is announced rather than
///         reached silently.
/// @dev The registry had no test file of its own. Its behaviour was exercised only incidentally,
///      through the hub's rotation tests, which is why `removeAuditor` writing a threshold that
///      `setThreshold` itself forbids went unnoticed.
contract KAY9AuditorRegistryTest is Kay9TestBase {
    /// @notice A removal that leaves fewer auditors than the threshold halts; it never lowers it.
    /// @dev An earlier version lowered the threshold to the number left, so removing two of three
    ///      auditors at threshold two left one key able to publish alone. The quorum only ever
    ///      shrinks by an explicit `setThreshold` now.
    function test_aRemovalBelowTheThresholdHaltsInsteadOfLoweringIt() public {
        address[] memory sorted = _sortedAuditors();
        assertEq(auditorRegistry.auditorCount(), 3);
        assertEq(auditorRegistry.threshold(), 2);

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (sorted[0])));
        assertEq(auditorRegistry.auditorCount(), 2, "two left");
        assertEq(auditorRegistry.threshold(), 2, "a two-of-two quorum is still satisfiable");

        vm.expectEmit(false, false, false, false, address(auditorRegistry));
        emit KAY9AuditorRegistry.QuorumHalted();
        vm.prank(address(timelock));
        auditorRegistry.removeAuditor(sorted[1]);
        assertEq(auditorRegistry.auditorCount(), 1, "one left");
        assertEq(auditorRegistry.threshold(), 0, "halted, not lowered to one");
        assertTrue(auditorRegistry.isHalted(), "and the registry says so");

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.setThreshold, (1)));
        assertEq(auditorRegistry.threshold(), 1, "a one-key quorum only by explicit choice");
    }

    /// @notice Removing every auditor is still allowed and leaves the registry halted.
    /// @dev Refusing it would force an owner responding to a total key compromise to leave a
    ///      compromised key in place.
    function test_removingEveryAuditorLeavesItHalted() public {
        address[] memory sorted = _sortedAuditors();
        for (uint256 i = 0; i < 3; ++i) {
            _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (sorted[i])));
        }
        assertEq(auditorRegistry.auditorCount(), 0);
        assertEq(auditorRegistry.threshold(), 0, "no quorum can form");
        assertTrue(auditorRegistry.isHalted(), "and the registry says so rather than leaving it to be inferred");
    }

    /// @notice The set is capped, so the hub's uint8 vote counters cannot overflow through growth.
    function test_theSetIsCapped() public {
        uint256 room = auditorRegistry.MAX_AUDITORS() - auditorRegistry.auditorCount();
        for (uint256 i = 0; i < room; ++i) {
            vm.prank(address(timelock));
            auditorRegistry.addAuditor(address(uint160(0xA0000 + i)));
        }
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AuditorRegistry.TooManyAuditors.selector);
        auditorRegistry.addAuditor(address(0xFFFFF));
    }

    /// @notice Ownership cannot be renounced.
    function test_renounceIsDisabled() public {
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AuditorRegistry.RenounceDisabled.selector);
        auditorRegistry.renounceOwnership();
    }

    /// @notice The halted threshold is a value `setThreshold` refuses to be given directly.
    /// @dev The contradiction this file exists for: one path wrote a zero the other forbids.
    ///      Both still hold, and the difference between them is now documented rather than
    ///      accidental — `removeAuditor` may reach zero, nobody may choose it.
    function test_zeroIsReachableByRemovalAndNeverByChoice() public {
        address[] memory sorted = _sortedAuditors();
        for (uint256 i = 0; i < 3; ++i) {
            _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (sorted[i])));
        }
        assertEq(auditorRegistry.threshold(), 0);

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditorRegistry.InvalidThreshold.selector, uint8(0), uint256(0)));
        auditorRegistry.setThreshold(0);
    }

    /// @notice Adding an auditor to a halted registry does not quietly pick a quorum.
    /// @dev The only value it could choose is one, and a single-signature quorum is not a decision
    ///      this contract should make on the owner's behalf. Recovery stays two explicit steps.
    function test_recoveryTakesAnExplicitThreshold() public {
        address[] memory sorted = _sortedAuditors();
        for (uint256 i = 0; i < 3; ++i) {
            _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (sorted[i])));
        }

        address fresh = address(0xA11CE);
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.addAuditor, (fresh)));
        assertEq(auditorRegistry.auditorCount(), 1);
        assertEq(auditorRegistry.threshold(), 0, "adding a key did not decide the quorum");
        // Still halted: a member without a quorum signs nothing. The hub refuses every signature
        // while the threshold is zero, so reporting this half-recovered registry as running would
        // be the same shape of mistake the halt state exists to remove.
        assertTrue(auditorRegistry.isHalted(), "one auditor and no quorum is still a halt");

        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.setThreshold, (1)));
        assertEq(auditorRegistry.threshold(), 1, "the owner chose it");
        assertFalse(auditorRegistry.isHalted(), "recovery ends when a quorum is named, not when a key is added");
    }

    /// @notice A threshold larger than the set is refused, whichever way it is reached.
    function test_thresholdCannotExceedTheSet() public {
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(KAY9AuditorRegistry.InvalidThreshold.selector, uint8(4), uint256(3)));
        auditorRegistry.setThreshold(4);
    }

    /// @notice Removal keeps the remaining membership intact, including after a swap from the end.
    function test_removalPreservesTheRestOfTheSet() public {
        address[] memory sorted = _sortedAuditors();
        _governanceCall(address(auditorRegistry), abi.encodeCall(KAY9AuditorRegistry.removeAuditor, (sorted[0])));

        assertFalse(auditorRegistry.isAuditor(sorted[0]), "the removed one is gone");
        assertTrue(auditorRegistry.isAuditor(sorted[1]), "the others are not");
        assertTrue(auditorRegistry.isAuditor(sorted[2]), "including the one swapped in from the end");

        address[] memory remaining = auditorRegistry.auditors();
        assertEq(remaining.length, 2);
    }
}
