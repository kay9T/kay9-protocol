// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IDistributorFactory
/// @notice The deterministic-deployment surface of the Continuous Clearing Auction factory.
/// @dev Mirrors `Uniswap/liquidity-launcher` IDistributorFactory as implemented by
///      ContinuousClearingAuctionFactory v2.1.0 at 0x000000001F26a0044BaA66024e7b6599c61963F8.
interface IDistributorFactory {
    /// @notice Predicts the address a distributor would be deployed to.
    /// @param token The token that will be distributed.
    /// @param totalSupply The supply that will be distributed.
    /// @param configData The abi-encoded factory-specific configuration.
    /// @param salt The salt the factory will hash with `sender`.
    /// @param sender The address that would call `create`.
    /// @return distributor The predicted distributor address.
    function getAddress(address token, uint256 totalSupply, bytes calldata configData, bytes32 salt, address sender)
        external
        view
        returns (address distributor);
}
