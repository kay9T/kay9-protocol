// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {LiquidityLauncher} from "liquidity-launcher/src/LiquidityLauncher.sol";
import {LBPStrategy} from "liquidity-launcher/src/strategies/lbp/LBPStrategy.sol";
import {IDistributorFactory} from "liquidity-launcher/src/interfaces/IDistributorFactory.sol";
import {FeeSplitter} from "liquidity-launcher/src/periphery/FeeSplitter.sol";
import {FeeSplit} from "liquidity-launcher/src/interfaces/IFeeSplitter.sol";
import {UERC20BeneficiaryVault} from "liquidity-launcher/src/periphery/UERC20BeneficiaryVault.sol";
import {CompoundingClaimRecipient} from "liquidity-launcher/src/periphery/CompoundingClaimRecipient.sol";
import {InitializerHook} from "../test/utils/InitializerHook.sol";

import {KAY9Genesis} from "../src/KAY9Genesis.sol";
import {KAY9AuditorRegistry} from "../src/KAY9AuditorRegistry.sol";
import {KAY9Registry} from "../src/KAY9Registry.sol";
import {KAY9AccessVault} from "../src/KAY9AccessVault.sol";
import {KAY9AuditHub} from "../src/KAY9AuditHub.sol";
import {ChainAddresses, RobinhoodAddresses} from "./config/RobinhoodAddresses.sol";

