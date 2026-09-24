// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {KAY9AccessVault} from "../src/KAY9AccessVault.sol";
import {KAY9AuditHub} from "../src/KAY9AuditHub.sol";
import {KAY9AuditorRegistry} from "../src/KAY9AuditorRegistry.sol";
import {KAY9Registry} from "../src/KAY9Registry.sol";
import {KAY9ScanRegistry} from "../src/KAY9ScanRegistry.sol";
import {RobinhoodAddresses} from "./config/RobinhoodAddresses.sol";

/// @notice The settings the watchdog deployment was given.
struct WatchdogConfig {
    address ownerSafe;
    address[] auditors;
    address[] scanners;
    uint8 threshold;
}

/// @notice Everything the watchdog deployment produced.
struct WatchdogDeployment {
    address timelock;
    address auditorRegistry;
    address scanRegistry;
    address reportRegistry;
    address auditHub;
}

/// @title DeployWatchdog
/// @notice Deploys the part of KAY9 that goes live **before** there is a token: the auditor set and
///         the permanent record of automatic basic scans.
///
/// @dev This script exists because of a deliberate ordering decision. The product is supposed to be
///      demonstrably useful before $KAY9 exists, which means the watchdog has to be able to run on
///      mainnet with no token, no pricing oracle, no access vault and no audit hub. `Deploy.s.sol`
///      cannot serve that purpose: it deploys the token, the vesting and the launch vault in the
///      same transaction batch, so running it early would mean launching the token early.
///
///      Nothing here can mint, price, sell or hold anything. The whole administrative surface is
///      "add or remove an auditor" and "authorise or de-authorise a scanner", and neither can alter
///      or remove a scan that has already been committed.
///
///      When the token does launch, `Deploy.s.sol` must be pointed at the timelock and auditor
///      registry this script produced — see `EXISTING_TIMELOCK` and `EXISTING_AUDITOR_REGISTRY`
///      there. Deploying a second auditor registry would leave the scan history answering to a set
///      of auditors that no longer governs anything.
/// @custom:security-contact security@kay9.io
contract DeployWatchdog is Script {
    /// @notice The minimum governance delay, matching the published admin surface.
    uint256 internal constant TIMELOCK_DELAY = 48 hours;

    /// @notice Thrown when the mainnet confirmation is missing.
    error MainnetNotConfirmed();

    /// @notice Thrown when a required address equals the deployer, which is almost always a mistake.
    /// @param what The name of the offending variable.
    error MustNotBeDeployer(string what);

    /// @notice Thrown when a required address is the zero address.
    /// @param what The name of the offending variable.
    error MissingAddress(string what);

    /// @notice Thrown when no auditors were supplied.
    error NoAuditors();

    /// @notice Thrown when the quorum threshold is zero or larger than the auditor set.
    error BadThreshold();

    /// @notice Thrown when an environment integer does not fit the type it is stored in.
    /// @param what The name of the offending variable.
    error OutOfRange(string what);

    /// @notice Thrown when no scanner is configured; auditors are not scanners by default.
    error NoScanners();

    /// @notice Thrown when the script is run against a chain it does not deploy to.
    /// @param chainId The refused chain.
    error UnsupportedChain(uint256 chainId);

    /// @notice Runs the deployment.
    /// @dev Split into reading the environment, checking what it said, and deploying, so that each
    ///      part can be tested on its own. The checks in particular must not be reachable only
    ///      through process-wide environment variables: `forge` runs test cases concurrently, so a
    ///      test that writes `OWNER_SAFE` to prove a guard fires can change what a different test
    ///      reads, and a security gate tested that way is tested by coincidence.
    /// @return d The deployed addresses.
    function run() external returns (WatchdogDeployment memory d) {
        address deployer = msg.sender;
        if (!_supportedChain(block.chainid)) revert UnsupportedChain(block.chainid);
        WatchdogConfig memory cfg = _config();
        _validate(cfg, deployer);

        if (block.chainid == RobinhoodAddresses.MAINNET_CHAIN_ID) {
            if (!_mainnetConfirmed(vm.envOr("MAINNET_CONFIRM", string("")))) revert MainnetNotConfirmed();
        }

        d = _deploy(cfg, deployer);
        _report(d, cfg, deployer);
    }

    /// @notice Reads every setting from the environment.
    /// @return cfg The settings, unchecked.
    function _config() internal view returns (WatchdogConfig memory cfg) {
        cfg.ownerSafe = vm.envAddress("OWNER_SAFE");
        cfg.auditors = vm.envAddress("AUDITORS", ",");
        // Narrowed only after the bound is checked, exactly as Deploy.s.sol does it. A bare cast
        // wraps silently, so a threshold of 258 would arrive as 2 — a number nobody typed, which
        // `_validate` below would then happily accept because 2 is a plausible quorum.
        cfg.threshold = _toUint8(vm.envUint("AUDITOR_THRESHOLD"), "AUDITOR_THRESHOLD");
        // Required. Auditors are not scanners by default, so a deployment with no scanner would
        // go live with nobody able to commit a basic scan.
        cfg.scanners = vm.envOr("SCANNERS", ",", new address[](0));
    }

    /// @notice Refuses a configuration that would put the project in the deployer's hands.
    /// @param cfg The settings.
    /// @param deployer The deploying key.
    function _validate(WatchdogConfig memory cfg, address deployer) internal pure {
        if (cfg.ownerSafe == address(0)) revert MissingAddress("OWNER_SAFE");
        if (cfg.ownerSafe == deployer) revert MustNotBeDeployer("OWNER_SAFE");
        if (cfg.auditors.length == 0) revert NoAuditors();
        if (cfg.threshold == 0 || cfg.threshold > cfg.auditors.length) revert BadThreshold();
        if (cfg.scanners.length == 0) revert NoScanners();
        // The deploying key keeps no role anywhere: not owner, not auditor, not scanner.
        for (uint256 i = 0; i < cfg.auditors.length; ++i) {
            if (cfg.auditors[i] == deployer) revert MustNotBeDeployer("AUDITORS");
        }
        for (uint256 i = 0; i < cfg.scanners.length; ++i) {
            if (cfg.scanners[i] == deployer) revert MustNotBeDeployer("SCANNERS");
        }
    }

    /// @notice Whether this script may deploy to a chain.
    /// @dev Robinhood Chain mainnet and testnet, and a local chain for tests. Anywhere else the
    ///      stack would deploy without complaint, and `BlockNumberish` would fall back to the
    ///      host chain's `block.number`.
    /// @param chainId The chain id.
    /// @return True when supported.
    function _supportedChain(uint256 chainId) internal pure returns (bool) {
        return chainId == RobinhoodAddresses.MAINNET_CHAIN_ID || chainId == 46630 || chainId == 31337;
    }

    /// @notice Narrows to uint8, refusing a value that would wrap.
    /// @param value The value read from the environment.
    /// @param what The variable it came from, for the error.
    /// @return The same value.
    function _toUint8(uint256 value, string memory what) internal pure returns (uint8) {
        if (value > type(uint8).max) revert OutOfRange(what);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }

    /// @notice Whether the mainnet confirmation phrase is the exact one required.
    /// @param confirmation Whatever the operator supplied.
    /// @return True when it matches.
    function _mainnetConfirmed(string memory confirmation) internal pure returns (bool) {
        return keccak256(bytes(confirmation)) == keccak256("I_AM_THE_OWNER");
    }

    /// @notice Deploys the watchdog stack.
    /// @param cfg The validated settings.
    /// @param deployer The deploying key, which must also be the broadcasting key.
    /// @return d The deployed addresses.
    function _deploy(WatchdogConfig memory cfg, address deployer) internal returns (WatchdogDeployment memory d) {
        // vm.startBroadcast only records the transactions. Nothing is sent unless forge is invoked
        // with --broadcast, so a bare `forge script` run is always a simulation.
        vm.startBroadcast();

        address[] memory proposers = new address[](1);
        proposers[0] = cfg.ownerSafe;
        address[] memory executors = new address[](1);
        executors[0] = cfg.ownerSafe;
        TimelockController timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        KAY9AuditorRegistry auditorRegistry = new KAY9AuditorRegistry(address(timelock), cfg.auditors, cfg.threshold);

        // Owned by the timelock from its first block, with the scanners named in the constructor,
        // so the first scan can land at once and the deploying key never owns it. The owner is the
        // guardian: it can revoke a scanner without the 48-hour delay, and do nothing else.
        KAY9ScanRegistry scanRegistry = new KAY9ScanRegistry(address(timelock), cfg.ownerSafe, cfg.scanners);

        // The deep and forensic side of the protocol deploys now too, with no access vault.
        //
        // It has to be now. `KAY9Registry` binds to its hub immutably, so the hub that governs the
        // permanent report record must be the final one from the first deployment — there is no
        // migration later. The vault holds KAY9 and cannot exist before the token, so the hub takes
        // a zero vault and governance binds the real one at launch, once.
        //
        // What that buys is the thing this ordering is for: `publishWatchdogReport` needs no
        // request and consumes no quota, so a quorum can publish deep and forensic reports
        // from day one, months before anybody is asked to lock a single KAY9 for one.
        address predictedHub = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        KAY9Registry reportRegistry = new KAY9Registry(predictedHub);
        KAY9AuditHub auditHub =
            new KAY9AuditHub(address(timelock), address(reportRegistry), auditorRegistry, KAY9AccessVault(address(0)));
        require(address(auditHub) == predictedHub, "hub address prediction failed");

        vm.stopBroadcast();

        d = WatchdogDeployment({
            timelock: address(timelock),
            auditorRegistry: address(auditorRegistry),
            scanRegistry: address(scanRegistry),
            reportRegistry: address(reportRegistry),
            auditHub: address(auditHub)
        });
    }

    /// @notice Prints every address, role and bytecode hash the go-live record needs.
    /// @param d The deployment.
    /// @param cfg The settings it used.
    /// @param deployer The deploying key.
    function _report(WatchdogDeployment memory d, WatchdogConfig memory cfg, address deployer) internal view {
        address[] memory scanners = cfg.scanners;
        console2.log("=== KAY9 watchdog deployment (no token) ===");
        console2.log("chainId                ", block.chainid);
        console2.log("TimelockController     ", d.timelock);
        console2.log("KAY9AuditorRegistry    ", d.auditorRegistry);
        console2.log("KAY9ScanRegistry       ", d.scanRegistry);
        console2.log("KAY9Registry           ", d.reportRegistry);
        console2.log("KAY9AuditHub           ", d.auditHub, "(no access vault yet)");

        console2.log("=== roles ===");
        console2.log("owner Safe             ", cfg.ownerSafe);
        console2.log("auditors               ", cfg.auditors.length);
        console2.log("quorum threshold       ", cfg.threshold);
        console2.log("authorised scanners    ", scanners.length);
        for (uint256 i = 0; i < scanners.length; ++i) {
            console2.log("  scanner              ", scanners[i]);
        }
        console2.log("scanner guardian       ", cfg.ownerSafe);
        console2.log("deploying key          ", deployer, "(keeps no role)");
        console2.log("timelock delay seconds ", TIMELOCK_DELAY);

        console2.log("");
        console2.log("Every contract is owned by the timelock from deployment; nothing to accept.");

        console2.log("");
        console2.log("=== when the token launches ===");
        console2.log("Run Deploy.s.sol with these set, or the token launch will deploy a second");
        console2.log("auditor registry and orphan every scan committed until then:");
        console2.log("  EXISTING_TIMELOCK         ", d.timelock);
        console2.log("  EXISTING_AUDITOR_REGISTRY ", d.auditorRegistry);
        console2.log("  EXISTING_REPORT_REGISTRY  ", d.reportRegistry);
        console2.log("  EXISTING_AUDIT_HUB        ", d.auditHub);
        console2.log("The report registry is bound to that hub immutably. A launch that deploys a");
        console2.log("second pair strands every report committed before it.");

        console2.log("=== bytecode hashes ===");
        console2.log("KAY9AuditorRegistry    ", vm.toString(d.auditorRegistry.codehash));
        console2.log("KAY9ScanRegistry       ", vm.toString(d.scanRegistry.codehash));
        console2.log("KAY9Registry           ", vm.toString(d.reportRegistry.codehash));
        console2.log("KAY9AuditHub           ", vm.toString(d.auditHub.codehash));
        console2.log("TimelockController     ", vm.toString(d.timelock.codehash));
    }
}
