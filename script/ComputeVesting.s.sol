// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CalendarMonths} from "../src/libraries/CalendarMonths.sol";

/// @title ComputeVesting
/// @notice Turns a token generation event timestamp into the two calendar unlock timestamps the
///         team vesting contract is deployed with, and prints them as UTC dates so the deployment
///         report can quote exact days rather than "180 days".
/// @dev The unlocks keep the day of month and the time of day. When the target month is too short,
///      for example a 31 August start looking for 31 February, the date clamps to the last day of
///      that month.
contract ComputeVesting is Script {
    /// @notice Computes and prints the schedule.
    /// @return tge The token generation event timestamp.
    /// @return unlock6m The six-month unlock timestamp.
    /// @return unlock12m The twelve-month unlock timestamp.
    function run() external view returns (uint64 tge, uint64 unlock6m, uint64 unlock12m) {
        uint256 tgeInput = vm.envUint("TGE_TIMESTAMP");
        (tge, unlock6m, unlock12m) = compute(tgeInput);

        console2.log("=== KAY9 team vesting schedule ===");
        _printDate("TGE            ", tge, 10_000_000e18);
        _printDate("TGE + 6 months ", unlock6m, 40_000_000e18);
        _printDate("TGE + 12 months", unlock12m, 40_000_000e18);
        console2.log("TGE_TIMESTAMP        =", tge);
        console2.log("UNLOCK_6M_TIMESTAMP  =", unlock6m);
        console2.log("UNLOCK_12M_TIMESTAMP =", unlock12m);
    }

    /// @notice Computes the schedule from a token generation event timestamp.
    /// @param tgeTimestamp The token generation event timestamp.
    /// @return tge The token generation event timestamp, unchanged.
    /// @return unlock6m The six-month unlock timestamp.
    /// @return unlock12m The twelve-month unlock timestamp.
    function compute(uint256 tgeTimestamp) public pure returns (uint64 tge, uint64 unlock6m, uint64 unlock12m) {
        tge = uint64(tgeTimestamp);
        unlock6m = uint64(CalendarMonths.addMonths(tgeTimestamp, 6));
        unlock12m = uint64(CalendarMonths.addMonths(tgeTimestamp, 12));
    }

    /// @notice Prints one tranche as a UTC date.
    /// @param label The tranche label.
    /// @param timestamp The unlock timestamp.
    /// @param amount The tranche amount in wei.
    function _printDate(string memory label, uint64 timestamp, uint256 amount) internal pure {
        (uint256 year, uint256 month, uint256 day) = CalendarMonths.toCivil(uint256(timestamp) / 86_400);
        uint256 secondsOfDay = uint256(timestamp) % 86_400;
        console2.log(
            string.concat(
                label,
                "  ",
                vm.toString(year),
                "-",
                _pad(month),
                "-",
                _pad(day),
                " ",
                _pad(secondsOfDay / 3600),
                ":",
                _pad((secondsOfDay % 3600) / 60),
                ":",
                _pad(secondsOfDay % 60),
                " UTC  unix ",
                vm.toString(uint256(timestamp)),
                "  amount ",
                vm.toString(amount / 1e18)
            )
        );
    }

    /// @notice Renders a number with a leading zero when it is a single digit.
    /// @param value The value.
    /// @return The padded string.
    function _pad(uint256 value) internal pure returns (string memory) {
        return value < 10 ? string.concat("0", vm.toString(value)) : vm.toString(value);
    }
}
