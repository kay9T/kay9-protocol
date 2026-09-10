// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LBPInitializationParams} from "./LauncherTypes.sol";

/// @title ILBPInitializer
/// @notice The generic price-discovery contract an LBP strategy migrates from.
/// @dev Mirrors `Uniswap/liquidity-launcher` ILBPInitializer.
interface ILBPInitializer {
    /// @notice The pricing outcome of the distribution. Reverts while the auction has not graduated.
    /// @return The discovered price, tokens sold and currency raised.
    function lbpInitializationParams() external view returns (LBPInitializationParams memory);

    /// @notice Sends the raised currency to the funds recipient. Callable only by that recipient.
    function sweepCurrency() external;

    /// @notice Sends the unsold tokens to the tokens recipient. Callable only by that recipient.
    function sweepUnsoldTokens() external;

    /// @notice The token being distributed.
    /// @return The token address.
    function token() external view returns (address);

    /// @notice The currency being raised.
    /// @return The currency address, address(0) for native ETH.
    function currency() external view returns (address);

    /// @notice The amount of the token offered.
    /// @return The offered supply.
    function totalSupply() external view returns (uint128);

    /// @notice The recipient of unsold tokens.
    /// @return The tokens recipient.
    function tokensRecipient() external view returns (address);

    /// @notice The recipient of the raised currency.
    /// @return The funds recipient.
    function fundsRecipient() external view returns (address);

    /// @notice The block the distribution starts at.
    /// @return The start block.
    function startBlock() external view returns (uint64);

    /// @notice The block the distribution ends at.
    /// @return The end block.
    function endBlock() external view returns (uint64);
}
