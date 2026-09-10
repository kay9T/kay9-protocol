// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AggregatorV3Interface
/// @notice The Chainlink price-feed reader interface, vendored so the project does not depend on
///         the Chainlink npm package.
/// @dev Matches `@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol`.
interface AggregatorV3Interface {
    /// @notice The number of decimals the feed's answers carry.
    /// @return The answer decimals.
    function decimals() external view returns (uint8);

    /// @notice A human-readable description of the feed, for example "ETH / USD".
    /// @return The description.
    function description() external view returns (string memory);

    /// @notice The feed's interface version.
    /// @return The version.
    function version() external view returns (uint256);

    /// @notice The most recent completed round.
    /// @return roundId The round id.
    /// @return answer The reported answer, scaled by `decimals()`.
    /// @return startedAt The unix timestamp the round started at.
    /// @return updatedAt The unix timestamp the answer was written at.
    /// @return answeredInRound The round the answer was computed in.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
