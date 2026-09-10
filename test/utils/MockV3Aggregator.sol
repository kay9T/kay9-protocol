// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "../../src/interfaces/external/AggregatorV3Interface.sol";

/// @title MockV3Aggregator
/// @notice A minimal, fully controllable Chainlink aggregator for tests and for the testnet
///         rehearsal, where Robinhood Chain testnet has no real ETH/USD feed.
contract MockV3Aggregator is AggregatorV3Interface {
    /// @notice The answer decimals.
    uint8 public immutable override decimals;

    /// @notice The latest round id.
    uint80 public roundId;

    /// @notice The latest answer.
    int256 public answer;

    /// @notice The timestamp the latest answer was written at.
    uint256 public updatedAt;

    /// @notice The round the latest answer was computed in.
    uint80 public answeredInRound;

    /// @notice Deploys the mock with an initial answer.
    /// @param decimals_ The answer decimals.
    /// @param initialAnswer The first answer.
    constructor(uint8 decimals_, int256 initialAnswer) {
        decimals = decimals_;
        updateAnswer(initialAnswer);
    }

    /// @notice Writes a new answer, stamped with the current block timestamp.
    /// @param newAnswer The new answer.
    function updateAnswer(int256 newAnswer) public {
        roundId += 1;
        answeredInRound = roundId;
        answer = newAnswer;
        updatedAt = block.timestamp;
    }

    /// @notice Writes a new answer with an explicit timestamp, for staleness tests.
    /// @param newAnswer The new answer.
    /// @param updatedAt_ The timestamp to stamp the answer with.
    function updateAnswerAt(int256 newAnswer, uint256 updatedAt_) external {
        roundId += 1;
        answeredInRound = roundId;
        answer = newAnswer;
        updatedAt = updatedAt_;
    }

    /// @notice Forces the round bookkeeping into an incomplete state, for validity tests.
    /// @param roundId_ The reported round id.
    /// @param answeredInRound_ The round the answer was computed in.
    function setRounds(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    /// @inheritdoc AggregatorV3Interface
    function description() external pure override returns (string memory) {
        return "ETH / USD";
    }

    /// @inheritdoc AggregatorV3Interface
    function version() external pure override returns (uint256) {
        return 3;
    }

    /// @inheritdoc AggregatorV3Interface
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
