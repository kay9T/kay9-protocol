// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title CalendarMonths
/// @notice Adds whole calendar months to a UTC timestamp, keeping the day of month and the time of
///         day. When the target month is too short for the source day, the result clamps to the
///         last day of that month, which is the convention used for the KAY9 team vesting dates.
/// @dev The civil-date conversions are the standard days-from-civil algorithms, which are exact for
///      the whole proleptic Gregorian calendar and involve no loops.
library CalendarMonths {
    /// @notice Thrown when a timestamp predates the Unix epoch or overflows the supported range.
    error OutOfRange();

    /// @notice Adds whole calendar months to a timestamp, preserving the time of day in UTC.
    /// @param timestamp The source timestamp, in seconds since the Unix epoch.
    /// @param months The number of months to add.
    /// @return The resulting timestamp.
    function addMonths(uint256 timestamp, uint256 months) internal pure returns (uint256) {
        (uint256 year, uint256 month, uint256 day) = toCivil(timestamp / 86_400);
        uint256 secondsOfDay = timestamp % 86_400;

        uint256 monthIndex = (year * 12 + (month - 1)) + months;
        uint256 targetYear = monthIndex / 12;
        uint256 targetMonth = (monthIndex % 12) + 1;

        uint256 maxDay = daysInMonth(targetYear, targetMonth);
        uint256 targetDay = day > maxDay ? maxDay : day;

        return fromCivil(targetYear, targetMonth, targetDay) * 86_400 + secondsOfDay;
    }

    /// @notice The number of days in a month.
    /// @param year The Gregorian year.
    /// @param month The month, from 1 to 12.
    /// @return The day count.
    function daysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 2) return isLeapYear(year) ? 29 : 28;
        if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
        return 31;
    }

    /// @notice Whether a Gregorian year is a leap year.
    /// @param year The year.
    /// @return True for leap years.
    function isLeapYear(uint256 year) internal pure returns (bool) {
        return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    }

    /// @notice Converts days since the Unix epoch into a civil date.
    /// @param daysSinceEpoch The day count.
    /// @return year The Gregorian year.
    /// @return month The month, from 1 to 12.
    /// @return day The day of month, from 1 to 31.
    function toCivil(uint256 daysSinceEpoch) internal pure returns (uint256 year, uint256 month, uint256 day) {
        uint256 z = daysSinceEpoch + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        day = doy - (153 * mp + 2) / 5 + 1;
        month = mp < 10 ? mp + 3 : mp - 9;
        year = month <= 2 ? y + 1 : y;
    }

    /// @notice Converts a civil date into days since the Unix epoch.
    /// @param year The Gregorian year.
    /// @param month The month, from 1 to 12.
    /// @param day The day of month.
    /// @return The day count.
    function fromCivil(uint256 year, uint256 month, uint256 day) internal pure returns (uint256) {
        if (year < 1970 || year > 400_000) revert OutOfRange();
        uint256 y = month <= 2 ? year - 1 : year;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = month > 2 ? month - 3 : month + 9;
        uint256 doy = (153 * mp + 2) / 5 + day - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }
}