/// @title Testnet
/// @notice Rehearses the whole launch on Robinhood Chain testnet, where the Uniswap v4 core, the
///         position manager, Permit2 and the continuous clearing auction factory exist at the same
///         addresses as mainnet but the liquidity launcher stack does not.
/// @dev The missing pieces are deployed from the same upstream sources the mainnet contracts were
///      built from, so the rehearsal covers every step of the real launch except that the launcher,
///      the strategy and the fee splitter live at different addresses. What testnet therefore does
///      not prove is the exact bytecode of those three dependencies; everything else, including the
///      auction, the migration, the locking, the settlement and the oracle, behaves identically.
contract Testnet is Script {
    /// @notice The native share of LP fees the beneficiary vault receives on mainnet.
    uint16 internal constant VAULT_NATIVE_BPS = 4000;

    /// @notice The native share of LP fees the compounding recipient receives on mainnet.
    uint16 internal constant COMPOUNDING_NATIVE_BPS = 6000;

    /// @notice The token share of LP fees the compounding recipient receives on mainnet.
    uint16 internal constant COMPOUNDING_TOKEN_BPS = 10_000;

    /// @notice The minimum liquidity increase the mainnet compounding recipient enforces.
    uint128 internal constant MIN_LIQUIDITY_INCREASE = 1e20;

    /// @notice The deep audit target, ten US dollars scaled by 1e8.

    /// @notice Thrown when the script is pointed at anything other than Robinhood Chain testnet.
    /// @param chainId The offending chain.
    error NotTestnet(uint256 chainId);

    /// @notice Deploys the launcher stand-ins and the whole KAY9 protocol.
    function run() external {
        if (block.chainid != RobinhoodAddresses.TESTNET_CHAIN_ID) revert NotTestnet(block.chainid);
        ChainAddresses memory book = RobinhoodAddresses.testnet();

        address deployer = msg.sender;
        address ownerSafe = vm.envOr("OWNER_SAFE", deployer);
        address treasury = vm.envOr("TREASURY", deployer);
        address teamBeneficiary = vm.envOr("TEAM_BENEFICIARY", deployer);
        address creatorFeeRecipient = vm.envOr("CREATOR_FEE_RECIPIENT", deployer);

        uint64 tge = uint64(vm.envOr("TGE_TIMESTAMP", block.timestamp));
        uint64 unlock6m = uint64(vm.envOr("UNLOCK_6M_TIMESTAMP", block.timestamp + 182 days));
        uint64 unlock12m = uint64(vm.envOr("UNLOCK_12M_TIMESTAMP", block.timestamp + 365 days));

        vm.startBroadcast();

        IPoolManager poolManager = IPoolManager(book.poolManager);
        IPositionManager positionManager = IPositionManager(book.positionManager);
        IAllowanceTransfer permit2 = IAllowanceTransfer(book.permit2);

        LBPStrategy lbpStrategy = _deployStrategy(positionManager, poolManager, book.auctionFactory);
        LiquidityLauncher launcher = new LiquidityLauncher(permit2);
        InitializerHook initializerHook = _deployInitializerHook(poolManager, address(lbpStrategy));

        UERC20BeneficiaryVault vault = new UERC20BeneficiaryVault(positionManager, deployer, address(0xdEaD));
        CompoundingClaimRecipient compounding = new CompoundingClaimRecipient(positionManager, MIN_LIQUIDITY_INCREASE);

        FeeSplit[] memory splits = new FeeSplit[](2);
        splits[0] = FeeSplit({recipient: address(vault), nativeBps: VAULT_NATIVE_BPS, tokenBps: 0, useCallback: true});
        splits[1] = FeeSplit({
            recipient: address(compounding),
            nativeBps: COMPOUNDING_NATIVE_BPS,
            tokenBps: COMPOUNDING_TOKEN_BPS,
            useCallback: true
        });
        FeeSplitter feeSplitter = new FeeSplitter(positionManager, splits);

        address[] memory single = new address[](1);
        single[0] = ownerSafe;
        /*
         * A rehearsal must not inherit mainnet's 48 hour governance delay.
         *
         * Every administrative step the rehearsal has to take — binding the price oracle to the
         * new pool, accepting the access vault's ownership, adding auditors — goes through this
         * timelock. With 48 hours on it, the access model cannot be exercised on the same day the
         * contracts are deployed, which is the opposite of what a rehearsal is for. What testnet
         * proves is that the protocol works; the delay itself is a mainnet policy and is asserted
         * separately in the unit tests.
         *
         * Override it with TIMELOCK_DELAY_SECONDS to rehearse the real delay deliberately.
         */
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY_SECONDS", uint256(60));
        TimelockController timelock = new TimelockController(timelockDelay, single, single, address(0));

        KAY9Genesis genesis = new KAY9Genesis(
            ownerSafe,
            teamBeneficiary,
            tge,
            unlock6m,
            unlock12m,
            creatorFeeRecipient,
            address(launcher),
            address(lbpStrategy),
            address(positionManager),
            address(poolManager),
            address(permit2),
            address(feeSplitter),
            address(vault),
            address(initializerHook)
        );

        address[] memory auditors = vm.envOr("AUDITORS", ",", single);
        KAY9AuditorRegistry auditorRegistry =
            new KAY9AuditorRegistry(address(timelock), auditors, uint8(vm.envOr("AUDITOR_THRESHOLD", uint256(1))));
        // The vault is deployed before the hub because the hub takes its address at construction.
        // It is owned by the deployer only long enough to point it at the hub, then handed over.
        KAY9AccessVault accessVault = new KAY9AccessVault(deployer, IERC20(address(genesis.token())));

        // The registry and the hub reference each other, so the hub address is predicted from the
        // broadcasting key's nonce and verified immediately after both are on-chain.
        address predictedHub = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        KAY9Registry reportRegistry = new KAY9Registry(predictedHub);
        KAY9AuditHub auditHub =
            new KAY9AuditHub(address(timelock), address(reportRegistry), auditorRegistry, accessVault);
        require(address(auditHub) == predictedHub, "hub address prediction failed");

        accessVault.setAuditHub(address(auditHub));
        accessVault.transferOwnership(address(timelock));

        vm.stopBroadcast();

        console2.log("=== KAY9 testnet rehearsal ===");
        console2.log("LiquidityLauncher (rehearsal copy)", address(launcher));
        console2.log("LBPStrategy       (rehearsal copy)", address(lbpStrategy));
        console2.log("InitializerHook   (rehearsal copy)", address(initializerHook));
        console2.log("FeeSplitter       (rehearsal copy)", address(feeSplitter));
        console2.log("BeneficiaryVault  (rehearsal copy)", address(vault));
        console2.log("Compounding       (rehearsal copy)", address(compounding));
        console2.log("TimelockController                ", address(timelock));
        console2.log("KAY9Genesis                       ", address(genesis));
        console2.log("KAY9Token                         ", address(genesis.token()));
        console2.log("KAY9TeamVesting                   ", address(genesis.teamVesting()));
        console2.log("KAY9LiquidityLock                 ", address(genesis.liquidityLock()));
        console2.log("KAY9AuditorRegistry               ", address(auditorRegistry));
        console2.log("KAY9Registry                      ", address(reportRegistry));
        console2.log("KAY9AuditHub                      ", address(auditHub));
        console2.log("CCA factory (canonical)           ", book.auctionFactory);
    }

    /// @notice Deploys the LBP strategy at an address carrying the beforeInitialize permission bit.
    /// @dev The strategy is its own fallback initialization hook, so Uniswap v4 requires its address
    ///      to encode exactly that permission. The salt is mined against the canonical CREATE2
    ///      deployer, which is what forge uses when a script deploys with a salt.
    /// @param positionManager The v4 position manager.
    /// @param poolManager The v4 pool manager.
    /// @param auctionFactory The continuous clearing auction factory.
    /// @return The deployed strategy.
    function _deployStrategy(IPositionManager positionManager, IPoolManager poolManager, address auctionFactory)
        internal
        returns (LBPStrategy)
    {
        bytes memory creationCode = abi.encodePacked(
            type(LBPStrategy).creationCode,
            abi.encode(positionManager, poolManager, IDistributorFactory(auctionFactory))
        );
        address create2Deployer = RobinhoodAddresses.testnet().create2Deployer;
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);
        for (uint256 salt = 0; salt < 200_000; ++salt) {
            address candidate = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xFF), create2Deployer, bytes32(salt), keccak256(creationCode))
                        )
                    )
                )
            );
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == flags && candidate.code.length == 0) {
                LBPStrategy deployed = new LBPStrategy{salt: bytes32(salt)}(
                    positionManager, poolManager, IDistributorFactory(auctionFactory)
                );
                require(address(deployed) == candidate, "strategy salt mismatch");
                return deployed;
            }
        }
        revert("no hook salt found");
    }

    /// @notice Deploys the initializer hook the official pool is keyed on, bound to the rehearsal
    ///         strategy, at an address carrying the beforeInitialize permission bit and no other.
    /// @dev Mainnet uses the canonical hook at 0xD462a559337859369EF271814851A18F496ba000, which
    ///      testnet does not have. The salt is mined against the canonical CREATE2 deployer, which
    ///      is what forge uses when a script deploys with a salt.
    /// @param poolManager The v4 pool manager.
    /// @param authorized The strategy allowed to initialize pools keyed on this hook.
    /// @return The deployed hook.
    function _deployInitializerHook(IPoolManager poolManager, address authorized) internal returns (InitializerHook) {
        bytes memory creationCode =
            abi.encodePacked(type(InitializerHook).creationCode, abi.encode(poolManager, authorized));
        address create2Deployer = RobinhoodAddresses.testnet().create2Deployer;
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG);
        for (uint256 salt = 0; salt < 200_000; ++salt) {
            address candidate = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(bytes1(0xFF), create2Deployer, bytes32(salt), keccak256(creationCode))
                        )
                    )
                )
            );
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == flags && candidate.code.length == 0) {
                InitializerHook deployed = new InitializerHook{salt: bytes32(salt)}(poolManager, authorized);
                require(address(deployed) == candidate, "hook salt mismatch");
                return deployed;
            }
        }
        revert("no hook salt found");
    }
}
