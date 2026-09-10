// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9TeamVesting} from "../../src/KAY9TeamVesting.sol";
import {CalendarMonths} from "../../src/libraries/CalendarMonths.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title KAY9TeamVestingTest
/// @notice Proves the team schedule cannot be accelerated, changed or over-drawn.
contract KAY9TeamVestingTest is Kay9TestBase {
    /// @notice The contract holds exactly the team allocation and nothing else.
    function test_fundedWithExactAllocation() public view {
        assertEq(token.balanceOf(address(vesting)), vesting.TOTAL_ALLOCATION());
        assertEq(vesting.TRANCHE_1() + vesting.TRANCHE_2() + vesting.TRANCHE_3(), vesting.TOTAL_ALLOCATION());
        assertEq(vesting.TOTAL_ALLOCATION(), 90_000_000e18);
        assertEq(vesting.released(), 0);
    }

    /// @notice The published schedule matches the immutables.
    function test_schedule() public view {
        (uint64[3] memory timestamps, uint256[3] memory amounts) = vesting.schedule();
        assertEq(timestamps[0], tge);
        assertEq(timestamps[1], unlock6m);
        assertEq(timestamps[2], unlock12m);
        assertEq(amounts[0], 10_000_000e18);
        assertEq(amounts[1], 40_000_000e18);
        assertEq(amounts[2], 40_000_000e18);
    }

    /// @notice Each tranche unlocks exactly at its timestamp, not one second earlier.
    function test_unlockBoundariesToTheSecond() public {
        vm.warp(tge - 1);
        assertEq(vesting.unlocked(), 0, "one second before the token generation event");
        vm.warp(tge);
        assertEq(vesting.unlocked(), 10_000_000e18, "at the token generation event");

        vm.warp(unlock6m - 1);
        assertEq(vesting.unlocked(), 10_000_000e18, "one second before the six-month unlock");
        vm.warp(unlock6m);
        assertEq(vesting.unlocked(), 50_000_000e18, "at the six-month unlock");

        vm.warp(unlock12m - 1);
        assertEq(vesting.unlocked(), 50_000_000e18, "one second before the twelve-month unlock");
        vm.warp(unlock12m);
        assertEq(vesting.unlocked(), 90_000_000e18, "at the twelve-month unlock");

        vm.warp(unlock12m + 3650 days);
        assertEq(vesting.unlocked(), 90_000_000e18, "the schedule never exceeds the allocation");
    }

    /// @notice release is permissionless and always pays the beneficiary.
    function test_releaseIsPermissionlessAndPaysBeneficiary() public {
        vm.warp(tge);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vesting.release();
        assertEq(token.balanceOf(teamBeneficiary), 10_000_000e18);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(vesting.released(), 10_000_000e18);
    }

    /// @notice A second release in the same window pays nothing.
    function test_noDoubleRelease() public {
        vm.warp(tge);
        vesting.release();
        vm.expectRevert(KAY9TeamVesting.NothingToRelease.selector);
        vesting.release();
        assertEq(token.balanceOf(teamBeneficiary), 10_000_000e18);
    }

    /// @notice Nothing is releasable before the token generation event.
    function test_noEarlyUnlock() public {
        vm.warp(tge - 1);
        vm.expectRevert(KAY9TeamVesting.NothingToRelease.selector);
        vesting.release();
    }

    /// @notice There is no owner and no override that could move the tokens early.
    function test_noOwnerOverride() public {
        string[6] memory signatures = [
            "owner()",
            "withdraw(uint256)",
            "emergencyWithdraw()",
            "setSchedule(uint64,uint64,uint64)",
            "accelerate()",
            "sweep(address)"
        ];
        for (uint256 i = 0; i < signatures.length; ++i) {
            (bool ok,) = address(vesting).call(abi.encodeWithSelector(bytes4(keccak256(bytes(signatures[i])))));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(address(vesting)), 90_000_000e18);
    }

    /// @notice Only the beneficiary can hand the role on, and the new one receives future releases.
    function test_transferBeneficiary() public {
        address next = makeAddr("nextBeneficiary");

        vm.expectRevert(KAY9TeamVesting.NotBeneficiary.selector);
        vesting.transferBeneficiary(next);

        vm.prank(teamBeneficiary);
        vm.expectRevert(KAY9TeamVesting.ZeroAddress.selector);
        vesting.transferBeneficiary(address(0));

        vm.prank(teamBeneficiary);
        vesting.transferBeneficiary(next);
        assertEq(vesting.beneficiary(), next);

        vm.warp(unlock6m);
        vesting.release();
        assertEq(token.balanceOf(next), 50_000_000e18);
        assertEq(token.balanceOf(teamBeneficiary), 0);
    }

    /// @notice The constructor rejects an out-of-order schedule.
    function test_rejectsBadSchedule() public {
        vm.expectRevert(KAY9TeamVesting.UnlockOrder.selector);
        new KAY9TeamVesting(IERC20(address(token)), teamBeneficiary, 200, 100, 300);

        vm.expectRevert(KAY9TeamVesting.ZeroAddress.selector);
        new KAY9TeamVesting(IERC20(address(token)), address(0), 100, 200, 300);
    }

    /// @notice The cumulative unlock is monotonic and never exceeds the allocation.
    /// @param timeOffset A time offset from the token generation event.
    function testFuzz_unlockedIsMonotonic(uint64 timeOffset) public {
        timeOffset = uint64(bound(timeOffset, 0, 4000 days));
        vm.warp(uint256(tge) + timeOffset);
        uint256 first = vesting.unlocked();
        assertLe(first, vesting.TOTAL_ALLOCATION());

        vm.warp(uint256(tge) + timeOffset + 1);
        assertGe(vesting.unlocked(), first);
    }

    /// @notice Releasing at any point never exceeds what is unlocked at that point.
    /// @param timeOffset A time offset from the token generation event.
    function testFuzz_releaseNeverExceedsUnlocked(uint64 timeOffset) public {
        timeOffset = uint64(bound(timeOffset, 0, 4000 days));
        vm.warp(uint256(tge) + timeOffset);
        uint256 unlockedNow = vesting.unlocked();
        if (unlockedNow == 0) {
            vm.expectRevert(KAY9TeamVesting.NothingToRelease.selector);
            vesting.release();
            return;
        }
        vesting.release();
        assertEq(vesting.released(), unlockedNow);
        assertEq(token.balanceOf(teamBeneficiary), unlockedNow);
        assertEq(token.balanceOf(address(vesting)), 90_000_000e18 - unlockedNow);
    }

    // -------------------------------------------------------------------------------------------
    // Calendar arithmetic
    // -------------------------------------------------------------------------------------------

    /// @notice Adding six and twelve calendar months keeps the day and the time of day.
    function test_calendarMonthsKeepDayAndTime() public pure {
        // 2026-03-15 13:45:07 UTC
        uint256 start = CalendarMonths.fromCivil(2026, 3, 15) * 86_400 + 13 * 3600 + 45 * 60 + 7;
        uint256 six = CalendarMonths.addMonths(start, 6);
        uint256 twelve = CalendarMonths.addMonths(start, 12);

        (uint256 y, uint256 m, uint256 d) = CalendarMonths.toCivil(six / 86_400);
        assertEq(y, 2026);
        assertEq(m, 9);
        assertEq(d, 15);
        assertEq(six % 86_400, start % 86_400);

        (y, m, d) = CalendarMonths.toCivil(twelve / 86_400);
        assertEq(y, 2027);
        assertEq(m, 3);
        assertEq(d, 15);
        assertEq(twelve % 86_400, start % 86_400);
    }

    /// @notice A day that does not exist in the target month clamps to the last day.
    function test_calendarMonthsClampShortMonths() public pure {
        // 2026-08-31 -> 2027-02-28 (2027 is not a leap year)
        uint256 start = CalendarMonths.fromCivil(2026, 8, 31) * 86_400;
        uint256 six = CalendarMonths.addMonths(start, 6);
        (uint256 y, uint256 m, uint256 d) = CalendarMonths.toCivil(six / 86_400);
        assertEq(y, 2027);
        assertEq(m, 2);
        assertEq(d, 28);

        // 2023-08-31 -> 2024-02-29 (2024 is a leap year)
        start = CalendarMonths.fromCivil(2023, 8, 31) * 86_400;
        six = CalendarMonths.addMonths(start, 6);
        (y, m, d) = CalendarMonths.toCivil(six / 86_400);
        assertEq(y, 2024);
        assertEq(m, 2);
        assertEq(d, 29);

        // 2026-01-31 -> 2026-07-31, which does exist
        start = CalendarMonths.fromCivil(2026, 1, 31) * 86_400;
        six = CalendarMonths.addMonths(start, 6);
        (y, m, d) = CalendarMonths.toCivil(six / 86_400);
        assertEq(y, 2026);
        assertEq(m, 7);
        assertEq(d, 31);
    }

    /// @notice Civil-date conversion round-trips for every day in a wide range.
    /// @param dayCount A day index since the Unix epoch.
    function testFuzz_civilRoundTrip(uint32 dayCount) public pure {
        uint256 day = bound(dayCount, 0, 60_000);
        (uint256 y, uint256 m, uint256 d) = CalendarMonths.toCivil(day);
        assertEq(CalendarMonths.fromCivil(y, m, d), day);
    }

    /// @notice Adding months always lands in the arithmetically correct month.
    /// @param dayCount A day index since the Unix epoch.
    /// @param months The number of months to add.
    function testFuzz_addMonthsLandsInTheRightMonth(uint32 dayCount, uint8 months) public pure {
        uint256 day = bound(dayCount, 0, 60_000);
        uint256 monthsToAdd = bound(months, 0, 120);
        uint256 start = day * 86_400 + 3661;
        (uint256 y0, uint256 m0,) = CalendarMonths.toCivil(day);
        uint256 result = CalendarMonths.addMonths(start, monthsToAdd);
        (uint256 y1, uint256 m1, uint256 d1) = CalendarMonths.toCivil(result / 86_400);

        uint256 expectedIndex = y0 * 12 + (m0 - 1) + monthsToAdd;
        assertEq(y1 * 12 + (m1 - 1), expectedIndex);
        assertLe(d1, CalendarMonths.daysInMonth(y1, m1));
        assertEq(result % 86_400, 3661);
    }
}
