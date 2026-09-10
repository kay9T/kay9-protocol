// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IStateView
/// @notice The read-only view of Uniswap v4 pool state the website uses.
/// @dev Mirrors the canonical StateView lens at 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b.
interface IStateView {
    /// @notice The pool's current price, tick and fees.
    /// @param poolId The pool.
    /// @return sqrtPriceX96 The current sqrt price.
    /// @return tick The current tick.
    /// @return protocolFee The protocol fee.
    /// @return lpFee The LP fee.
    function getSlot0(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    /// @notice The pool's in-range liquidity.
    /// @param poolId The pool.
    /// @return liquidity The active liquidity.
    function getLiquidity(PoolId poolId) external view returns (uint128 liquidity);

    /// @notice The pool's global fee growth.
    /// @param poolId The pool.
    /// @return feeGrowthGlobal0 The currency0 fee growth.
    /// @return feeGrowthGlobal1 The currency1 fee growth.
    function getFeeGrowthGlobals(PoolId poolId)
        external
        view
        returns (uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1);
}
