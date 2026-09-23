// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {KAY9Genesis, LaunchParams} from "../src/KAY9Genesis.sol";
import {KAY9AccessVault, Access} from "../src/KAY9AccessVault.sol";
import {KAY9AuditHub, Job, JobStatus} from "../src/KAY9AuditHub.sol";
import {KAY9AuditorRegistry} from "../src/KAY9AuditorRegistry.sol";
import {KAY9Registry, AuditResult} from "../src/KAY9Registry.sol";
import {KAY9LiquidityLock} from "../src/KAY9LiquidityLock.sol";
import {IContinuousClearingAuction} from "../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {Launch} from "./Launch.s.sol";

/// @title Rehearse
/// @notice The testnet rehearsal of `docs/DEPLOYMENT.md` §3 and §3.1, one stage per function, so
///         every step is a real broadcast on chain 46630 with a transaction hash in `broadcast/`.
/// @dev Run after `Testnet.s.sol` has deployed the stack. Every address and every throwaway key
///      comes from the environment; nothing here is a production value. The three auditor keys and
///      the depositor key are testnet-only keys generated for this rehearsal and never hold value.
///
///      Stages, in order:
///        launch           owner: KAY9Genesis.launch with parameters derived by Launch.s.sol
///        bid              depositor: three bids that carry the auction past graduation
///        graduate         anyone: checkpoint after the end block
///        migrate          anyone: LBPStrategy.migrate, then lock the LP NFT, then settle
///        govSchedule      owner: one timelock batch — accept vault ownership, shorten the
///                         period and the SLA to their minimums
///        govExecute       owner: execute that batch after the rehearsal delay
///        deployAuditStack deployer: a fresh vault, registry and hub against the existing token
///                         (the 2026-09-11 redenomination; the old stack stays where it is)
///        requirementSchedule / requirementExecute
///                         owner: setRequirement(TIER, KAY9) through the timelock
///        claim            depositor: claim the auction tokens
///        lockAccess       depositor: approve, lock a deep period at requirementOf(1)
///        request          depositor: one requestAudit
///        attestPair       auditor A: two agreeing signatures in one transaction
///        dispute          auditors A, B, C: three different results, one transaction each
///        expire           anyone: markExpired after the SLA
///        upgradeAccess    depositor: deep to forensic mid-period
///        renew / unlock   depositor: at or after expiresAt
contract Rehearse is Script {
    bytes32 internal constant CHAIN_KEY = keccak256("eip155:46630");

    // ----------------------------------------------------------------------------------------
    // Wiring, read once per stage from the environment.
    // ----------------------------------------------------------------------------------------

    function _genesis() internal view returns (KAY9Genesis) {
        return KAY9Genesis(payable(vm.envAddress("GENESIS")));
    }

    function _vault() internal view returns (KAY9AccessVault) {
        return KAY9AccessVault(vm.envAddress("VAULT"));
    }

    function _hub() internal view returns (KAY9AuditHub) {
        return KAY9AuditHub(vm.envAddress("HUB"));
    }

    function _registry() internal view returns (KAY9Registry) {
        return KAY9Registry(vm.envAddress("REGISTRY"));
    }

    function _timelock() internal view returns (TimelockController) {
        return TimelockController(payable(vm.envAddress("TIMELOCK")));
    }

    function _auction() internal view returns (IContinuousClearingAuction) {
        return IContinuousClearingAuction(_genesis().auction());
    }

    function _token() internal view returns (IERC20) {
        return IERC20(address(_genesis().token()));
    }

    function _ownerKey() internal view returns (uint256) {
        return vm.envUint("PRIVATE_KEY");
    }

    function _userKey() internal view returns (uint256) {
        return vm.envUint("PK_USER");
    }

    function _auditorKey(string memory which) internal view returns (uint256) {
        return vm.envUint(string.concat("PK_", which));
    }

    // ----------------------------------------------------------------------------------------
    // Launch
    // ----------------------------------------------------------------------------------------

    /// @notice Derives the launch parameters exactly as Launch.s.sol does and launches.
    function launch() external {
        KAY9Genesis genesis = _genesis();
        Launch deriver = new Launch();
        // The rehearsal has no Chainlink feed; the ETH/USD answer the launch parameters are
        // derived from comes from the environment, as a plain number scaled by 1e8.
        int256 answer = int256(vm.envUint("ETH_USD_E8"));
        LaunchParams memory p = deriver.derive(
            genesis,
            vm.envUint("FLOOR_FDV_USD"),
            vm.envUint("GRADUATION_FDV_USD"),
            vm.envUint("DURATION_HOURS"),
            vm.envUint("START_DELAY_MINUTES"),
            bytes32(vm.envOr("LAUNCH_SALT", uint256(1))),
            uint256(answer)
        );
        (address predicted, uint256 fdvWei, uint256 raiseWei) = genesis.previewLaunch(p);
        console2.log("predicted auction        ", predicted);
        console2.log("startBlock/endBlock      ", p.startBlock, p.endBlock);
        console2.log("claim/migration block    ", p.claimBlock, p.migrationBlock);
        console2.log("floor FDV wei            ", fdvWei);
        console2.log("required raise wei       ", raiseWei);

        vm.startBroadcast(_ownerKey());
        genesis.launch(p);
        vm.stopBroadcast();

        console2.log("auction                  ", genesis.auction());
        console2.log("launchState              ", genesis.launchState());
    }

    /// @notice Prints where the launch is, in the block number the contracts read.
    function status() external view {
        KAY9Genesis genesis = _genesis();
        LaunchParams memory p = genesis.launchParams();
        console2.log("block.number (contract)  ", block.number);
        console2.log("startBlock/endBlock      ", p.startBlock, p.endBlock);
        console2.log("migrationBlock           ", p.migrationBlock);
        console2.log("launchState              ", genesis.launchState());
        if (genesis.auction() != address(0)) {
            IContinuousClearingAuction auction = _auction();
            console2.log("clearingPrice            ", auction.clearingPrice());
            console2.log("currencyRaised           ", auction.currencyRaised());
            console2.log("requiredCurrencyRaised   ", uint256(p.requiredCurrencyRaised));
            console2.log("isGraduated              ", auction.isGraduated());
        }
    }

    /// @notice Bids from the depositor, each willing to pay four times the current clearing price
    ///         and each committing slightly more than the whole graduation threshold.
    /// @dev The margin is the fix for a real failure, not caution. On the 2026-09-21 rehearsal a
    ///      single bid of exactly `requiredCurrencyRaised` left `currencyRaised` at
    ///      1819999999999998 against a threshold of 1819999999999999 — one wei short — so the
    ///      auction ended un-graduated and the launch failed. What a bid contributes is credited
    ///      through the clearing price and the conversion rounds down, so a commitment of exactly
    ///      the threshold is not guaranteed to reach it, and this one did not. The default of three
    ///      bids had always hidden it by committing three times the requirement; `BID_COUNT=1` is
    ///      what exposed it. A launch that has failed
    ///      cannot be relaunched for `RELAUNCH_DELAY` (48 hours), so this off-by-one costs two days
    ///      of rehearsal time, which is why the margin is here rather than in the caller's head.
    function bid() external {
        IContinuousClearingAuction auction = _auction();
        LaunchParams memory p = _genesis().launchParams();
        uint256 threshold = uint256(p.requiredCurrencyRaised);
        uint256 withMargin = threshold + threshold / 1000 + 1;
        require(withMargin <= type(uint128).max, "bid: the margin does not fit the auction's uint128");
        uint128 each = uint128(withMargin);
        uint256 count = vm.envOr("BID_COUNT", uint256(3));
        address depositor = vm.addr(_userKey());

        vm.startBroadcast(_userKey());
        for (uint256 i = 0; i < count; ++i) {
            uint256 cleared = auction.clearingPrice();
            uint256 base = cleared > p.floorPriceQ96 ? cleared : p.floorPriceQ96;
            uint256 price = base * 4;
            price -= price % p.auctionTickSpacingQ96;
            uint256 bidId = auction.submitBid{value: each}(price, each, depositor, "");
            console2.log("bid id / price / amount  ", bidId, price, uint256(each));
        }
        vm.stopBroadcast();
        console2.log("currencyRaised           ", auction.currencyRaised());
    }

    /// @notice Checkpoints the auction after its end block and reports graduation.
    function graduate() external {
        vm.startBroadcast(_ownerKey());
        _auction().checkpoint();
        vm.stopBroadcast();
        console2.log("isGraduated              ", _auction().isGraduated());
        console2.log("launchState              ", _genesis().launchState());
    }

    /// @notice Migrates, locks the LP NFT and settles the leftover supply.
    function migrate() external {
        KAY9Genesis genesis = _genesis();
        IPositionManager positionManager = genesis.positionManager();
        KAY9LiquidityLock lock = genesis.liquidityLock();

        // The path the runbook and the site use: one transaction that migrates, locks the positions
        // the migration minted and settles.
        vm.startBroadcast(_ownerKey());
        genesis.migrateAndSettle();
        vm.stopBroadcast();
        uint256 tokenId = positionManager.nextTokenId() - 1;
        console2.log("last LP tokenId          ", tokenId);
        console2.log("migration position locked", lock.isLocked(tokenId));

        console2.log("launchState              ", genesis.launchState());
        console2.log("LP NFT owner             ", IERC721(address(positionManager)).ownerOf(tokenId));
        console2.log("settled                  ", genesis.settled());
        PoolKey memory key = genesis.poolKey();
        console2.log("pool hook                ", address(key.hooks));
    }

    // ----------------------------------------------------------------------------------------
    // Governance, through the timelock
    // ----------------------------------------------------------------------------------------

    function _governanceBatch()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](3);
        values = new uint256[](3);
        payloads = new bytes[](3);
        targets[0] = address(_vault());
        payloads[0] = abi.encodeWithSignature("acceptOwnership()");
        targets[1] = address(_vault());
        payloads[1] = abi.encodeCall(KAY9AccessVault.setLockDuration, (uint64(7 days)));
        targets[2] = address(_hub());
        payloads[2] = abi.encodeCall(KAY9AuditHub.setSla, (uint64(1 hours)));
    }

    /// @notice Schedules the governance batch.
    function govSchedule() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _governanceBatch();
        TimelockController timelock = _timelock();
        uint256 delay = timelock.getMinDelay();
        vm.startBroadcast(_ownerKey());
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), delay);
        vm.stopBroadcast();
        console2.log("scheduled, executable after", block.timestamp + delay);
        console2.log(
            "operation id             ",
            vm.toString(timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0)))
        );
    }

    /// @notice Executes the governance batch once the delay has elapsed.
    function govExecute() external {
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _governanceBatch();
        vm.startBroadcast(_ownerKey());
        _timelock().executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
        vm.stopBroadcast();
        console2.log("vault owner              ", _vault().owner());
        console2.log("lockDuration             ", _vault().lockDuration());
        console2.log("slaSeconds               ", _hub().slaSeconds());
    }

    // ----------------------------------------------------------------------------------------
    // The audit stack, redeployed against the token that already exists
    // ----------------------------------------------------------------------------------------

    /// @notice Deploys a fresh KAY9AccessVault, KAY9Registry and KAY9AuditHub on the existing
    ///         token, auditor registry and timelock, exactly as Deploy.s.sol wires them. The old
    ///         hub keeps its `restore` right on the old vault and nothing about the old stack is
    ///         touched. Prints the three addresses; the shell puts them in the environment for
    ///         the stages that follow, and govSchedule/govExecute then hand the vault to the
    ///         timelock.
    function deployAuditStack() external {
        address deployer = vm.addr(_ownerKey());
        vm.startBroadcast(_ownerKey());
        KAY9AccessVault vault = new KAY9AccessVault(deployer, _token());
        address predictedHub = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        KAY9Registry registry = new KAY9Registry(predictedHub);
        KAY9AuditHub hub = new KAY9AuditHub(
            address(_timelock()), address(registry), KAY9AuditorRegistry(vm.envAddress("AUDITOR_REGISTRY")), vault
        );
        require(address(hub) == predictedHub, "hub address prediction failed");
        vault.setAuditHub(address(hub));
        vault.transferOwnership(address(_timelock()));
        vm.stopBroadcast();
        console2.log("KAY9AccessVault          ", address(vault));
        console2.log("KAY9Registry             ", address(registry));
        console2.log("KAY9AuditHub             ", address(hub));
        console2.log("requirementOf(1)         ", vault.requirementOf(1));
        console2.log("requirementOf(2)         ", vault.requirementOf(2));
    }

    // ----------------------------------------------------------------------------------------
    // Requirement, through the timelock
    // ----------------------------------------------------------------------------------------

    /// @notice Schedules `setRequirement(TIER, KAY9)` on the vault. TIER and KAY9 from env.
    function requirementSchedule() external {
        (address target, bytes memory payload) = _requirementCall();
        TimelockController timelock = _timelock();
        uint256 delay = timelock.getMinDelay();
        vm.startBroadcast(_ownerKey());
        timelock.schedule(target, 0, payload, bytes32(0), _requirementSalt(), delay);
        vm.stopBroadcast();
        console2.log("scheduled, executable after", block.timestamp + delay);
        console2.log(
            "operation id             ",
            vm.toString(timelock.hashOperation(target, 0, payload, bytes32(0), _requirementSalt()))
        );
    }

    /// @notice Executes the scheduled `setRequirement` once the delay has elapsed.
    function requirementExecute() external {
        (address target, bytes memory payload) = _requirementCall();
        vm.startBroadcast(_ownerKey());
        _timelock().execute(target, 0, payload, bytes32(0), _requirementSalt());
        vm.stopBroadcast();
        console2.log("requirementOf(1)         ", _vault().requirementOf(1));
        console2.log("requirementOf(2)         ", _vault().requirementOf(2));
    }

    function _requirementCall() internal view returns (address target, bytes memory payload) {
        uint8 tier = uint8(vm.envUint("TIER"));
        uint256 kay9 = vm.envUint("KAY9");
        target = address(_vault());
        payload = abi.encodeCall(KAY9AccessVault.setRequirement, (tier, kay9));
    }

    function _requirementSalt() internal view returns (bytes32) {
        return keccak256(abi.encodePacked("requirement", vm.envUint("TIER"), vm.envUint("KAY9")));
    }

    // ----------------------------------------------------------------------------------------
    // Access
    // ----------------------------------------------------------------------------------------

    /// @notice The depositor claims its auction tokens.
    function claim() external {
        uint256[] memory ids = vm.envUint("BID_IDS", ",");
        address depositor = vm.addr(_userKey());
        vm.startBroadcast(_userKey());
        for (uint256 i = 0; i < ids.length; ++i) {
            _auction().claimTokens(ids[i]);
        }
        vm.stopBroadcast();
        console2.log("depositor KAY9           ", _token().balanceOf(depositor));
    }

    /// @notice Quote, approve and lock a deep period.
    function lockAccess() external {
        KAY9AccessVault vault = _vault();
        address depositor = vm.addr(_userKey());
        uint256 required = vault.requirementOf(1);
        console2.log("deep requirement KAY9    ", required);
        console2.log("depositor KAY9 before    ", _token().balanceOf(depositor));

        vm.startBroadcast(_userKey());
        _token().approve(address(vault), type(uint256).max);
        vault.lock(1, required);
        vm.stopBroadcast();

        _printAccess(depositor);
    }

    /// @notice One audit request from the depositor.
    function request() external {
        address depositor = vm.addr(_userKey());
        uint8 tier = uint8(vm.envOr("TIER", uint256(1)));
        vm.startBroadcast(_userKey());
        uint256 jobId = _hub().requestAudit(CHAIN_KEY, _assetId(), tier, 1);
        vm.stopBroadcast();
        console2.log("jobId                    ", jobId);
        console2.log("jobExpiresAt             ", _hub().jobExpiresAt(jobId));
        _printAccess(depositor);
        console2.log("hub KAY9 balance         ", _token().balanceOf(address(_hub())));
    }

    /// @notice Two agreeing signatures, A and B, submitted by A in one transaction.
    function attestPair() external {
        uint256 jobId = vm.envUint("JOB_ID");
        AuditResult memory result = _result(42, "agree");
        bytes32 digest = _hub().hashResult(jobId, result);
        bytes[] memory signatures = _sorted2(digest, _auditorKey("A"), _auditorKey("B"));

        vm.startBroadcast(_auditorKey("A"));
        uint256 reportId = _hub().attest(jobId, result, signatures);
        vm.stopBroadcast();

        console2.log("reportId                 ", reportId);
        console2.log("job status               ", uint8(_hub().getJob(jobId).status));
        (bool exists, uint256 latestId, uint8 trust,,, uint64 committedAt) =
            _registry().latestSummary(CHAIN_KEY, _assetId());
        console2.log("latestSummary exists/id  ", exists, latestId);
        console2.log("overallTrust/committedAt ", trust, committedAt);
        _printAccess(vm.addr(_userKey()));
    }

    /// @notice Three different results from A, B and C, one transaction each. Job ends Disputed.
    function dispute() external {
        uint256 jobId = vm.envUint("JOB_ID");
        string[3] memory names = ["A", "B", "C"];
        for (uint256 i = 0; i < 3; ++i) {
            uint256 key = _auditorKey(names[i]);
            AuditResult memory result = _result(uint8(10 + 30 * i), string.concat("dissent-", names[i]));
            bytes32 digest = _hub().hashResult(jobId, result);
            bytes[] memory one = new bytes[](1);
            one[0] = _sign(key, digest);
            vm.startBroadcast(key);
            _hub().attest(jobId, result, one);
            vm.stopBroadcast();
            console2.log("attested by / status     ", vm.addr(key), uint8(_hub().getJob(jobId).status));
        }
        // The hub disputes a job only once no position can still reach the threshold, and every
        // active auditor that has not voted counts as a vote that could still arrive. Three
        // dissents therefore dispute a job only when A, B and C are the whole set. A registry that
        // still lists the deployer, or auditors whose keys were thrown away after an earlier run,
        // leaves the job Requested until the SLA expires, and this stage would report that as if
        // the path had been exercised. Failing here fails the simulation, so nothing is broadcast.
        require(
            _hub().getJob(jobId).status == JobStatus.Disputed,
            "dispute: job not disputed; the auditor set must be exactly A, B and C (remove the deployer and stale keys)"
        );
        _printAccess(vm.addr(_userKey()));
    }

    /// @notice Anyone expires a job after its SLA.
    function expire() external {
        uint256 jobId = vm.envUint("JOB_ID");
        console2.log("jobExpiresAt / now       ", _hub().jobExpiresAt(jobId), block.timestamp);
        vm.startBroadcast(_auditorKey("C"));
        _hub().markExpired(jobId);
        vm.stopBroadcast();
        console2.log("job status               ", uint8(_hub().getJob(jobId).status));
        _printAccess(vm.addr(_userKey()));
    }

    /// @notice Deep to forensic, mid-period.
    function upgradeAccess() external {
        address depositor = vm.addr(_userKey());
        uint256 required = _vault().requirementOf(2);
        console2.log("forensic requirement     ", required);
        vm.startBroadcast(_userKey());
        _vault().upgrade(required);
        vm.stopBroadcast();
        _printAccess(depositor);
    }

    /// @notice Renewal at or after expiry.
    function renew() external {
        address depositor = vm.addr(_userKey());
        uint256 before = _token().balanceOf(depositor);
        vm.startBroadcast(_userKey());
        _vault().renew(1, type(uint256).max);
        vm.stopBroadcast();
        console2.log("balance delta (signed)   ", int256(_token().balanceOf(depositor)) - int256(before));
        _printAccess(depositor);
    }

    /// @notice The whole principal back, at or after expiry, reading no oracle.
    function unlock() external {
        address depositor = vm.addr(_userKey());
        uint256 before = _token().balanceOf(depositor);
        uint256 locked = _vault().accessOf(depositor).lockedKay9;
        vm.startBroadcast(_userKey());
        _vault().unlock();
        vm.stopBroadcast();
        console2.log("returned                 ", _token().balanceOf(depositor) - before);
        console2.log("was locked               ", locked);
        console2.log("totalLocked              ", _vault().totalLocked());
    }

    /// @notice Everything about the depositor's period.
    function access() external view {
        _printAccess(vm.addr(_userKey()));
    }

    // ----------------------------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------------------------

    function _assetId() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(_genesis().token()))));
    }

    function _result(uint8 trust, string memory tag) internal view returns (AuditResult memory r) {
        r.chainKey = CHAIN_KEY;
        r.assetId = _assetId();
        r.overallTrust = trust;
        r.contractTrust = trust;
        r.liquidityTrust = trust;
        r.holderTrust = trust;
        r.insiderTrust = trust;
        r.creatorTrust = trust;
        r.tradingTrust = trust;
        r.botTrust = trust;
        r.flags = 0;
        r.engineVersion = 1;
        r.analyzedAt = uint64(vm.envOr("ANALYZED_AT", block.timestamp));
        r.reportHash = keccak256(abi.encodePacked("kay9 testnet rehearsal ", tag));
        r.reportURI = string.concat("ipfs://rehearsal/", tag);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sorted2(bytes32 digest, uint256 keyA, uint256 keyB) internal pure returns (bytes[] memory out) {
        out = new bytes[](2);
        if (vm.addr(keyA) < vm.addr(keyB)) {
            out[0] = _sign(keyA, digest);
            out[1] = _sign(keyB, digest);
        } else {
            out[0] = _sign(keyB, digest);
            out[1] = _sign(keyA, digest);
        }
    }

    function _printAccess(address depositor) internal view {
        Access memory a = _vault().accessOf(depositor);
        console2.log("tier / startedAt / expiresAt", a.tier, a.startedAt, a.expiresAt);
        console2.log("deepUsed / deepQuota     ", a.deepUsed, a.deepQuota);
        console2.log("forensicUsed / quota     ", a.forensicUsed, a.forensicQuota);
        console2.log("lockedKay9               ", a.lockedKay9);
        console2.log("deepRemaining            ", _vault().deepRemaining(depositor));
        console2.log("forensicRemaining        ", _vault().forensicRemaining(depositor));
        console2.log("vault totalLocked        ", _vault().totalLocked());
        console2.log("vault KAY9 balance       ", _token().balanceOf(address(_vault())));
    }
}
