// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployWatchdog, WatchdogConfig, WatchdogDeployment} from "../../script/DeployWatchdog.s.sol";
import {Deploy, DeployConfig} from "../../script/Deploy.s.sol";
import {ChainAddresses, RobinhoodAddresses} from "../../script/config/RobinhoodAddresses.sol";
import {KAY9AuditHub} from "../../src/KAY9AuditHub.sol";
import {KAY9AuditorRegistry} from "../../src/KAY9AuditorRegistry.sol";
import {KAY9Registry} from "../../src/KAY9Registry.sol";
import {KAY9ScanRegistry} from "../../src/KAY9ScanRegistry.sol";

/// @notice Exposes the watchdog script's guards and its deployment step, so both can be exercised
///         with explicit arguments instead of through process-wide environment variables.
contract WatchdogHarness is DeployWatchdog {
    function validate(WatchdogConfig memory cfg, address deployer) external pure {
        _validate(cfg, deployer);
    }

    function mainnetConfirmed(string memory confirmation) external pure returns (bool) {
        return _mainnetConfirmed(confirmation);
    }

    function deploy(WatchdogConfig memory cfg, address deployer) external returns (WatchdogDeployment memory) {
        return _deploy(cfg, deployer);
    }
}

/// @notice Exposes `Deploy`'s internal configuration reader, which is where the launch decides
///         whether to reuse the live watchdog's governance or quietly stand up a second one.
contract DeployHarness is Deploy {
    function config(ChainAddresses memory book, address deployer, address[] memory auditors)
        external
        view
        returns (DeployConfig memory)
    {
        return _config(book, deployer, auditors);
    }

    function validateExistingAuditProtocol(address reportRegistry, address auditHub) external view {
        _validateExistingAuditProtocol(reportRegistry, auditHub);
    }

    function validateExistingWatchdog(
        address timelock,
        address auditorRegistry,
        uint8 threshold,
        address[] memory auditors
    ) external view {
        _validateExistingWatchdog(timelock, auditorRegistry, threshold, auditors);
    }
}

