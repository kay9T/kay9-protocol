// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IInitializerHook} from "../../src/interfaces/uniswap/IInitializerHook.sol";

/// @title InitializerHook
/// @notice A local build of Uniswap's canonical InitializerHook, the hook the official KAY9 pool is
///         keyed on. It permits nothing but `beforeInitialize`, and that only for one address.
/// @dev Upstream lives at `liquidity-launcher/src/periphery/hooks/InitializerHook.sol` and inherits
///      `v4-periphery/src/utils/BaseHook.sol`, which the v4-periphery version this repository pins
///      (1.0.4) does not carry, so it cannot be compiled here. This file reproduces the upstream
///      behaviour that KAY9 depends on, byte for byte in effect: the same constructor permission
///      validation, the same pool-manager-only `beforeInitialize` that reverts for any sender other
///      than `authorized`, and the same ERC-165 answer. The deployed canonical hook at
///      0xD462a559337859369EF271814851A18F496ba000 is what the fork suite exercises.
contract InitializerHook is IHooks, IInitializerHook {
    /// @notice Thrown when someone other than the pool manager calls a hook entry point.
    error NotPoolManager();

    /// @notice Thrown when the caller is not authorized to initialize the pool.
    /// @param caller The rejected initializer.
    /// @param expected The authorized initializer.
    error InvalidInitializer(address caller, address expected);

    /// @notice Thrown when a permission this hook does not hold is exercised.
    error HookNotImplemented();

    /// @notice The v4 pool manager this hook is bound to.
    IPoolManager public immutable poolManager;

    /// @inheritdoc IInitializerHook
    address public immutable authorized;

    /// @notice Deploys the hook and asserts its address carries beforeInitialize and nothing else.
    /// @param poolManager_ The v4 pool manager.
    /// @param authorized_ The only address allowed to initialize pools keyed on this hook.
    constructor(IPoolManager poolManager_, address authorized_) {
        poolManager = poolManager_;
        authorized = authorized_;

        Hooks.Permissions memory permissions;
        permissions.beforeInitialize = true;
        Hooks.validateHookPermissions(IHooks(address(this)), permissions);
    }

    /// @notice Reverts every initialization that does not come from the authorized address.
    /// @param sender The address that called `PoolManager.initialize`.
    /// @return The hook selector.
    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (sender != authorized) revert InvalidInitializer(sender, authorized);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IInitializerHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
