// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title TickRange
/// @notice Tick snapping helpers and the v4 per-tick liquidity cap, reimplemented locally so the
///         genesis vault does not have to pull in the whole v4 Pool library.
library TickRange {
    /// @notice Thrown when a tick spacing is zero or negative.
    error InvalidTickSpacing();

    /// @notice Rounds a tick down to the nearest multiple of the spacing.
    /// @dev Solidity truncates integer division toward zero, so negative ticks need an extra step
    ///      to round toward negative infinity.
    /// @param tick The tick to round.
    /// @param tickSpacing The pool tick spacing.
    /// @return The largest multiple of tickSpacing that is at most tick.
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        int24 rounded = (tick / tickSpacing) * tickSpacing;
        if (tick < 0 && rounded != tick) rounded -= tickSpacing;
        return rounded;
    }

    /// @notice Rounds a tick up to the nearest multiple of the spacing.
    /// @param tick The tick to round.
    /// @param tickSpacing The pool tick spacing.
    /// @return The smallest multiple of tickSpacing that is at least tick.
    function ceilToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        int24 rounded = (tick / tickSpacing) * tickSpacing;
        if (tick > 0 && rounded != tick) rounded += tickSpacing;
        return rounded;
    }

    /// @notice The lowest tick a pool with this spacing can hold liquidity at.
    /// @param tickSpacing The pool tick spacing.
    /// @return The minimum usable tick.
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return TickMath.minUsableTick(tickSpacing);
    }

    /// @notice The highest tick a pool with this spacing can hold liquidity at.
    /// @param tickSpacing The pool tick spacing.
    /// @return The maximum usable tick.
    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return TickMath.maxUsableTick(tickSpacing);
    }

    /// @notice The maximum liquidity a single initialized tick may carry.
    /// @dev Identical to `Pool.tickSpacingToMaxLiquidityPerTick` in v4-core.
    /// @param tickSpacing The pool tick spacing.
    /// @return The per-tick liquidity cap.
    function maxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }
}
