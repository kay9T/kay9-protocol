// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {MigratorParameters} from "./LauncherTypes.sol";
import {ILBPInitializer} from "./ILBPInitializer.sol";
import {IDistributorFactory} from "./IDistributorFactory.sol";

/// @title ILBPStrategy
/// @notice The subset of the canonical Uniswap LBPStrategy that KAY9 reads and calls.
/// @dev Mirrors `Uniswap/liquidity-launcher` LBPStrategy v3.1.1 at
///      0x05d552391067389EE44fec3924157ed33F976000.
interface ILBPStrategy {
    /// @notice Emitted when the strategy has created the auction (the LBP initializer).
    /// @param initializer The created auction.
    /// @param migrationParams The migration parameters registered against it.
    event InitializerCreated(ILBPInitializer indexed initializer, MigratorParameters migrationParams);

    /// @notice Emitted when the strategy successfully migrated an auction into a v4 pool.
    /// @param initializer The migrated auction.
    /// @param key The pool key that was initialized.
    /// @param initialSqrtPriceX96 The initialization price.
    /// @param plan The PositionManager plan that was executed.
    event Migrated(ILBPInitializer indexed initializer, PoolKey indexed key, uint160 initialSqrtPriceX96, bytes plan);

    /// @notice Emitted when a migration reverted and the reserves were returned to the recipient.
    /// @param initializer The auction that failed to migrate.
    /// @param reason The revert data of the failed migration.
    event MigrationFailed(ILBPInitializer indexed initializer, bytes reason);

    /// @notice Migrates a graduated auction into a Uniswap v4 pool. Permissionless.
    /// @param initializer The auction to migrate.
    function migrate(ILBPInitializer initializer) external;

    /// @notice The migration parameters registered for an auction, or a zeroed struct if unknown.
    /// @param initializer The auction to look up.
    /// @return The stored migration parameters.
    function initializers(ILBPInitializer initializer) external view returns (MigratorParameters memory);

    /// @notice The auction that has reserved a pool id, zeroed once that auction has migrated.
    /// @param poolId The pool id to look up.
    /// @return The auction holding the reservation.
    function registeredPoolIds(PoolId poolId) external view returns (address);

    /// @notice The factory the strategy deploys auctions through.
    /// @return The CCA factory.
    function initializerFactory() external view returns (IDistributorFactory);

    /// @notice The Uniswap v4 PositionManager the strategy mints through.
    /// @return The position manager.
    function positionManager() external view returns (IPositionManager);

    /// @notice The Uniswap v4 PoolManager the strategy initializes pools on.
    /// @return The pool manager.
    function poolManager() external view returns (IPoolManager);
}
