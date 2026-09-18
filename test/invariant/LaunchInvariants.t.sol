// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {LaunchHandler} from "./LaunchHandler.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";

/// @title LaunchInvariants
/// @notice The properties of the launch state machine that must hold whatever order the public
///         actions arrive in, including a stranger competing for the official pool key.
/// @dev The existing `Kay9Invariants` suite drives the token, the vault, the hub and the registry
///      and never calls `KAY9Genesis` at all. The pool-resolution defect found on 2026-09-16 lived
///      exactly there: the vault read a stranger's pool as proof that its own migration had
///      succeeded, refused `recover` and stranded the whole raise. A fuzzer only ever finds what it
///      has been told to guard, and nothing here was guarded. This suite is that gap closed.
contract LaunchInvariants is Kay9TestBase {
    /// @notice The shortest window the vault accepts, so the run reaches the later phases.
    /// @dev A four-hour auction is 144,000 blocks and the fuzzer would spend most of its depth
    ///      walking through it. The phases after the auction are what this suite is about.
    uint64 internal constant MIN_WINDOW_BLOCKS = 36_000;

    /// @notice The floor valuation the fixture launches at, in wei.
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;

    /// @notice The action driver.
    LaunchHandler internal launchHandler;

    /// @notice The launch under test.
    LaunchParams internal params;

    /// @notice True once the launch has ever reported itself migrated.
    bool internal everMigrated;

    /// @notice True once settlement has ever completed.
    bool internal everSettled;

    /// @notice True once recovery has ever run.
    bool internal everRecovered;

    /// @notice The outcome the vault recorded, once it has recorded one.
    bool internal recordedOutcome;

    /// @notice True once an outcome has been recorded at all.
    bool internal outcomeSeen;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();

        params = _launchParams(FLOOR_FDV_WEI, MIN_WINDOW_BLOCKS);
        vm.prank(owner);
        genesis.launch(params);

        address[] memory bidders = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            bidders[i] = makeAddr(string(abi.encodePacked("launchBidder", i)));
        }

        launchHandler = new LaunchHandler(
            genesis,
            uni.lbpStrategy,
            uni.launcher,
            uni.permit2,
            address(uni.positionManager),
            address(uni.initializerHook),
            bidders,
            makeAddr("launchStranger")
        );
        targetContract(address(launchHandler));
    }

    // ---------------------------------------------------------------------------------------
    // The one that matters
    // ---------------------------------------------------------------------------------------

    /// @notice The raise is never stranded: if the vault is holding real money, something must be
    ///         able to move it.
    /// @dev This is the property the 2026-09-16 defect broke. The vault held the entire raise, read
    ///      a stranger's pool as its own migration, and refused every path that could spend it —
    ///      `recover`, `settle` and the relaunch alike. Stated as a property rather than as a case,
    ///      so a sequence nobody thought of has to satisfy it too.
    ///
    ///      Callability is probed against a snapshot and rolled back, so the invariant observes the
    ///      state machine without becoming another actor in it.
    function invariant_theRaiseIsNeverStranded() public {
        uint256 balance = address(genesis).balance;
        // Dust is allowed to sit. The strategy returns a little currency on a healthy migration and
        // there is deliberately no withdrawal path for it.
        if (balance <= 0.01 ether) return;

        uint256 snapshotId = vm.snapshotState();

        bool canSettle;
        try genesis.settle() {
            canSettle = true;
        } catch {}
        vm.revertToState(snapshotId);

        snapshotId = vm.snapshotState();
        bool canRecover;
        try genesis.recover() {
            canRecover = true;
        } catch {}
        vm.revertToState(snapshotId);

        assertTrue(canSettle || canRecover, "the vault holds the raise and neither settle nor recover can move it");
    }

    // ---------------------------------------------------------------------------------------
    // The state machine never goes backwards
    // ---------------------------------------------------------------------------------------

    /// @notice A launch that has reported itself migrated never reports anything else.
    /// @dev Reading the outcome from shared pool state is what made this worth asserting: before the
    ///      fix, what the vault reported depended on who else had touched the pool key.
    function invariant_migratedIsTerminal() public {
        uint8 state = genesis.launchState();
        if (state == 3) everMigrated = true;
        if (everMigrated) {
            assertEq(state, 3, "the launch left the migrated state");
        }
    }

    /// @notice Settlement and recovery are one-way.
    function invariant_settlementNeverUnwinds() public {
        if (genesis.settled()) everSettled = true;
        if (genesis.recovered()) everRecovered = true;
        if (everSettled) assertTrue(genesis.settled(), "settled went back to false");
        if (everRecovered) assertTrue(genesis.recovered(), "recovered went back to false");
    }

    /// @notice Once the migration outcome is written down it never changes.
    /// @dev The record exists precisely because `settle` and `recover` move the balances the outcome
    ///      is read from, so a reading taken afterwards would not be the same reading.
    function invariant_theRecordedOutcomeIsFinal() public {
        if (!genesis.outcomeRecorded()) return;
        bool succeeded = genesis.migrationSucceeded();
        if (!outcomeSeen) {
            outcomeSeen = true;
            recordedOutcome = succeeded;
        }
        assertEq(succeeded, recordedOutcome, "the recorded migration outcome changed");
    }

    // ---------------------------------------------------------------------------------------
    // Supply and allocation
    // ---------------------------------------------------------------------------------------

    /// @notice The vault never holds more KAY9 than the launch allocation it started with.
    function invariant_theVaultNeverExceedsItsAllocation() public view {
        assertLe(
            token.balanceOf(address(genesis)),
            genesis.LAUNCH_ALLOCATION(),
            "the vault holds more than the launch allocation"
        );
    }

    /// @notice The team's tokens are untouchable from the launch path.
    function invariant_vestingIsNeverDrainedByALaunch() public view {
        assertEq(
            token.balanceOf(address(vesting)) + vesting.released(),
            vesting.TOTAL_ALLOCATION(),
            "the vesting contract lost tokens to the launch path"
        );
    }

    /// @notice The supply is minted once and can only go down.
    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), 1_000_000_000e18, "supply exceeded the genesis mint");
    }

    // ---------------------------------------------------------------------------------------
    // Coverage
    // ---------------------------------------------------------------------------------------

    /// @notice Proves the run actually reached the states these invariants are about.
    /// @dev An invariant suite that never leaves the first state is green and worthless, which is
    ///      how the launch path went unguarded in the first place.
    function invariant_callSummary() public view {
        if (vm.envOr("QUIET", false)) return;
        console2Log("bids placed              ", launchHandler.bidsPlaced());
        console2Log("checkpoints              ", launchHandler.checkpoints());
        console2Log("migrations attempted     ", launchHandler.migrationsAttempted());
        console2Log("migrations forced to fail", launchHandler.migrationsForcedToFail());
        console2Log("settlements              ", launchHandler.settlements());
        console2Log("recoveries               ", launchHandler.recoveries());
        console2Log("stranger pools built     ", launchHandler.strangerPools());
    }

    /// @notice Thin wrapper so the summary reads as one line per counter.
    function console2Log(string memory label, uint256 value) private pure {
        console2.log(label, value);
    }
}
