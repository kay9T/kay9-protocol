// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ILBPInitializer} from "./ILBPInitializer.sol";

/// @notice One checkpoint of the auction's clearing state.
/// @dev Field layout copied verbatim from `Uniswap/continuous-clearing-auction` CheckpointLib.
///      `currencyRaisedAtClearingPriceQ96X7` is the upstream `ValueX7` user-defined type, which is
///      a plain `uint256` at the ABI level.
struct Checkpoint {
    uint256 clearingPrice;
    uint256 currencyRaisedAtClearingPriceQ96X7;
    uint256 cumulativeMpsPerPrice;
    uint24 cumulativeMps;
    uint64 prev;
    uint64 next;
}

/// @title IContinuousClearingAuction
/// @notice The subset of the Continuous Clearing Auction that KAY9 and the website use.
/// @dev Mirrors `Uniswap/continuous-clearing-auction` v2.1.0. Auctions are deployed by the
///      canonical factory at 0x000000001F26a0044BaA66024e7b6599c61963F8.
interface IContinuousClearingAuction is ILBPInitializer {
    /// @notice Emitted for every accepted bid.
    /// @param id The bid id.
    /// @param owner The bid owner.
    /// @param priceQ96 The bid's maximum price.
    /// @param amount The currency committed.
    event BidSubmitted(uint256 indexed id, address indexed owner, uint256 priceQ96, uint128 amount);

    /// @notice Submits a bid, optionally hinting the previous initialized tick.
    /// @param maxPriceQ96 The highest Q96 price the bidder accepts.
    /// @param amount The currency amount committed.
    /// @param owner The address credited with the bid.
    /// @param prevTickPriceQ96 A hint for the tick immediately below `maxPriceQ96`.
    /// @param hookData Data forwarded to the validation hook.
    /// @return bidId The id of the new bid.
    function submitBid(
        uint256 maxPriceQ96,
        uint128 amount,
        address owner,
        uint256 prevTickPriceQ96,
        bytes calldata hookData
    ) external payable returns (uint256 bidId);

    /// @notice Submits a bid without a tick hint.
    /// @param maxPriceQ96 The highest Q96 price the bidder accepts.
    /// @param amount The currency amount committed.
    /// @param owner The address credited with the bid.
    /// @param hookData Data forwarded to the validation hook.
    /// @return bidId The id of the new bid.
    function submitBid(uint256 maxPriceQ96, uint128 amount, address owner, bytes calldata hookData)
        external
        payable
        returns (uint256 bidId);

    /// @notice Advances the auction clock and records a checkpoint for the current block.
    /// @return The checkpoint at the current block.
    function checkpoint() external returns (Checkpoint memory);

    /// @notice The most recent clearing price.
    /// @return The clearing price in Q96 currency-per-token.
    function clearingPrice() external view returns (uint256);

    /// @notice Whether the auction has raised at least `requiredCurrencyRaised`.
    /// @return True once the auction has graduated.
    function isGraduated() external view returns (bool);

    /// @notice Refunds a bid that cleared above the final price.
    /// @param bidId The bid to exit.
    function exitBid(uint256 bidId) external;

    /// @notice Refunds the unfilled part of a partially filled bid.
    /// @param bidId The bid to exit.
    /// @param lastFullyFilledCheckpointBlock The last block whose clearing price was below the bid price.
    /// @param outbidBlock The first block whose clearing price exceeded the bid price, or 0.
    function exitPartiallyFilledBid(uint256 bidId, uint64 lastFullyFilledCheckpointBlock, uint64 outbidBlock) external;

    /// @notice Sends an exited bid's tokens to its owner after the claim block.
    /// @param bidId The bid to claim.
    function claimTokens(uint256 bidId) external;

    /// @notice The currency raised as of the last checkpoint.
    /// @return The raised amount.
    function currencyRaised() external view returns (uint256);

    /// @notice The tokens cleared as of the last checkpoint.
    /// @return The cleared amount.
    function totalCleared() external view returns (uint256);

    /// @notice The unsold supply as of the last checkpoint.
    /// @return The remaining supply.
    function remainingSupply() external view returns (uint256);

    /// @notice The block at which the raised currency was swept, or 0.
    /// @return The sweep block.
    function sweepCurrencyBlock() external view returns (uint256);

    /// @notice The block at which unsold tokens were swept, or 0.
    /// @return The sweep block.
    function sweepUnsoldTokensBlock() external view returns (uint256);

    /// @notice The block after which purchased tokens can be claimed.
    /// @return The claim block.
    function claimBlock() external view returns (uint64);
}
