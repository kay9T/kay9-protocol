// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Struct definitions copied verbatim from the Uniswap Liquidity Launcher
// (github.com/Uniswap/liquidity-launcher, LiquidityLauncher v3.2.0 / LBPStrategy v3.1.1)
// and from the Continuous Clearing Auction (github.com/Uniswap/continuous-clearing-auction,
// factory v2.1.0). The field order and types must stay byte-identical to the deployed
// contracts, because KAY9Genesis abi-encodes these structs and hands them to those contracts.
// Only the structs and the function selectors KAY9 actually uses are vendored; the upstream
// implementation logic is deliberately not copied.

/// @notice One distribution instruction handed to `LiquidityLauncher.distributeToken`.
struct Distribution {
    address strategy;
    uint128 amount;
    bytes configData;
}

/// @notice Parameters for the Uniswap v4 pool created at migration.
struct PoolParameters {
    uint24 fee;
    int24 tickSpacing;
    address hook;
}

/// @notice Migration parameters consumed by `LBPStrategy.initializeDistribution`.
/// @dev The struct is hashed as part of the initializer salt, so every field affects the
///      predicted auction address.
struct MigratorParameters {
    address token;
    address currency;
    uint64 migrationBlock;
    uint128 reservedTokenAmountForLP;
    address recipient;
    address positionRecipient;
    PoolParameters poolParameters;
    bytes positionDefinitions;
    bytes lpAllocationSchedule;
}

/// @notice One bracket of the LP allocation schedule, in milli-percent (1e7 = 100 %).
struct LiquidityAllocationBracket {
    uint128 lowerThreshold;
    uint24 rate;
}

/// @notice A weighted liquidity position expressed as tick offsets from the pool's current tick.
/// @dev The sentinel pair (MIN_TICK, MAX_TICK) resolves to a full-range position.
struct PositionDefinition {
    int24 offsetLower;
    int24 offsetUpper;
    uint24 weight;
    address overridePositionRecipient;
}

/// @notice The pricing outcome an LBP initializer reports to the strategy at migration.
struct LBPInitializationParams {
    uint256 initialPriceX96;
    uint256 tokensSold;
    uint256 currencyRaised;
}

/// @notice Constructor parameters of a Continuous Clearing Auction.
/// @dev `token` and `totalSupply` are separate constructor arguments and are not part of this struct.
struct AuctionParameters {
    address currency;
    address tokensRecipient;
    address fundsRecipient;
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint256 tickSpacing;
    address validationHook;
    uint256 floorPrice;
    uint128 requiredCurrencyRaised;
    bytes auctionStepsData;
}