/// @title DeployWatchdogTest
/// @notice Covers the deployment that goes live before the token exists.
/// @dev The point of this script is an ordering guarantee: the watchdog can run on mainnet with no
///      token, no oracle and no access vault, and the later token launch must attach to the
///      governance it already answers to rather than replacing it. Both halves are tested here,
///      because getting the second one wrong would orphan every scan committed before the launch
///      and nothing about that failure is visible at the time it happens.
contract DeployWatchdogTest is Test {
    address internal ownerSafe = address(0x5AFE);
    address internal auditorA = address(0xA1);
    address internal auditorB = address(0xA2);
    address internal auditorC = address(0xA3);
    address internal scannerKey = address(0x5CA1);

    /// @notice The settings a normal deployment is given.
    /// @param withScanner Whether to authorise a dedicated scanner key.
    /// @return cfg The settings.
    function _config(bool withScanner) internal view returns (WatchdogConfig memory cfg) {
        cfg.ownerSafe = ownerSafe;
        cfg.auditors = _auditorList();
        cfg.threshold = 2;
        cfg.scanners = new address[](withScanner ? 1 : 0);
        if (withScanner) cfg.scanners[0] = scannerKey;
    }

    /// @notice Deploys the watchdog stack the way `forge script` would.
    /// @dev `_deploy` is given the deploying key, which under a broadcast is the default sender.
    ///      Passing anything else would leave the script owning contracts it cannot then configure,
    ///      a failure that can only happen in a test and never in production.
    /// @param cfg The settings.
    /// @return d The deployment.
    function _deployWatchdog(WatchdogConfig memory cfg) internal returns (WatchdogDeployment memory d) {
        return new WatchdogHarness().deploy(cfg, DEFAULT_SENDER);
    }

    /// @notice Deploys with the ordinary settings.
    /// @return d The deployment.
    function _deployWatchdog() internal returns (WatchdogDeployment memory d) {
        return _deployWatchdog(_config(true));
    }

    /// @notice The watchdog stack deploys, is wired together, and contains no token.
    function test_deploysAWatchdogWithNoToken() public {
        WatchdogDeployment memory d = _deployWatchdog();

        KAY9AuditorRegistry registry = KAY9AuditorRegistry(d.auditorRegistry);
        KAY9ScanRegistry scans = KAY9ScanRegistry(d.scanRegistry);

        assertEq(registry.owner(), d.timelock, "the auditor set answers to the timelock immediately");
        assertEq(registry.auditorCount(), 3);
        assertEq(registry.threshold(), 2);

        assertEq(address(scans.auditors()), d.auditorRegistry, "the scan registry knows the auditor set");
        assertTrue(scans.isScanner(scannerKey), "the supplied scanner may commit");
        assertFalse(scans.isScanner(ownerSafe), "and nobody else was authorised by accident");

        // Ownable2Step: the handover is proposed, not complete, and the script says so loudly.
        assertEq(scans.pendingOwner(), d.timelock, "ownership is proposed to the timelock");
        assertTrue(scans.owner() != d.timelock, "and not yet held by it, which the report warns about");
    }

    /// @notice A scanner is optional, because the auditors can always commit.
    function test_scannersAreOptional() public {
        WatchdogDeployment memory d = _deployWatchdog(_config(false));
        KAY9ScanRegistry scans = KAY9ScanRegistry(d.scanRegistry);
        assertFalse(scans.isScanner(scannerKey));
        assertTrue(KAY9AuditorRegistry(d.auditorRegistry).isAuditor(auditorA), "an auditor can still commit");
    }

    /// @notice The owner Safe may not be the deploying key.
    function test_refusesTheDeployerAsOwner() public {
        WatchdogHarness harness = new WatchdogHarness();
        WatchdogConfig memory cfg = _config(true);
        cfg.ownerSafe = DEFAULT_SENDER;
        vm.expectRevert(abi.encodeWithSelector(DeployWatchdog.MustNotBeDeployer.selector, "OWNER_SAFE"));
        harness.validate(cfg, DEFAULT_SENDER);
    }

    /// @notice A missing owner Safe is refused rather than defaulting to anybody.
    function test_refusesAnEmptyOwner() public {
        WatchdogHarness harness = new WatchdogHarness();
        WatchdogConfig memory cfg = _config(true);
        cfg.ownerSafe = address(0);
        vm.expectRevert(abi.encodeWithSelector(DeployWatchdog.MissingAddress.selector, "OWNER_SAFE"));
        harness.validate(cfg, DEFAULT_SENDER);
    }

    /// @notice A quorum nobody could ever reach is refused at deployment, not discovered later.
    function test_refusesAnUnreachableQuorum() public {
        WatchdogHarness harness = new WatchdogHarness();
        WatchdogConfig memory cfg = _config(true);
        cfg.threshold = 4; // there are three auditors
        vm.expectRevert(DeployWatchdog.BadThreshold.selector);
        harness.validate(cfg, DEFAULT_SENDER);

        cfg.threshold = 0;
        vm.expectRevert(DeployWatchdog.BadThreshold.selector);
        harness.validate(cfg, DEFAULT_SENDER);
    }

    /// @notice An empty auditor set is refused.
    function test_refusesAnEmptyAuditorSet() public {
        WatchdogHarness harness = new WatchdogHarness();
        WatchdogConfig memory cfg = _config(true);
        cfg.auditors = new address[](0);
        vm.expectRevert(DeployWatchdog.NoAuditors.selector);
        harness.validate(cfg, DEFAULT_SENDER);
    }

    /// @notice Mainnet needs one exact confirmation phrase from the owner, on this script too.
    /// @dev The watchdog launching early is the whole plan, so this is the script most likely to be
    ///      run against mainnet in a hurry. It carries the same gate as the token deployment, and
    ///      the gate is an exact string match rather than a truthiness check, so "yes" does not pass.
    function test_mainnetNeedsExplicitConfirmation() public {
        WatchdogHarness harness = new WatchdogHarness();
        assertTrue(harness.mainnetConfirmed("I_AM_THE_OWNER"), "the documented phrase passes");
        assertFalse(harness.mainnetConfirmed(""), "an unset variable does not");
        assertFalse(harness.mainnetConfirmed("yes"), "and neither does anything else");
        assertFalse(harness.mainnetConfirmed("i_am_the_owner"), "including the wrong case");
        assertFalse(harness.mainnetConfirmed("I_AM_THE_OWNER "), "or a trailing space");
    }

    /// @notice The mainnet gate is wired into `run()`, not merely available.
    /// @dev The only test here that writes environment variables. It sets MAINNET_CONFIRM to the
    ///      empty string, which is what every other test wants it to be anyway, and the rest to the
    ///      same values every time, so running these concurrently cannot make it flaky.
    function test_runRefusesMainnetWithoutConfirmation() public {
        _setWatchdogEnv();
        vm.setEnv("MAINNET_CONFIRM", "");
        vm.chainId(RobinhoodAddresses.MAINNET_CHAIN_ID);
        DeployWatchdog script = new DeployWatchdog();
        vm.expectRevert(DeployWatchdog.MainnetNotConfirmed.selector);
        vm.prank(DEFAULT_SENDER);
        script.run();
    }

    // ---------------------------------------------------------------------------------------
    // The token launch attaching to the watchdog that is already live
    // ---------------------------------------------------------------------------------------

    /// @notice Sets the variables both scripts read, to the same values from every test.
    /// @dev `forge` runs the cases in a suite concurrently and environment variables are process
    ///      wide, so two tests writing the same name with different values race. Every test that
    ///      needs these writes them through here, and the guards that would otherwise want a
    ///      different value are tested by calling the check directly instead.
    function _setWatchdogEnv() internal {
        vm.setEnv("OWNER_SAFE", vm.toString(ownerSafe));
        vm.setEnv(
            "AUDITORS", string.concat(vm.toString(auditorA), ",", vm.toString(auditorB), ",", vm.toString(auditorC))
        );
        vm.setEnv("AUDITOR_THRESHOLD", "2");
    }

    /// @notice Sets the extra variables the token launch needs but the watchdog does not.
    function _setLaunchEnv() internal {
        vm.setEnv("TEAM_BENEFICIARY", vm.toString(address(0xBEEF)));
        vm.setEnv("CREATOR_FEE_RECIPIENT", vm.toString(address(0xFEE5)));
        vm.setEnv("TGE_TIMESTAMP", "1800000000");
        // 2027-01-15 08:00 UTC, then exactly six and twelve calendar months later.
        vm.setEnv("UNLOCK_6M_TIMESTAMP", "1815638400");
        vm.setEnv("UNLOCK_12M_TIMESTAMP", "1831536000");
        vm.setEnv("ETH_USD_FEED", vm.toString(address(0xFEED)));
        vm.setEnv("INITIALIZER_HOOK", vm.toString(address(0x400C)));
    }

    function _auditorList() internal view returns (address[] memory list) {
        list = new address[](3);
        list[0] = auditorA;
        list[1] = auditorB;
        list[2] = auditorC;
    }

    /// @notice The launch reads the live watchdog's addresses out of the environment and keeps them.
    /// @dev The only test that exercises `Deploy._config` end to end. Everything it asserts about
    ///      the *checks* lives in the tests below, which pass their arguments directly.
    function test_launchReadsTheLiveWatchdogFromTheEnvironment() public {
        WatchdogDeployment memory w = _deployWatchdog();

        _setWatchdogEnv();
        _setLaunchEnv();
        vm.setEnv("EXISTING_TIMELOCK", vm.toString(w.timelock));
        vm.setEnv("EXISTING_AUDITOR_REGISTRY", vm.toString(w.auditorRegistry));

        DeployConfig memory cfg =
            new DeployHarness().config(RobinhoodAddresses.testnet(), address(0xD3), _auditorList());

        assertEq(cfg.existingTimelock, w.timelock, "the launch attaches to the live timelock");
        assertEq(cfg.existingAuditorRegistry, w.auditorRegistry, "and to the live auditor set");
    }

    /// @notice The watchdog deployment brings up the audit protocol too, with no vault.
    /// @dev `KAY9Registry` binds to its hub immutably, so the hub has to be the final one from the
    ///      first deployment. Bringing both up now is what lets a quorum publish deep and forensic
    ///      reports months before anybody is asked to lock KAY9 for one.
    function test_theWatchdogBringsUpTheAuditProtocolWithNoVault() public {
        WatchdogDeployment memory d = _deployWatchdog();
        assertTrue(d.reportRegistry != address(0), "the report registry is deployed");
        assertEq(KAY9Registry(d.reportRegistry).auditHub(), d.auditHub, "and bound to the hub, immutably");
        assertEq(
            address(KAY9AuditHub(d.auditHub).accessVault()),
            address(0),
            "with no access vault, because there is no token yet"
        );
        new DeployHarness().validateExistingAuditProtocol(d.reportRegistry, d.auditHub);
    }

    /// @notice A registry and hub that do not belong to each other are refused.
    function test_launchRefusesAMismatchedRegistryAndHub() public {
        WatchdogDeployment memory a = _deployWatchdog();
        WatchdogDeployment memory b = _deployWatchdog();
        DeployHarness harness = new DeployHarness();
        vm.expectRevert(abi.encodeWithSelector(Deploy.AuditProtocolMismatch.selector, "hub"));
        harness.validateExistingAuditProtocol(a.reportRegistry, b.auditHub);
    }

    /// @notice Half a pair is refused, because the two only mean anything together.
    function test_launchRefusesHalfAnAuditProtocol() public {
        WatchdogDeployment memory d = _deployWatchdog();
        DeployHarness harness = new DeployHarness();
        vm.expectRevert(abi.encodeWithSelector(Deploy.MissingAddress.selector, "EXISTING_AUDIT_HUB"));
        harness.validateExistingAuditProtocol(d.reportRegistry, address(0));
    }

    /// @notice A registry with a different quorum is refused rather than silently adopted.
    /// @dev These four call the validation directly rather than through the environment. Every one
    ///      of them would otherwise have to write process-wide environment variables that the rest
    ///      of the suite also writes, and the checks being tested are exactly the ones that must not
    ///      depend on which test ran last.
    function test_launchRefusesAMismatchedThreshold() public {
        WatchdogDeployment memory w = _deployWatchdog();
        DeployHarness harness = new DeployHarness();
        address[] memory auditors = _auditorList();
        vm.expectRevert(abi.encodeWithSelector(Deploy.AuditorSetMismatch.selector, "threshold"));
        harness.validateExistingWatchdog(w.timelock, w.auditorRegistry, 3, auditors); // the live one says 2
    }

    /// @notice An auditor the live registry has never heard of is refused.
    function test_launchRefusesAnUnknownAuditor() public {
        WatchdogDeployment memory w = _deployWatchdog();
        DeployHarness harness = new DeployHarness();
        address[] memory auditors = _auditorList();
        auditors[2] = address(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(Deploy.AuditorSetMismatch.selector, "member"));
        harness.validateExistingWatchdog(w.timelock, w.auditorRegistry, 2, auditors);
    }

    /// @notice A registry governed by some other timelock is refused.
    function test_launchRefusesAForeignTimelock() public {
        WatchdogDeployment memory w = _deployWatchdog();
        WatchdogDeployment memory other = _deployWatchdog();
        DeployHarness harness = new DeployHarness();
        address[] memory auditors = _auditorList();
        vm.expectRevert(abi.encodeWithSelector(Deploy.AuditorSetMismatch.selector, "owner"));
        harness.validateExistingWatchdog(other.timelock, w.auditorRegistry, 2, auditors);
    }

    /// @notice An address with no code is refused, which is what a typo looks like.
    function test_launchRefusesAnAddressWithNoCode() public {
        DeployHarness harness = new DeployHarness();
        address[] memory auditors = _auditorList();
        vm.expectRevert(abi.encodeWithSelector(Deploy.NotDeployed.selector, "EXISTING_TIMELOCK"));
        harness.validateExistingWatchdog(address(0xC0FFEE), address(0), 2, auditors);
    }

    /// @notice With neither address supplied the launch still stands alone, so a first deployment works.
    function test_launchStillWorksWithNoLiveWatchdog() public {
        DeployHarness harness = new DeployHarness();
        harness.validateExistingWatchdog(address(0), address(0), 2, _auditorList());
    }

    /// @notice The live watchdog's own stack passes validation, which is the case that matters.
    function test_theLiveWatchdogPassesValidation() public {
        WatchdogDeployment memory w = _deployWatchdog();
        new DeployHarness().validateExistingWatchdog(w.timelock, w.auditorRegistry, 2, _auditorList());
    }
}
