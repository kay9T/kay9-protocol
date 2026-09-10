// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AuctionSteps
/// @notice Builds the packed emission schedule a Continuous Clearing Auction consumes.
/// @dev The auction stores the schedule as a sequence of 8-byte words, each holding a `uint24` of
///      milli-percent per block followed by a `uint40` block delta. The auction constructor
///      enforces two invariants: every block delta is non-zero, the sum of `mps * blockDelta`
///      equals exactly 1e7, and the block deltas add up to `endBlock - startBlock`.
///
///      The shape reproduced here is the Uniswap SDK default: a number of ramp steps that each
///      release the same number of tokens over progressively shorter windows, followed by a single
///      final block that releases the reserved remainder. Concentrating the last slice in one block
///      anchors the clearing price where it is expensive to manipulate.
library AuctionSteps {
    /// @notice The milli-percent denominator. 1e7 is 100 % of the auctioned supply.
    uint256 internal constant MPS_TOTAL = 1e7;

    /// @notice The number of ramp steps the launch configuration uses.
    uint256 internal constant DEFAULT_RAMP_STEPS = 12;

    /// @notice The share of supply released in the final block, in milli-percent.
    uint256 internal constant DEFAULT_FINAL_BLOCK_MPS = 3e6;

    /// @notice Thrown when the requested window cannot hold the requested schedule.
    error WindowTooShort();

    /// @notice Thrown when the caller asks for no ramp steps.
    error NoRampSteps();

    /// @notice Thrown when the reserved final-block share is not a proper fraction of the supply.
    error InvalidFinalShare();

    /// @notice Builds the launch schedule with the default twelve ramp steps and 30 % final block.
    /// @param startBlock The first block of the auction.
    /// @param endBlock The block the auction ends at, exclusive.
    /// @return The packed schedule.
    function convexSchedule(uint64 startBlock, uint64 endBlock) internal pure returns (bytes memory) {
        return convexSchedule(startBlock, endBlock, DEFAULT_RAMP_STEPS, DEFAULT_FINAL_BLOCK_MPS);
    }

    /// @notice Builds a convex schedule.
    /// @dev Ramp boundaries follow the inverse of the normalized supply curve `C(t) = t^1.2`, which
    ///      is evaluated in fixed point as `t^(5/6)` of the ramp length. Every boundary is forced
    ///      strictly increasing and leaves at least one block for each remaining step, so no step
    ///      can collapse to a zero-length window. The final block absorbs whatever milli-percent
    ///      the integer-rounded ramp did not emit, which makes the total exact by construction.
    /// @param startBlock The first block of the auction.
    /// @param endBlock The block the auction ends at, exclusive.
    /// @param rampSteps The number of equal-supply ramp steps.
    /// @param finalBlockMps The milli-percent reserved for the single final block.
    /// @return schedule The packed schedule.
    function convexSchedule(uint64 startBlock, uint64 endBlock, uint256 rampSteps, uint256 finalBlockMps)
        internal
        pure
        returns (bytes memory schedule)
    {
        if (endBlock <= startBlock) revert WindowTooShort();
        if (rampSteps == 0) revert NoRampSteps();
        if (finalBlockMps == 0 || finalBlockMps >= MPS_TOTAL) revert InvalidFinalShare();

        uint64 rampBlocks = endBlock - startBlock - 1;
        if (rampBlocks < 1) revert WindowTooShort();
        if (rampSteps > rampBlocks) rampSteps = rampBlocks;

        uint256 rampMps = MPS_TOTAL - finalBlockMps;
        uint256 emitted;

        uint64[] memory boundaries = _boundaries(rampBlocks, rampSteps);

        schedule = new bytes(0);
        for (uint256 i = 0; i < rampSteps; ++i) {
            uint64 duration = boundaries[i + 1] - boundaries[i];
            uint256 stepMps = _roundDiv(rampMps, rampSteps * uint256(duration));
            if (stepMps == 0) stepMps = 1;
            emitted += stepMps * uint256(duration);
            schedule = bytes.concat(schedule, _pack(uint24(stepMps), uint40(duration)));
        }

        if (emitted >= MPS_TOTAL) revert InvalidFinalShare();
        schedule = bytes.concat(schedule, _pack(uint24(MPS_TOTAL - emitted), uint40(1)));
    }

    /// @notice The cumulative block boundaries of the ramp, in blocks from the auction start.
    /// @param rampBlocks The number of blocks the ramp spans.
    /// @param rampSteps The number of ramp steps.
    /// @return boundaries `rampSteps + 1` strictly increasing boundaries, starting at zero and
    ///         ending at `rampBlocks`.
    function _boundaries(uint64 rampBlocks, uint256 rampSteps) private pure returns (uint64[] memory boundaries) {
        boundaries = new uint64[](rampSteps + 1);
        for (uint256 i = 1; i < rampSteps; ++i) {
            // t = (i / rampSteps) ^ (1 / 1.2) = (i / rampSteps) ^ (5 / 6), evaluated as a
            // sixth root of the fifth power in 1e18 fixed point.
            uint256 t = _pow5over6(_mulDiv(i, 1e18, rampSteps));
            uint64 raw = uint64(_mulDiv(t, rampBlocks, 1e18));
            uint64 lo = boundaries[i - 1] + 1;
            uint64 hi = rampBlocks - uint64(rampSteps - i);
            boundaries[i] = raw < lo ? lo : (raw > hi ? hi : raw);
        }
        boundaries[rampSteps] = rampBlocks;
    }

    /// @notice Raises a 1e18-scaled fraction in [0, 1] to the power 5/6.
    /// @dev Computed as the sixth root of the fifth power. The sixth root is three nested square
    ///      roots would be the eighth root, so the cube root is taken by Newton iteration and the
    ///      square root by the OpenZeppelin-style bit method, both in 1e18 fixed point.
    /// @param x The base, scaled by 1e18.
    /// @return The result, scaled by 1e18.
    function _pow5over6(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        uint256 x5 = x;
        for (uint256 i = 0; i < 4; ++i) {
            x5 = _mulDiv(x5, x, 1e18);
        }
        return _cbrt(_sqrt(x5));
    }

    /// @notice The square root of a 1e18-scaled value, in 1e18 fixed point.
    /// @param x The value.
    /// @return The square root.
    function _sqrt(uint256 x) private pure returns (uint256) {
        if (x == 0) return 0;
        uint256 value = x * 1e18;
        uint256 result = 1;
        uint256 remaining = value;
        if (remaining >= 1 << 128) {
            remaining >>= 128;
            result <<= 64;
        }
        if (remaining >= 1 << 64) {
            remaining >>= 64;
            result <<= 32;
        }
        if (remaining >= 1 << 32) {
            remaining >>= 32;
            result <<= 16;
        }
        if (remaining >= 1 << 16) {
            remaining >>= 16;
            result <<= 8;
        }
        if (remaining >= 1 << 8) {
            remaining >>= 8;
            result <<= 4;
        }
        if (remaining >= 1 << 4) {
            remaining >>= 4;
            result <<= 2;
        }
        if (remaining >= 1 << 2) result <<= 1;
        for (uint256 i = 0; i < 7; ++i) {
            result = (result + value / result) >> 1;
        }
        uint256 down = value / result;
        return result <= down ? result : down;
    }

    /// @notice The cube root of a 1e18-scaled value, in 1e18 fixed point.
    /// @param x The value.
    /// @return result The cube root.
    function _cbrt(uint256 x) private pure returns (uint256 result) {
        if (x == 0) return 0;
        result = 1e18;
        for (uint256 i = 0; i < 60; ++i) {
            uint256 square = _mulDiv(result, result, 1e18);
            uint256 next = (2 * result + _mulDiv(x, 1e18, square)) / 3;
            if (next == result) break;
            result = next;
        }
    }

    /// @notice Full-precision multiply then divide for the magnitudes used here.
    /// @param a The first factor.
    /// @param b The second factor.
    /// @param denominator The divisor.
    /// @return The result.
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256) {
        return (a * b) / denominator;
    }

    /// @notice Integer division rounded to nearest.
    /// @param numerator The dividend.
    /// @param denominator The divisor.
    /// @return The rounded quotient.
    function _roundDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return (numerator + denominator / 2) / denominator;
    }

    /// @notice Packs one step into the auction's 8-byte word layout.
    /// @param mps The milli-percent released per block during the step.
    /// @param blockDelta The number of blocks the step spans.
    /// @return The packed word.
    function _pack(uint24 mps, uint40 blockDelta) private pure returns (bytes8) {
        return bytes8((uint64(mps) << 40) | uint64(blockDelta));
    }

    /// @notice Re-derives the totals a packed schedule implies, for assertions and scripts.
    /// @param schedule The packed schedule.
    /// @return totalMps The sum of `mps * blockDelta` across every step.
    /// @return totalBlocks The sum of the block deltas.
    /// @return steps The number of steps.
    function totals(bytes memory schedule) internal pure returns (uint256 totalMps, uint64 totalBlocks, uint256 steps) {
        steps = schedule.length / 8;
        for (uint256 i = 0; i < steps; ++i) {
            (uint24 mps, uint40 blockDelta) = stepAt(schedule, i);
            totalMps += uint256(mps) * uint256(blockDelta);
            totalBlocks += uint64(blockDelta);
        }
    }

    /// @notice Reads one step out of a packed schedule.
    /// @param schedule The packed schedule.
    /// @param index The step index.
    /// @return mps The milli-percent per block.
    /// @return blockDelta The number of blocks the step spans.
    function stepAt(bytes memory schedule, uint256 index) internal pure returns (uint24 mps, uint40 blockDelta) {
        uint256 offset = index * 8;
        bytes8 word;
        assembly ("memory-safe") {
            word := mload(add(add(schedule, 0x20), offset))
        }
        mps = uint24(bytes3(word));
        blockDelta = uint40(uint64(word));
    }
}
