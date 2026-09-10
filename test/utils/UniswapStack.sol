// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LiquidityLauncher} from "liquidity-launcher/src/LiquidityLauncher.sol";
import {LBPStrategy} from "liquidity-launcher/src/strategies/lbp/LBPStrategy.sol";
import {IDistributorFactory} from "liquidity-launcher/src/interfaces/IDistributorFactory.sol";
import {FeeSplitter} from "liquidity-launcher/src/periphery/FeeSplitter.sol";
import {FeeSplit} from "liquidity-launcher/src/interfaces/IFeeSplitter.sol";
import {UERC20BeneficiaryVault} from "liquidity-launcher/src/periphery/UERC20BeneficiaryVault.sol";
import {CompoundingClaimRecipient} from "liquidity-launcher/src/periphery/CompoundingClaimRecipient.sol";
import {InitializerHook} from "./InitializerHook.sol";
import {ContinuousClearingAuctionFactory} from "continuous-clearing-auction/src/ContinuousClearingAuctionFactory.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

/// @notice Every canonical Uniswap address KAY9 depends on, deployed locally.
struct UniswapDeployment {
    IPoolManager poolManager;
    IPositionManager positionManager;
    IAllowanceTransfer permit2;
    LiquidityLauncher launcher;
    LBPStrategy lbpStrategy;
    ContinuousClearingAuctionFactory auctionFactory;
    InitializerHook initializerHook;
    UERC20BeneficiaryVault beneficiaryVault;
    CompoundingClaimRecipient compounding;
    FeeSplitter feeSplitter;
}

/// @title UniswapStack
/// @notice Deploys the real Uniswap v4, liquidity launcher and continuous clearing auction
///         contracts from their upstream sources, wired the way Robinhood Chain has them wired.
/// @dev Using the genuine implementations rather than mocks is what makes the local tests
///       meaningful: the salt derivation, the struct encodings and the migration behaviour under
///       test are the ones that will run on mainnet.
library UniswapStack {
    /// @notice The 40 % native share the beneficiary vault receives on Robinhood Chain.
    uint16 internal constant VAULT_NATIVE_BPS = 4000;

    /// @notice The 60 % native share the compounding recipient receives.
    uint16 internal constant COMPOUNDING_NATIVE_BPS = 6000;

    /// @notice The full token-side share the compounding recipient receives.
    uint16 internal constant COMPOUNDING_TOKEN_BPS = 10_000;

    /// @notice The minimum liquidity increase the canonical compounding recipient enforces.
    uint128 internal constant MIN_LIQUIDITY_INCREASE = 1e20;

    /// @notice Deploys the whole stack.
    /// @param permit2 The already-deployed canonical Permit2.
    /// @param nativeFallback The vault's native fallback recipient.
    /// @param tokenFallback The vault's token fallback recipient.
    /// @return d The deployed contracts.
    function deploy(IAllowanceTransfer permit2, address nativeFallback, address tokenFallback)
        internal
        returns (UniswapDeployment memory d)
    {
        d.permit2 = permit2;
        d.poolManager = IPoolManager(address(new PoolManager(address(0))));
        d.positionManager = IPositionManager(
            address(
                new PositionManager(
                    d.poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0))
                )
            )
        );
        d.auctionFactory = new ContinuousClearingAuctionFactory(address(0));

        // The strategy doubles as the fallback initialization hook, so its address has to carry the
        // beforeInitialize permission bit exactly as the canonical mainnet deployment does.
        (, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_INITIALIZE_FLAG),
            type(LBPStrategy).creationCode,
            abi.encode(d.positionManager, d.poolManager, IDistributorFactory(address(d.auctionFactory)))
        );
        d.lbpStrategy = new LBPStrategy{salt: salt}(
            d.positionManager, d.poolManager, IDistributorFactory(address(d.auctionFactory))
        );
        d.launcher = new LiquidityLauncher(permit2);

        // The official KAY9 pool is keyed on a canonical InitializerHook whose authorized
        // initializer is the strategy, so its address also has to carry the beforeInitialize
        // permission bit and nothing else, exactly like the mainnet deployment.
        (, bytes32 hookSalt) = HookMiner.find(
            address(this),
            uint160(Hooks.BEFORE_INITIALIZE_FLAG),
            type(InitializerHook).creationCode,
            abi.encode(d.poolManager, address(d.lbpStrategy))
        );
        d.initializerHook = new InitializerHook{salt: hookSalt}(d.poolManager, address(d.lbpStrategy));

        d.beneficiaryVault = new UERC20BeneficiaryVault(d.positionManager, nativeFallback, tokenFallback);
        d.compounding = new CompoundingClaimRecipient(d.positionManager, MIN_LIQUIDITY_INCREASE);

        FeeSplit[] memory splits = new FeeSplit[](2);
        splits[0] = FeeSplit({
            recipient: address(d.beneficiaryVault), nativeBps: VAULT_NATIVE_BPS, tokenBps: 0, useCallback: true
        });
        splits[1] = FeeSplit({
            recipient: address(d.compounding),
            nativeBps: COMPOUNDING_NATIVE_BPS,
            tokenBps: COMPOUNDING_TOKEN_BPS,
            useCallback: true
        });
        d.feeSplitter = new FeeSplitter(d.positionManager, splits);
    }
}
