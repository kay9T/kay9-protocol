// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Distribution} from "./LauncherTypes.sol";

/// @title ILiquidityLauncher
/// @notice The subset of the canonical Uniswap LiquidityLauncher that KAY9Genesis calls.
/// @dev Mirrors `Uniswap/liquidity-launcher` v3.2.0 at 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0.
interface ILiquidityLauncher {
    /// @notice Emitted by the launcher once a distribution has been handed to a strategy.
    /// @param tokenAddress The distributed token, or address(0) for native.
    /// @param strategy The strategy that pulled the tokens.
    /// @param amount The distributed amount.
    event TokenDistributed(address indexed tokenAddress, address indexed strategy, uint256 amount);

    /// @notice Batches several launcher calls into one transaction.
    /// @param data The abi-encoded calls to make against the launcher.
    /// @return results The return data of each call.
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);

    /// @notice Pulls `amount` of `token` from the caller into the launcher through Permit2.
    /// @param token The token to pull.
    /// @param amount The amount to pull, capped to Permit2's uint160 allowance type.
    function depositToken(address token, uint160 amount) external payable;

    /// @notice Hands tokens already held by the launcher to a strategy.
    /// @dev The launcher domain-separates the salt as `keccak256(abi.encode(msg.sender, salt))`
    ///      before forwarding it to the strategy.
    /// @param tokenAddress The token to distribute.
    /// @param distribution The distribution instruction.
    /// @param salt The caller-chosen salt.
    function distributeToken(address tokenAddress, Distribution memory distribution, bytes32 salt) external payable;
}
