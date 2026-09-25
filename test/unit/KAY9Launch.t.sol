// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {KAY9LiquidityLock} from "../../src/KAY9LiquidityLock.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";
import {
    AuctionParameters,
    MigratorParameters,
    PositionDefinition,
    LiquidityAllocationBracket
} from "../../src/interfaces/uniswap/LauncherTypes.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {ILBPInitializer as IKay9Initializer} from "../../src/interfaces/uniswap/ILBPInitializer.sol";

import {
    MigratorParameters as UpstreamMigratorParameters,
    PoolParameters as UpstreamPoolParameters,
    LiquidityAllocationBracket as UpstreamBracket
} from "liquidity-launcher/src/libraries/MigratorParams.sol";
import {PositionDefinition as UpstreamPositionDefinition} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {
    AuctionParameters as UpstreamAuctionParameters
} from "continuous-clearing-auction/src/interfaces/IContinuousClearingAuction.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";

/// @title KAY9LaunchTest
/// @notice Exercises the fair launch against the real Uniswap liquidity launcher, LBP strategy and
///         continuous clearing auction, from configuration through migration, locking and
///         settlement, and through both failure paths.
contract KAY9LaunchTest is Kay9TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    /// @notice A four-hour auction on the auction's own clock: 14,400 s at the chain's 0.1 s cadence.
    /// @dev The auction reads `ArbSys.arbBlockNumber()` through Uniswap's `BlockNumberish`, and so
    ///      does `KAY9Genesis`; neither reads `block.number`, which on this Orbit chain is the
    ///      parent chain's height. See the note on `KAY9Genesis.MIN_DURATION_BLOCKS`.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;

    /// @notice A one-thousand-dollar floor valuation at 2500 dollars per ETH, expressed in wei.
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;

    /// @notice A bidder used across the graduation tests.
    address internal alice = makeAddr("alice");

    /// @notice A second bidder.
    address internal bob = makeAddr("bob");

    // -------------------------------------------------------------------------------------------
    // Encoding compatibility
    // -------------------------------------------------------------------------------------------

    /// @notice The vendored structs encode byte-for-byte like the upstream ones.
    /// @dev This is the guarantee that KAY9Genesis hands the canonical contracts exactly the
    ///      calldata they expect, and that the website can decode the same events.
    function test_vendoredStructsMatchUpstream() public pure {
        PositionDefinition[] memory mine = new PositionDefinition[](1);
        mine[0] = PositionDefinition({
            offsetLower: -887_272, offsetUpper: 887_272, weight: 1e7, overridePositionRecipient: address(0)
        });
        UpstreamPositionDefinition[] memory theirs = new UpstreamPositionDefinition[](1);
        theirs[0] = UpstreamPositionDefinition({
            offsetLower: -887_272, offsetUpper: 887_272, weight: 1e7, overridePositionRecipient: address(0)
        });
        assertEq(keccak256(abi.encode(mine)), keccak256(abi.encode(theirs)), "position definitions");

        LiquidityAllocationBracket[] memory myBrackets = new LiquidityAllocationBracket[](1);
        myBrackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 1e7});
        UpstreamBracket[] memory theirBrackets = new UpstreamBracket[](1);
        theirBrackets[0] = UpstreamBracket({lowerThreshold: 0, rate: 1e7});
        assertEq(keccak256(abi.encode(myBrackets)), keccak256(abi.encode(theirBrackets)), "brackets");
    }

    /// @notice The migration parameters the vault builds hash identically to the upstream struct.
    function test_migrationParamsEncodingMatchesUpstream() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        MigratorParameters memory mine = genesis.migrationParams();

        PositionDefinition[] memory positions = new PositionDefinition[](1);
        positions[0] = PositionDefinition({
            offsetLower: -887_272, offsetUpper: 887_272, weight: 1e7, overridePositionRecipient: address(0)
        });
        UpstreamBracket[] memory brackets = new UpstreamBracket[](1);
        brackets[0] = UpstreamBracket({lowerThreshold: 0, rate: 1e7});

        UpstreamMigratorParameters memory theirs = UpstreamMigratorParameters({
            token: address(token),
            currency: address(0),
            migrationBlock: p.migrationBlock,
            reservedTokenAmountForLP: uint128(genesis.LIQUIDITY_RESERVE()),
            recipient: address(genesis),
            positionRecipient: address(lock),
            poolParameters: UpstreamPoolParameters({fee: 10_000, tickSpacing: 200, hook: address(uni.initializerHook)}),
            positionDefinitions: abi.encode(positions),
            lpAllocationSchedule: abi.encode(brackets)
        });

        assertEq(keccak256(abi.encode(mine)), keccak256(abi.encode(theirs)), "migration params");
    }

    // -------------------------------------------------------------------------------------------
    // Configuration invariants
    // -------------------------------------------------------------------------------------------

    /// @notice The planned 24-hour auction (owner, 2026-09-25) builds a valid schedule and launches.
    /// @dev 864,000 blocks is also `MAX_DURATION_BLOCKS`, so this is the longest auction the vault
    ///      accepts: the schedule must still sum to exactly 1e7 mps over exactly that many blocks.
    function test_aTwentyFourHourAuctionLaunches() public {
        uint64 day = 864_000;
        assertEq(day, genesis.MAX_DURATION_BLOCKS(), "24 hours is the ceiling");
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, day);
        (uint256 totalMps, uint64 totalBlocks, uint256 steps) = AuctionSteps.totals(p.auctionStepsData);
        assertEq(totalMps, 1e7, "the whole supply is released");
        assertEq(totalBlocks, day, "over exactly 24 hours of blocks");
        for (uint256 i = 0; i < steps; ++i) {
            (uint24 mps, uint40 delta) = AuctionSteps.stepAt(p.auctionStepsData, i);
            assertGt(delta, 0, "no zero-length step");
            assertLe(mps, genesis.MAX_STEP_MPS(), "no step above the cap");
        }

        vm.prank(owner);
        genesis.launch(p);
        assertGt(genesis.auction().code.length, 0, "the auction deployed");
        assertEq(token.balanceOf(genesis.auction()), genesis.AUCTION_ALLOCATION(), "and holds the allocation");
    }

    /// @notice A launch moves exactly 910 M into the pipeline and predicts the auction correctly.
    function test_launchMovesFullAllocation() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        (address predicted, uint256 fdv, uint256 raise) = genesis.previewLaunch(p);

        vm.prank(owner);
        genesis.launch(p);

        assertEq(genesis.auction(), predicted, "auction prediction");
        assertGt(predicted.code.length, 0, "auction deployed");
        assertEq(genesis.launchCount(), 1);
        assertEq(token.balanceOf(address(genesis)), 0, "genesis emptied");
        assertEq(token.balanceOf(predicted), genesis.AUCTION_ALLOCATION(), "auction funded");
        assertEq(token.balanceOf(address(uni.lbpStrategy)), genesis.LIQUIDITY_RESERVE(), "strategy holds the reserve");
        assertEq(fdv, AuctionPriceLib.impliedFdvWei(p.floorPriceQ96, token.TOTAL_SUPPLY()));
        assertEq(raise, p.requiredCurrencyRaised);
    }

    /// @notice The auction the strategy created carries exactly the recipients the vault chose.
    function test_auctionRecipientsAreFixedByTheContract() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        assertEq(auction.token(), address(token));
        assertEq(auction.currency(), address(0));
        assertEq(auction.tokensRecipient(), address(genesis), "unsold supply returns to genesis");
        assertEq(auction.fundsRecipient(), address(uni.lbpStrategy), "raise goes to the strategy");
        assertEq(auction.totalSupply(), uint128(genesis.AUCTION_ALLOCATION()));
        assertEq(auction.startBlock(), p.startBlock);
        assertEq(auction.endBlock(), p.endBlock);
    }

    /// @notice The migration parameters fix the pool fee, spacing, hook and position recipient.
    function test_migrationParamsAreFixedByTheContract() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        MigratorParameters memory mp = genesis.migrationParams();
        assertEq(mp.token, address(token));
        assertEq(mp.currency, address(0));
        assertEq(mp.reservedTokenAmountForLP, uint128(455_000_000e18));
        assertEq(mp.recipient, address(genesis));
        assertEq(mp.positionRecipient, address(lock));
        assertEq(mp.poolParameters.fee, 10_000);
        assertEq(mp.poolParameters.tickSpacing, int24(200));
        assertEq(mp.poolParameters.hook, address(uni.initializerHook));
    }

    /// @notice Only the owner may launch.
    function test_onlyOwnerCanLaunch() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        genesis.launch(p);
    }

    /// @notice A second launch is refused while the first one is still resolvable.
    function test_cannotLaunchTwice() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.startPrank(owner);
        genesis.launch(p);
        p.salt = bytes32(uint256(2));
        vm.expectRevert(abi.encodeWithSelector(KAY9Genesis.WrongLaunchState.selector, uint8(1)));
        genesis.launch(p);
        vm.stopPrank();
    }

    /// @notice Every malformed parameter set is rejected before any token moves.
    function test_malformedParamsRevert() public {
        // Memory structs assign by reference, so each case starts from a freshly built copy.
        LaunchParams memory p = _fresh();
        p.startBlock = uint64(block.number);
        _expectLaunchRevert(p, KAY9Genesis.StartBlockInPast.selector);

        p = _fresh();
        p.endBlock = p.startBlock + genesis.MIN_DURATION_BLOCKS() - 1;
        p.claimBlock = p.endBlock;
        p.migrationBlock = p.endBlock + 1;
        p.auctionStepsData = AuctionSteps.convexSchedule(p.startBlock, p.endBlock);
        _expectLaunchRevert(p, KAY9Genesis.InvalidDuration.selector);

        p = _fresh();
        p.endBlock = p.startBlock + genesis.MAX_DURATION_BLOCKS() + 1;
        p.claimBlock = p.endBlock;
        p.migrationBlock = p.endBlock + 1;
        p.auctionStepsData = AuctionSteps.convexSchedule(p.startBlock, p.endBlock);
        _expectLaunchRevert(p, KAY9Genesis.InvalidDuration.selector);

        p = _fresh();
        p.claimBlock = p.endBlock - 1;
        _expectLaunchRevert(p, KAY9Genesis.InvalidClaimBlock.selector);

        p = _fresh();
        p.migrationBlock = p.endBlock;
        _expectLaunchRevert(p, KAY9Genesis.InvalidMigrationBlock.selector);

        p = _fresh();
        p.floorPriceQ96 = 1;
        _expectLaunchRevert(p, KAY9Genesis.InvalidFloorPrice.selector);

        p = _fresh();
        p.floorPriceQ96 = p.floorPriceQ96 + 1;
        _expectLaunchRevert(p, KAY9Genesis.InvalidFloorPrice.selector);

        p = _fresh();
        p.auctionTickSpacingQ96 = 1;
        _expectLaunchRevert(p, KAY9Genesis.InvalidAuctionTickSpacing.selector);

        p = _fresh();
        p.requiredCurrencyRaised = 0;
        _expectLaunchRevert(p, KAY9Genesis.InvalidRequiredRaise.selector);

        p = _fresh();
        p.auctionStepsData = "";
        _expectLaunchRevert(p, KAY9Genesis.InvalidAuctionSteps.selector);

        p = _fresh();
        p.auctionStepsData = hex"0011";
        _expectLaunchRevert(p, KAY9Genesis.InvalidAuctionSteps.selector);

        // Nothing moved through any of those attempts.
        assertEq(token.balanceOf(address(genesis)), genesis.LAUNCH_ALLOCATION());
        assertEq(genesis.launchCount(), 0);
    }

    /// @notice The id of the most recently minted Uniswap position.
    /// @return The position id.
    function _latestPositionId() internal view returns (uint256) {
        return uni.positionManager.nextTokenId() - 1;
    }

    /// @notice A freshly built, valid parameter set.
    /// @return The parameters.
    function _fresh() internal view returns (LaunchParams memory) {
        return _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
    }

    /// @notice The generated emission schedule satisfies the auction's own invariants.
    function test_auctionStepsInvariants() public pure {
        uint64 start = 1_000_000;
        uint64 end = start + FOUR_HOURS_BLOCKS;
        bytes memory schedule = AuctionSteps.convexSchedule(start, end);
        (uint256 totalMps, uint64 totalBlocks, uint256 steps) = AuctionSteps.totals(schedule);
        assertEq(totalMps, 1e7, "mps total");
        assertEq(totalBlocks, end - start, "block total");
        assertEq(steps, 13, "twelve ramp steps plus the final block");

        (uint24 finalMps, uint40 finalDelta) = AuctionSteps.stepAt(schedule, steps - 1);
        assertEq(finalDelta, 1, "the last step is a single block");
        assertGt(finalMps, 2_000_000, "the last block carries the reserved share");

        for (uint256 i = 0; i < steps; ++i) {
            (, uint40 delta) = AuctionSteps.stepAt(schedule, i);
            assertGt(delta, 0, "no zero-length step");
        }
    }

    // -------------------------------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------------------------------

    /// @notice A graduated auction migrates, the LP NFT reaches the lock, and locking is one-way.
    function test_graduationMigrationAndLock() public {
        LaunchParams memory p = _runGraduatingAuction();

        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));

        assertEq(genesis.launchState(), 3, "migrated");

        PoolKey memory key = genesis.poolKey();
        (uint160 sqrtPriceX96,,,) = uni.poolManager.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "pool initialized");
        assertEq(key.fee, 10_000, "one percent fee");
        assertEq(key.tickSpacing, int24(200), "tick spacing");
        assertEq(address(key.hooks), address(uni.initializerHook), "keyed on the canonical initializer hook");

        uint256 tokenId = _latestPositionId();
        assertEq(IERC721(address(uni.positionManager)).ownerOf(tokenId), address(lock), "lock owns the position");

        // The canonical PositionManager mints without a receiver callback, so the lock only learns
        // about a migration position when someone announces it. Both entry points are exercised.
        lock.track(tokenId);
        assertEq(lock.lockedTokenIds(0), tokenId);
        lock.lockAll();
        assertTrue(lock.isLocked(tokenId));
        assertEq(
            IERC721(address(uni.positionManager)).ownerOf(tokenId),
            address(uni.feeSplitter),
            "position handed to the fee splitter"
        );
        assertEq(uni.beneficiaryVault.ownerOf(tokenId), creatorFeeRecipient, "creator fee registered");

        vm.expectRevert(abi.encodeWithSelector(KAY9LiquidityLock.AlreadyLocked.selector, tokenId));
        lock.lock(tokenId);
    }

    /// @notice A good migration leaves at most rounding dust in the vault. Measured at zero.
    function test_aGoodMigrationLeavesAtMostDust() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        assertLt(address(genesis).balance, 1e9, "a good migration returns dust or nothing");
    }

    /// @notice ETH the vault holds after a good migration ends in a locked position, not in the vault.
    function test_settlePlacesLeftoverEth() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        lock.lock(_latestPositionId());

        // Far below half the raise, so the migration still reads as good.
        uint256 leftover = 0.001 ether;
        vm.deal(address(genesis), address(genesis).balance + leftover);
        uint256 nextId = uni.positionManager.nextTokenId();

        genesis.settle();

        assertLe(address(genesis).balance, 1, "at most one wei of rounding stays behind");
        uint256 last = uni.positionManager.nextTokenId() - 1;
        assertGt(last, nextId, "a KAY9 position and an ETH position were both minted");
        assertEq(IERC721(address(uni.positionManager)).ownerOf(last), address(uni.feeSplitter), "ETH position locked");
    }

    /// @notice Timing fields that would lock the raise or the bids up for years are refused (F-1).
    function test_launchRejectsFarFutureTiming() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        uint64 maxLag = genesis.MAX_DURATION_BLOCKS();

        LaunchParams memory q = p;
        q.migrationBlock = p.endBlock + maxLag + 1;
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.InvalidMigrationBlock.selector);
        genesis.launch(q);

        q = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        q.claimBlock = p.endBlock + maxLag + 1;
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.InvalidClaimBlock.selector);
        genesis.launch(q);

        uint64 far = uint64(genesis.chainBlockNumber()) + genesis.MAX_START_DELAY_BLOCKS() + 1;
        q = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        q.startBlock = far;
        q.endBlock = far + FOUR_HOURS_BLOCKS;
        q.claimBlock = q.endBlock;
        q.migrationBlock = q.endBlock + 1;
        q.auctionStepsData = AuctionSteps.convexSchedule(q.startBlock, q.endBlock);
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.StartBlockTooFar.selector);
        genesis.launch(q);
    }

    /// @notice A schedule that releases most of the supply in one block is refused (F-7).
    function test_launchRejectsAConcentratedSchedule() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        // 60 % in the final block.
        p.auctionStepsData = AuctionSteps.convexSchedule(p.startBlock, p.endBlock, 12, 6e6);
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.InvalidAuctionSteps.selector);
        genesis.launch(p);
    }

    /// @notice migrateAndSettle migrates, locks the migration positions and settles in one call (F-3, F-6).
    function test_migrateAndSettleLocksAndSettlesAtOnce() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uint256 firstId = uni.positionManager.nextTokenId();

        genesis.migrateAndSettle();

        assertEq(genesis.launchState(), 3, "migrated");
        assertTrue(genesis.settled(), "settled in the same transaction");
        assertTrue(genesis.outcomeRecorded(), "the outcome is written down before anyone else can move the balance");
        assertTrue(lock.isLocked(firstId), "the migration position is locked");
        assertEq(IERC721(address(uni.positionManager)).ownerOf(firstId), address(uni.feeSplitter));
        assertLe(address(genesis).balance, 1, "no raise left in the vault");
        // A gift of half the raise after settlement changes nothing any more.
        vm.deal(address(genesis), 10 ether);
        assertEq(genesis.launchState(), 3, "still migrated");
    }

    /// @notice Half the raise given to the vault before the migration no longer turns a good
    ///         migration into the recovery path when it runs through migrateAndSettle (R-01).
    function test_migrateAndSettleIgnoresAGiftSentBeforehand() public {
        LaunchParams memory p = _runGraduatingAuction();
        uint256 raised = IContinuousClearingAuction(genesis.auction()).currencyRaised();
        vm.roll(p.migrationBlock);
        vm.deal(address(genesis), raised);

        genesis.migrateAndSettle();

        assertEq(genesis.launchState(), 3, "migrated, not failed");
        assertTrue(genesis.migrationSucceeded(), "recorded as a good migration");
        assertTrue(genesis.settled(), "settled");
        assertFalse(genesis.recovered(), "no second pool");
        assertLe(address(genesis).balance, 1, "the gift went into locked liquidity");
        vm.expectRevert(KAY9Genesis.NothingToRecover.selector);
        genesis.recover();
    }

    /// @notice Renouncing ownership would strand the allocation, so it is refused (F-10).
    function test_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.OwnershipCannotBeRenounced.selector);
        genesis.renounceOwnership();
        assertEq(genesis.owner(), owner);
    }

    /// @notice A graduation threshold too small for the migration-outcome test is refused.
    function test_launchRejectsATinyGraduationRaise() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p.requiredCurrencyRaised = 1e15 - 1;
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.InvalidRequiredRaise.selector);
        genesis.launch(p);
    }

    /// @notice Settlement places the unsold supply as a single-sided position and locks it too.
    function test_settleLocksUnsoldSupply() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));

        lock.lock(_latestPositionId());

        uint256 held = token.balanceOf(address(genesis));
        assertGt(held, 0, "leftover reserve returned to genesis");

        genesis.settle();

        assertTrue(genesis.settled(), "settled");
        assertLt(token.balanceOf(address(genesis)), genesis.DUST_THRESHOLD(), "genesis holds at most dust");
        // Any ETH dust the strategy forwarded stays frozen: the vault has no withdrawal path.
        assertLt(address(genesis).balance, 0.001 ether, "at most ETH dust remains, and it is frozen");

        uint256 settleTokenId = lock.lockedTokenIds(lock.lockedCount() - 1);
        assertTrue(lock.isLocked(settleTokenId), "settlement position locked");
        assertEq(
            IERC721(address(uni.positionManager)).ownerOf(settleTokenId),
            address(uni.feeSplitter),
            "settlement position at the fee splitter"
        );
    }

    /// @notice Giving the vault half the raise after a good migration buys a second pool and
    ///         nothing else: no ETH or KAY9 is stranded, and none of it comes back to the giver.
    /// @dev The vault tells a failed migration from a good one by whether the raise came back to it
    ///      (`_raiseCameBack`), because that is the one signal that errs in the safe direction: it
    ///      can never read a failed migration as a good one and strand the raise. The price of that
    ///      is this case. Anyone willing to give the vault at least half of what the auction raised,
    ///      before `settle` has recorded the outcome, makes a good migration read as failed. `settle`
    ///      then refuses, `recover` runs, and the launch ends with two pools: the official one the
    ///      migration built, holding the real raise, and a hookless one holding the giver's ETH and
    ///      the leftover supply. The gift is locked as KAY9 liquidity for good. This test pins that
    ///      the damage stops there.
    function test_aGiftOfHalfTheRaiseBuysASecondPoolAndStrandsNothing() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        assertEq(genesis.launchState(), 3, "migrated");
        uint256 migrationPosition = _latestPositionId();

        uint256 raised = IContinuousClearingAuction(genesis.auction()).currencyRaised();
        address giver = makeAddr("giver");
        vm.deal(giver, raised);
        vm.prank(giver);
        (bool sent,) = address(genesis).call{value: raised / 2}("");
        assertTrue(sent, "the vault accepts ETH, as it must for the strategy's own refunds");

        assertEq(genesis.launchState(), 4, "the good migration now reads as failed");
        vm.expectRevert(KAY9Genesis.PoolNotReady.selector);
        genesis.settle();

        genesis.recover();

        // Nothing is stranded, and the launch is over.
        assertTrue(genesis.settled(), "settled");
        assertEq(genesis.launchState(), 3, "and reads as migrated again");
        assertLt(address(genesis).balance, raised / 1000, "the gift went into the pool, not into the vault");
        assertLt(token.balanceOf(address(genesis)), genesis.DUST_THRESHOLD(), "at most dust left");
        assertEq(giver.balance, raised - raised / 2, "nothing came back to the giver");

        // The pool the migration built is untouched and still holds the real raise.
        (uint160 officialPrice,,,) = uni.poolManager.getSlot0(_officialKey().toId());
        assertGt(officialPrice, 0, "the official pool is still there");
        assertEq(
            IERC721(address(uni.positionManager)).ownerOf(migrationPosition),
            address(lock),
            "and its position still belongs to the lock"
        );

        // Every position the recovery minted is locked at the fee splitter, like any other.
        for (uint256 i = 0; i < lock.lockedCount(); ++i) {
            uint256 tokenId = lock.lockedTokenIds(i);
            assertTrue(lock.isLocked(tokenId), "locked");
            assertEq(IERC721(address(uni.positionManager)).ownerOf(tokenId), address(uni.feeSplitter));
        }

        // The cost of the confusion: the canonical pool is now the hookless one.
        assertEq(address(genesis.poolKey().hooks), address(0), "poolKey() now names the recovery pool");
    }

    /// @notice Once `settle` has recorded a good migration, no gift can reopen it.
    function test_aGiftAfterSettlementChangesNothing() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        genesis.settle();

        uint256 raised = IContinuousClearingAuction(genesis.auction()).currencyRaised();
        vm.deal(address(this), raised);
        (bool sent,) = address(genesis).call{value: raised}("");
        assertTrue(sent);

        assertEq(genesis.launchState(), 3, "still migrated");
        assertEq(address(genesis.poolKey().hooks), address(uni.initializerHook), "still the official pool");
        vm.expectRevert(KAY9Genesis.NothingToRecover.selector);
        genesis.recover();
    }

    /// @notice Settlement cannot run twice.
    function test_settleIsIdempotentGuarded() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        lock.lock(_latestPositionId());
        genesis.settle();
        vm.expectRevert(KAY9Genesis.AlreadySettled.selector);
        genesis.settle();
    }

    /// @notice Settlement is refused while there is no pool.
    function test_settleRequiresPool() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);
        vm.expectRevert(KAY9Genesis.PoolNotReady.selector);
        genesis.settle();
    }

    // -------------------------------------------------------------------------------------------
    // Failure paths
    // -------------------------------------------------------------------------------------------

    /// @notice An auction that does not graduate returns the whole allocation and allows a relaunch.
    function test_nonGraduationAndRelaunch() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        vm.roll(p.endBlock + 1);
        assertEq(genesis.launchState(), 2, "ended; not failed until the final checkpoint says so");
        IContinuousClearingAuction(genesis.auction()).checkpoint();
        assertEq(genesis.launchState(), 4, "failed");

        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        assertEq(genesis.launchState(), 4, "still failed after the recovery branch");
        assertEq(token.balanceOf(address(genesis)), genesis.LIQUIDITY_RESERVE(), "reserve returned");

        genesis.markFailed();
        uint256 earliest = genesis.earliestRelaunchTimestamp();
        assertEq(earliest, block.timestamp + genesis.RELAUNCH_DELAY());

        LaunchParams memory p2 = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p2.salt = bytes32(uint256(7));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KAY9Genesis.RelaunchTooEarly.selector, earliest));
        genesis.launch(p2);

        vm.warp(earliest);
        p2 = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p2.salt = bytes32(uint256(7));
        vm.prank(owner);
        genesis.launch(p2);

        assertEq(genesis.launchCount(), 2);
        assertEq(genesis.launchState(), 1, "the new auction is live");
        assertEq(token.balanceOf(address(genesis)), 0, "the whole allocation moved again");
    }

    /// @notice A relaunch releases the strategy's reserve itself when nobody called migrate on
    ///         the failed auction, and refuses cleanly while the strategy still cannot release it.
    function test_relaunchReleasesReserveFromStrategy() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p.migrationBlock = p.endBlock + 1000;
        vm.prank(owner);
        genesis.launch(p);

        vm.roll(p.endBlock + 1);
        IContinuousClearingAuction(genesis.auction()).checkpoint();
        assertEq(genesis.launchState(), 4, "failed");
        genesis.markFailed();
        vm.warp(genesis.earliestRelaunchTimestamp());

        LaunchParams memory p2 = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p2.salt = bytes32(uint256(7));

        // The strategy still holds the reserve and the pool id, and its migration block has not
        // arrived, so the relaunch cannot release either yet and says so.
        assertEq(token.balanceOf(address(genesis)), 0, "reserve still in the strategy");
        vm.prank(owner);
        vm.expectRevert();
        genesis.launch(p2);

        vm.roll(p.migrationBlock);
        p2 = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p2.salt = bytes32(uint256(7));
        vm.prank(owner);
        genesis.launch(p2);

        assertEq(genesis.launchCount(), 2);
        assertEq(genesis.launchState(), 1, "the new auction is live");
        assertEq(token.balanceOf(address(genesis)), 0, "the whole allocation moved again");
        assertEq(token.balanceOf(address(uni.lbpStrategy)), genesis.LIQUIDITY_RESERVE(), "one reserve, not two");
    }

    /// @notice A relaunch with the owner-facing salt unchanged, which is how the testnet relaunch
    ///         runs (`LAUNCH_SALT` defaults to 1 both times). The strategy salts the auction with
    ///         the migration parameters as well, so a later window is a new auction address, and
    ///         the failed auction is swept inside `launch()`.
    function test_relaunchKeepsTheOwnerFacingSalt() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);
        address first = genesis.auction();

        vm.roll(p.endBlock + 1);
        IContinuousClearingAuction(first).checkpoint();
        genesis.markFailed();
        vm.roll(p.migrationBlock);
        vm.warp(genesis.earliestRelaunchTimestamp());

        LaunchParams memory p2 = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        assertEq(p2.salt, p.salt, "same owner-facing salt");
        vm.prank(owner);
        genesis.launch(p2);

        assertEq(genesis.launchCount(), 2);
        assertTrue(genesis.auction() != first, "a new auction address");
        assertEq(genesis.launchState(), 1, "the new auction is live");
        assertEq(token.balanceOf(address(genesis)), 0, "the whole allocation moved again");
        assertEq(token.balanceOf(first), 0, "the failed auction was swept");
        assertEq(token.balanceOf(address(uni.lbpStrategy)), genesis.LIQUIDITY_RESERVE(), "one reserve, not two");
    }

    /// @notice Pushing the price down right before `settle` cannot pull the leftover ladder below
    ///         the auction's clearing price. Anchored at spot alone, the ladder moved with the dump
    ///         and the manipulator could buy the leftover back below what every bidder paid.
    function test_settleIgnoresPushedDownPrice() public {
        LaunchParams memory p = _runGraduatingAuction();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        lock.lock(_latestPositionId());

        int24 clearingTick = TickMath.getTickAtSqrtPrice(
            AuctionPriceLib.toSqrtPriceX96(IContinuousClearingAuction(genesis.auction()).clearingPrice(), true)
        );

        uint256 dump = 50_000_000e18;
        deal(address(token), address(this), dump);
        _sellKay9(dump);
        (, int24 pushedTick,,) = uni.poolManager.getSlot0(genesis.poolKey().toId());
        assertGt(pushedTick, clearingTick + 2 * genesis.POOL_TICK_SPACING(), "the dump really moved the price");

        uint256 positionsBefore = lock.lockedCount();
        genesis.settle();
        assertEq(lock.lockedCount(), positionsBefore + 1, "the leftover was placed, not burned");

        (, PositionInfo info) = uni.positionManager.getPoolAndPositionInfo(lock.lockedTokenIds(positionsBefore));
        assertLe(
            info.tickUpper(),
            clearingTick - genesis.POOL_TICK_SPACING(),
            "the ladder starts no cheaper than the clearing price"
        );
        assertLt(info.tickUpper(), pushedTick, "and below spot, so the position stays single-sided");
    }

    /// @notice An auction that graduates only at its final checkpoint must not read as failed
    ///         before that checkpoint, and nobody may start the relaunch cooldown on it.
    function test_launchStateWaitsForFinalCheckpoint() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        vm.roll(p.startBlock + 1);
        _bid(auction, alice, p.floorPriceQ96 * 8, uint128(uint256(p.requiredCurrencyRaised) * 3));

        vm.roll(p.endBlock + 1);
        assertFalse(auction.isGraduated(), "the stored figure still predates the final block");
        assertEq(genesis.launchState(), 2, "ended, not failed: the final checkpoint has not run");
        vm.expectRevert(KAY9Genesis.NotFailed.selector);
        genesis.markFailed();

        auction.checkpoint();
        assertTrue(auction.isGraduated(), "the final checkpoint graduates it");
        assertEq(genesis.launchState(), 2, "ended and graduated, awaiting migration");
    }

    /// @notice A partially filled, non-graduating auction still returns everything.
    function test_partialAuctionDoesNotGraduate() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        vm.roll(p.startBlock + 1000);
        _bid(auction, alice, p.floorPriceQ96 * 4, uint128(p.requiredCurrencyRaised / 10));

        vm.roll(p.endBlock);
        auction.checkpoint();
        assertFalse(auction.isGraduated(), "not graduated");
        assertGt(auction.currencyRaised(), 0, "but partially filled");

        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(address(auction)));
        assertEq(genesis.launchState(), 4);

        genesis.markFailed();
        assertGt(genesis.earliestRelaunchTimestamp(), 0);
    }

    /// @notice markFailed refuses to start the cooldown on a healthy launch.
    function test_markFailedRejectsHealthyLaunch() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);
        vm.expectRevert(KAY9Genesis.NotFailed.selector);
        genesis.markFailed();
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Runs a full auction that graduates.
    /// @return p The launch parameters used.
    function _runGraduatingAuction() internal returns (LaunchParams memory p) {
        p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());

        uint128 amount = uint128(uint256(p.requiredCurrencyRaised) * 3);
        vm.roll(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        _bid(auction, alice, p.floorPriceQ96 * 8, amount);

        vm.roll(p.endBlock - 1);
        _bid(auction, bob, p.floorPriceQ96 * 8, amount);

        vm.roll(p.endBlock);
        auction.checkpoint();
        assertTrue(auction.isGraduated(), "auction graduated");
    }

    /// @notice Places one bid at a price snapped to the auction tick grid.
    /// @param auction The auction to bid into.
    /// @param bidder The bidder.
    /// @param rawPriceQ96 The desired price, snapped down to the tick grid.
    /// @param amount The ETH committed.
    function _bid(IContinuousClearingAuction auction, address bidder, uint256 rawPriceQ96, uint128 amount) internal {
        LaunchParams memory p = genesis.launchParams();
        uint256 price = rawPriceQ96 - (rawPriceQ96 % p.auctionTickSpacingQ96);
        vm.deal(bidder, amount);
        vm.prank(bidder);
        auction.submitBid{value: amount}(price, amount, bidder, "");
    }

    /// @notice Asserts that a set of launch parameters is rejected with a specific error.
    /// @param p The parameters.
    /// @param selector The expected error selector.
    function _expectLaunchRevert(LaunchParams memory p, bytes4 selector) internal {
        vm.prank(owner);
        vm.expectPartialRevert(selector);
        genesis.launch(p);
    }
}
