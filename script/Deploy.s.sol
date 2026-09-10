// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KAY9Genesis} from "../src/KAY9Genesis.sol";
import {KAY9Token} from "../src/KAY9Token.sol";
import {KAY9TeamVesting} from "../src/KAY9TeamVesting.sol";
import {KAY9LiquidityLock} from "../src/KAY9LiquidityLock.sol";
import {KAY9AuditorRegistry} from "../src/KAY9AuditorRegistry.sol";
import {KAY9Registry} from "../src/KAY9Registry.sol";
import {KAY9Pricing} from "../src/KAY9Pricing.sol";
import {KAY9AccessVault} from "../src/KAY9AccessVault.sol";
import {KAY9AuditHub} from "../src/KAY9AuditHub.sol";
import {AggregatorV3Interface} from "../src/interfaces/external/AggregatorV3Interface.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ChainAddresses, RobinhoodAddresses} from "./config/RobinhoodAddresses.sol";

/// @notice The project-specific addresses and settings the deployment was given.
struct DeployConfig {
    address ownerSafe;
    address teamBeneficiary;
    address creatorFeeRecipient;
    address ethUsdFeed;
    address initializerHook;
    /// @dev The timelock the live watchdog already answers to, or zero to deploy a new one.
    address existingTimelock;
    /// @dev The auditor registry the live watchdog already uses, or zero to deploy a new one.
    address existingAuditorRegistry;
    /// @dev The report registry the live watchdog already writes to, or zero to deploy a new one.
    address existingReportRegistry;
    /// @dev The audit hub that registry is bound to, or zero to deploy a new one.
    address existingAuditHub;
    uint64 tge;
    uint64 unlock6m;
    uint64 unlock12m;
    uint8 auditorThreshold;
    uint256 auditorCount;
}

/// @notice Everything the deployment produced, so the report can be assembled from one struct.
struct Deployment {
    address timelock;
    address genesis;
    address token;
    address teamVesting;
    address liquidityLock;
    address auditorRegistry;
    address pricing;
    address accessVault;
    address reportRegistry;
    address auditHub;
}

