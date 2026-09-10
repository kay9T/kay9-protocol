// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IInitializerHook
/// @notice A Uniswap v4 hook that gates pool initialization to a single authorized address.
/// @dev Mirrors `Uniswap/liquidity-launcher` IInitializerHook as implemented by the canonical
///      InitializerHook at 0xD462a559337859369EF271814851A18F496ba000, whose `authorized()` is the
///      LBPStrategy. The hook carries the beforeInitialize permission bit and nothing else, so it
///      never sees a swap, a liquidity change or a donation, and it takes no hook data.
interface IInitializerHook is IERC165 {
    /// @notice The only address allowed to initialize a pool keyed on this hook.
    /// @return The authorized initializer.
    function authorized() external view returns (address);
}
