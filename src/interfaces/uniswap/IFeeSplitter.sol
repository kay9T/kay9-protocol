// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice One recipient's fee allocation. Both sides are independent basis-point shares.
/// @dev Layout copied verbatim from `Uniswap/liquidity-launcher` IFeeSplitter.
struct FeeSplit {
    address recipient;
    uint16 nativeBps;
    uint16 tokenBps;
    bool useCallback;
}

/// @title IFeeSplitter
/// @notice The terminal custodian of the KAY9 LP positions.
/// @dev Mirrors `Uniswap/liquidity-launcher` IFeeSplitter as implemented at
///      0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf (40 % native to the beneficiary vault,
///      60 % native and 100 % token compounded back into the position).
interface IFeeSplitter {
    /// @notice Emitted once per collected position.
    /// @param tokenId The collected position.
    /// @param token The pool's currency1.
    /// @param nativeAmount The native fees collected.
    /// @param tokenAmount The token fees collected.
    event FeesCollected(uint256 indexed tokenId, address indexed token, uint256 nativeAmount, uint256 tokenAmount);

    /// @notice Collects the accrued fees of each position and pushes the configured splits.
    /// @param tokenIds The positions to collect.
    function collectFees(uint256[] calldata tokenIds) external;

    /// @notice The immutable split configuration.
    /// @return The configured splits.
    function getSplits() external view returns (FeeSplit[] memory);
}