/// @title Deploy
/// @notice Deploys the whole KAY9 protocol and hands every administrative role to a 48-hour
///         TimelockController whose proposer and executor is the project owner Safe.
/// @dev A bare `forge script` run only simulates; transactions are sent only when forge is invoked
///      with --broadcast. The script also refuses to run against Robinhood Chain mainnet unless the
///      operator has explicitly confirmed with an environment variable.
///      Nothing about the project identity is hard-coded; every address comes from the environment
///      and is checked against the deployer key so a forgotten variable cannot silently make the
///      deployer the owner.
contract Deploy is Script {
    /// @notice The minimum governance delay, matching the published admin surface.
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    /// @notice The deep audit target, ten US dollars scaled by 1e8.
    /// @notice The USD value of KAY9 a deep access lock must hold, scaled by 1e8.
    uint256 internal constant DEEP_ACCESS_USD_E8 = 100e8;

    /// @notice The USD value of KAY9 a forensic access lock must hold, scaled by 1e8.
    uint256 internal constant FORENSIC_ACCESS_USD_E8 = 500e8;

    /// @notice Thrown when the mainnet confirmation is missing.
    error MainnetNotConfirmed();

    /// @notice Thrown when a required address equals the deployer, which is almost always a mistake.
    /// @param what The name of the offending variable.
    error MustNotBeDeployer(string what);

    /// @notice Thrown when a required address is the zero address.
    /// @param what The name of the offending variable.
    error MissingAddress(string what);

    /// @notice Thrown when the vesting schedule is not strictly increasing.
    error BadSchedule();

    /// @notice Thrown when a supplied existing address holds no code on this chain.
    /// @param what The name of the offending variable.
    error NotDeployed(string what);

    /// @notice Thrown when a supplied existing auditor registry is not the one this launch expects.
    /// @param what Which part disagreed: threshold, count, member or owner.
    error AuditorSetMismatch(string what);

    /// @notice Thrown when a supplied existing registry and hub do not belong to each other.
    /// @param what Which part disagreed.
    error AuditProtocolMismatch(string what);

    /// @notice Runs the deployment.
    /// @return d The deployed addresses.
    function run() external returns (Deployment memory d) {
        ChainAddresses memory book = RobinhoodAddresses.forChain(block.chainid);

        address deployer = msg.sender;
        address[] memory auditors = vm.envAddress("AUDITORS", ",");
        DeployConfig memory cfg = _config(book, deployer, auditors);

        if (block.chainid == RobinhoodAddresses.MAINNET_CHAIN_ID) {
            if (keccak256(bytes(vm.envOr("MAINNET_CONFIRM", string("")))) != keccak256("I_AM_THE_OWNER")) {
                revert MainnetNotConfirmed();
            }
        }

        // vm.startBroadcast only records the transactions. Nothing is sent unless forge is invoked
        // with --broadcast, so a bare `forge script` run is always a simulation.
        vm.startBroadcast();

        // The watchdog goes live before the token, so by the time this script runs there is
        // normally already a timelock and an auditor registry governing a scan history. Reuse them.
        // Deploying a second auditor registry here would leave every basic scan committed before
        // the launch answering to a set of auditors that no longer governs anything, and would give
        // the project two timelocks with different addresses and the same claimed authority.
        TimelockController timelock = cfg.existingTimelock != address(0)
            ? TimelockController(payable(cfg.existingTimelock))
            : _newTimelock(cfg.ownerSafe);

        KAY9Genesis genesis = new KAY9Genesis(
            cfg.ownerSafe,
            cfg.teamBeneficiary,
            cfg.tge,
            cfg.unlock6m,
            cfg.unlock12m,
            cfg.creatorFeeRecipient,
            book.liquidityLauncher,
            book.lbpStrategy,
            book.positionManager,
            book.poolManager,
            book.permit2,
            book.feeSplitter,
            book.beneficiaryVault,
            cfg.initializerHook
        );

        KAY9AuditorRegistry auditorRegistry = cfg.existingAuditorRegistry != address(0)
            ? KAY9AuditorRegistry(cfg.existingAuditorRegistry)
            : new KAY9AuditorRegistry(address(timelock), auditors, cfg.auditorThreshold);
        KAY9Pricing pricing = new KAY9Pricing(
            address(timelock),
            IPoolManager(book.poolManager),
            address(genesis.token()),
            AggregatorV3Interface(cfg.ethUsdFeed),
            DEEP_ACCESS_USD_E8,
            FORENSIC_ACCESS_USD_E8
        );

        // The vault is deployed before the hub because the hub takes its address at construction.
        // It is owned by the deployer only long enough to point it at the hub, then handed over.
        KAY9AccessVault accessVault = new KAY9AccessVault(deployer, IERC20(address(genesis.token())), pricing);

        // The audit protocol is normally already live: the watchdog deploys the registry and the
        // hub before the token exists, and `KAY9Registry` binds to its hub immutably, so there is
        // no second chance to move it. Deploying a fresh pair here would strand every report the
        // watchdog had already committed.
        KAY9Registry reportRegistry;
        KAY9AuditHub auditHub;
        if (cfg.existingAuditHub != address(0)) {
            reportRegistry = KAY9Registry(cfg.existingReportRegistry);
            auditHub = KAY9AuditHub(cfg.existingAuditHub);
        } else {
            // The registry and the hub reference each other, so the hub address is predicted from
            // the broadcasting key's nonce and verified immediately after both are on-chain.
            address predictedHub = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
            reportRegistry = new KAY9Registry(predictedHub);
            auditHub = new KAY9AuditHub(
                address(timelock), address(reportRegistry), auditorRegistry, KAY9AccessVault(address(0))
            );
            require(address(auditHub) == predictedHub, "hub address prediction failed");
        }

        accessVault.setAuditHub(address(auditHub));
        accessVault.transferOwnership(address(timelock));

        vm.stopBroadcast();

        d = Deployment({
            timelock: address(timelock),
            genesis: address(genesis),
            token: address(genesis.token()),
            teamVesting: address(genesis.teamVesting()),
            liquidityLock: address(genesis.liquidityLock()),
            auditorRegistry: address(auditorRegistry),
            pricing: address(pricing),
            accessVault: address(accessVault),
            reportRegistry: address(reportRegistry),
            auditHub: address(auditHub)
        });

        _report(d, book, cfg);
    }

    /// @notice Reads and validates every project-specific setting from the environment.
    /// @param book The canonical address book for this chain.
    /// @param deployer The deploying key, which none of the project addresses may equal.
    /// @param auditors The auditors supplied, which an existing registry is checked against.
    /// @return cfg The validated configuration.
    function _config(ChainAddresses memory book, address deployer, address[] memory auditors)
        internal
        view
        returns (DeployConfig memory cfg)
    {
        uint256 auditorCount = auditors.length;
        cfg.ownerSafe = _requiredAddress("OWNER_SAFE", deployer);
        cfg.teamBeneficiary = _requiredAddress("TEAM_BENEFICIARY", deployer);
        cfg.creatorFeeRecipient = _requiredAddress("CREATOR_FEE_RECIPIENT", deployer);

        cfg.tge = uint64(vm.envUint("TGE_TIMESTAMP"));
        cfg.unlock6m = uint64(vm.envUint("UNLOCK_6M_TIMESTAMP"));
        cfg.unlock12m = uint64(vm.envUint("UNLOCK_12M_TIMESTAMP"));
        if (!(cfg.tge < cfg.unlock6m && cfg.unlock6m < cfg.unlock12m)) revert BadSchedule();

        cfg.auditorThreshold = uint8(vm.envUint("AUDITOR_THRESHOLD"));
        cfg.auditorCount = auditorCount;

        // The watchdog is expected to be live already, with its own timelock and auditor set. Both
        // are optional so a from-scratch deployment and a test still work, but if one is supplied
        // it is checked against the chain rather than trusted, because a wrong address here would
        // silently point the token at governance nobody holds.
        cfg.existingTimelock = vm.envOr("EXISTING_TIMELOCK", address(0));
        cfg.existingAuditorRegistry = vm.envOr("EXISTING_AUDITOR_REGISTRY", address(0));
        cfg.existingReportRegistry = vm.envOr("EXISTING_REPORT_REGISTRY", address(0));
        cfg.existingAuditHub = vm.envOr("EXISTING_AUDIT_HUB", address(0));
        _validateExistingWatchdog(cfg.existingTimelock, cfg.existingAuditorRegistry, cfg.auditorThreshold, auditors);
        _validateExistingAuditProtocol(cfg.existingReportRegistry, cfg.existingAuditHub);

        cfg.ethUsdFeed = vm.envOr("ETH_USD_FEED", book.ethUsdFeed);
        if (cfg.ethUsdFeed == address(0)) revert MissingAddress("ETH_USD_FEED");

        // The official pool is keyed on Uniswap's canonical InitializerHook, whose authorized
        // initializer is the LBP strategy. KAY9Genesis re-validates it in its constructor.
        cfg.initializerHook = vm.envOr("INITIALIZER_HOOK", book.initializerHook);
        if (cfg.initializerHook == address(0)) revert MissingAddress("INITIALIZER_HOOK");
    }

    /// @notice Checks that a supplied live watchdog really is the one this launch expects.
    /// @dev Called with whatever `EXISTING_TIMELOCK` and `EXISTING_AUDITOR_REGISTRY` hold, but takes
    ///      them as arguments rather than reading the environment itself, so the checks can be
    ///      exercised directly. Both addresses are optional; a zero means "deploy a new one".
    ///      Nothing here is trusted on the operator's word: a wrong address would point the token at
    ///      governance nobody holds, and would be invisible until somebody needed to use it.
    /// @param timelock The timelock the watchdog answers to, or zero.
    /// @param auditorRegistry The auditor registry the watchdog uses, or zero.
    /// @param threshold The quorum this launch expects.
    /// @param auditors The auditors this launch expects.
    function _validateExistingWatchdog(
        address timelock,
        address auditorRegistry,
        uint8 threshold,
        address[] memory auditors
    ) internal view {
        if (timelock != address(0) && timelock.code.length == 0) {
            revert NotDeployed("EXISTING_TIMELOCK");
        }
        if (auditorRegistry == address(0)) return;
        if (auditorRegistry.code.length == 0) revert NotDeployed("EXISTING_AUDITOR_REGISTRY");

        // The registry must be the one this launch believes in: same quorum, same members, and
        // governed by the timelock this launch is about to hand everything else to.
        KAY9AuditorRegistry existing = KAY9AuditorRegistry(auditorRegistry);
        if (existing.threshold() != threshold) revert AuditorSetMismatch("threshold");
        if (existing.auditorCount() != auditors.length) revert AuditorSetMismatch("count");
        for (uint256 i = 0; i < auditors.length; ++i) {
            if (!existing.isAuditor(auditors[i])) revert AuditorSetMismatch("member");
        }
        if (timelock != address(0) && existing.owner() != timelock) revert AuditorSetMismatch("owner");
    }

    /// @notice Checks that a supplied live audit protocol is internally consistent.
    /// @dev Both addresses travel together: a registry is bound to exactly one hub, immutably, and
    ///      pointing the launch at a mismatched pair would produce a vault wired to a hub that
    ///      cannot write to the registry anybody is reading.
    /// @param reportRegistry The registry the watchdog already writes to, or zero.
    /// @param auditHub The hub it is bound to, or zero.
    function _validateExistingAuditProtocol(address reportRegistry, address auditHub) internal view {
        if (reportRegistry == address(0) && auditHub == address(0)) return;
        if (reportRegistry == address(0)) revert MissingAddress("EXISTING_REPORT_REGISTRY");
        if (auditHub == address(0)) revert MissingAddress("EXISTING_AUDIT_HUB");
        if (reportRegistry.code.length == 0) revert NotDeployed("EXISTING_REPORT_REGISTRY");
        if (auditHub.code.length == 0) revert NotDeployed("EXISTING_AUDIT_HUB");
        if (KAY9Registry(reportRegistry).auditHub() != auditHub) revert AuditProtocolMismatch("hub");
        // A hub that already has a vault has already launched once. Binding a second vault is
        // refused by the hub itself, so catching it here saves a broadcast that would revert.
        if (address(KAY9AuditHub(auditHub).accessVault()) != address(0)) {
            revert AuditProtocolMismatch("vault already set");
        }
    }

    /// @notice Deploys a fresh timelock whose sole proposer and executor is the owner Safe.
    /// @dev Only reached when no live watchdog timelock was supplied, which in production means a
    ///      first deployment or a test. Kept as its own function so the reuse branch above reads as
    ///      one expression.
    /// @param ownerSafe The owner Safe.
    /// @return The new timelock.
    function _newTimelock(address ownerSafe) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = ownerSafe;
        address[] memory executors = new address[](1);
        executors[0] = ownerSafe;
        return new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));
    }

    /// @notice Reads a required address from the environment and refuses the deployer.
    /// @param name The environment variable name.
    /// @param deployer The deployer address.
    /// @return value The address.
    function _requiredAddress(string memory name, address deployer) internal view returns (address value) {
        value = vm.envAddress(name);
        if (value == address(0)) revert MissingAddress(name);
        if (value == deployer) revert MustNotBeDeployer(name);
    }

    /// @notice Prints every address, role and bytecode hash the launch report needs.
    /// @param d The deployment.
    /// @param book The canonical address book used.
    /// @param cfg The validated configuration.
    function _report(Deployment memory d, ChainAddresses memory book, DeployConfig memory cfg) internal view {
        console2.log("=== KAY9 deployment ===");
        console2.log("chainId                ", block.chainid);
        console2.log("TimelockController     ", d.timelock);
        console2.log("KAY9Genesis            ", d.genesis);
        console2.log("KAY9Token              ", d.token);
        console2.log("KAY9TeamVesting        ", d.teamVesting);
        console2.log("KAY9LiquidityLock      ", d.liquidityLock);
        console2.log("KAY9AuditorRegistry    ", d.auditorRegistry);
        console2.log("KAY9Pricing            ", d.pricing);
        console2.log("KAY9AccessVault        ", d.accessVault);
        console2.log("KAY9Registry           ", d.reportRegistry);
        console2.log("KAY9AuditHub           ", d.auditHub);

        console2.log("=== roles ===");
        console2.log("owner Safe             ", cfg.ownerSafe);
        console2.log("team beneficiary       ", cfg.teamBeneficiary);
        console2.log("creator fee recipient  ", cfg.creatorFeeRecipient);
        console2.log("auditors               ", cfg.auditorCount);
        console2.log("quorum threshold       ", cfg.auditorThreshold);
        console2.log("timelock delay seconds ", TIMELOCK_DELAY);
        console2.log("");
        console2.log("=== ACTION REQUIRED, the deployment is not finished ===");
        console2.log("KAY9AccessVault ownership is PROPOSED to the timelock, not held by it.");
        console2.log("Ownable2Step needs the new owner to accept, so until the timelock");
        console2.log("executes acceptOwnership() the deploying key still owns the vault.");
        console2.log("Queue and execute it before announcing anything:");
        console2.log("  target ", d.accessVault);
        console2.log("  data   ", "acceptOwnership()");
        console2.log("Verify with: accessVault.owner() == the timelock address above.");
        console2.log("");
        console2.log("The audit hub has no access vault until governance binds it. Until then");
        console2.log("requestAudit reverts AccessVaultNotSet and nobody can spend quota. Queue:");
        console2.log("  target ", d.auditHub);
        console2.log("  data   ", "setAccessVault(address)");
        console2.log("  arg    ", d.accessVault);
        console2.log("It can be called once and never again, so check the address before signing.");

        console2.log("=== canonical dependencies ===");
        console2.log("PoolManager            ", book.poolManager);
        console2.log("PositionManager        ", book.positionManager);
        console2.log("Permit2                ", book.permit2);
        console2.log("LiquidityLauncher      ", book.liquidityLauncher);
        console2.log("LBPStrategy            ", book.lbpStrategy);
        console2.log("CCA factory            ", book.auctionFactory);
        console2.log("FeeSplitter            ", book.feeSplitter);
        console2.log("BeneficiaryVault       ", book.beneficiaryVault);
        console2.log("InitializerHook        ", cfg.initializerHook);
        console2.log("ETH/USD feed           ", cfg.ethUsdFeed);

        console2.log("=== bytecode hashes ===");
        console2.log("KAY9Token              ", vm.toString(d.token.codehash));
        console2.log("KAY9TeamVesting        ", vm.toString(d.teamVesting.codehash));
        console2.log("KAY9Genesis            ", vm.toString(d.genesis.codehash));
        console2.log("KAY9LiquidityLock      ", vm.toString(d.liquidityLock.codehash));
        console2.log("KAY9AuditorRegistry    ", vm.toString(d.auditorRegistry.codehash));
        console2.log("KAY9Pricing            ", vm.toString(d.pricing.codehash));
        console2.log("KAY9Registry           ", vm.toString(d.reportRegistry.codehash));
        console2.log("KAY9AuditHub           ", vm.toString(d.auditHub.codehash));
        console2.log("TimelockController     ", vm.toString(d.timelock.codehash));
    }
}
