// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";
import {ILiquidityLauncher} from "../../src/interfaces/uniswap/ILiquidityLauncher.sol";
import {
    AuctionParameters,
    Distribution,
    LiquidityAllocationBracket,
    MigratorParameters,
    PoolParameters,
    PositionDefinition
} from "../../src/interfaces/uniswap/LauncherTypes.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title GenesisStrangerPoolTest
/// @notice The strategy frees the official pool id before it attempts a migration and never takes
///         it back when that migration reverts, so a stranger holding a little KAY9 can register
///         their own distribution on the same key and bring the official pool into being. The vault
///         has to keep reading its own launch as failed, or the whole raise would be stranded in a
///         contract with no code path able to spend it.
contract GenesisStrangerPoolTest is Kay9TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice A four-hour auction on the auction's own clock.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;

    /// @notice The floor valuation the fixture launches at, in wei.
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;

    /// @notice The bidder who graduates the real auction.
    address internal alice = makeAddr("alice");

    /// @notice The KAY9 holder who migrates a distribution of their own on the official key.
    address internal stranger = makeAddr("stranger");

    /// @notice A stranger distribution on the official key does not turn a failed migration into a
    ///         migrated launch, and the raise stays recoverable.
    function test_strangerPoolAfterAGraduatedFailedMigrationLeavesTheRaiseRecoverable() public {
        (LaunchParams memory p, uint256 clearingPrice) = _graduateThenFailMigration();

        assertEq(genesis.launchState(), 4, "failed after the migration reverted");
        uint256 raised = address(genesis).balance;
        assertGt(raised, 0, "the whole raise came back to the vault");

        _strangerMigratesOnTheOfficialKey(p);

        (uint160 officialPrice,,,) = uni.poolManager.getSlot0(_officialKey().toId());
        assertGt(officialPrice, 0, "a stranger distribution created the official pool");

        assertEq(genesis.launchState(), 4, "the failure is still this launch own, not theirs");
        vm.expectRevert(KAY9Genesis.PoolNotReady.selector);
        genesis.settle();

        genesis.recover();

        PoolKey memory key = genesis.poolKey();
        assertEq(address(key.hooks), address(0), "the raise went into the vault own recovery pool");
        (uint160 recoveryPrice,,,) = uni.poolManager.getSlot0(key.toId());
        assertEq(recoveryPrice, AuctionPriceLib.toSqrtPriceX96(clearingPrice, true), "priced at the clearing price");
        assertLt(address(genesis).balance, raised / 1000, "essentially all of the raise is now liquidity");
        assertTrue(genesis.outcomeRecorded(), "the outcome is written down");
        assertFalse(genesis.migrationSucceeded());
    }

    /// @notice The recorded outcome survives the balance moves settlement itself makes.
    function test_aHealthyMigrationStillReadsAsMigratedAfterSettlement() public {
        LaunchParams memory p = _runGraduatingAuction();

        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));

        assertEq(genesis.launchState(), 3, "migrated");
        genesis.settle();

        assertTrue(genesis.outcomeRecorded());
        assertTrue(genesis.migrationSucceeded());
        assertEq(genesis.launchState(), 3, "still migrated once the unsold supply has been placed");
        assertEq(address(genesis.poolKey().hooks), address(uni.initializerHook), "the official pool");
    }

    /// @notice An auction that graduated on a fraction of its supply still reads as migrated. The
    ///         outcome is told apart by the raise, and this is the shape that leaves the most of the
    ///         liquidity reserve unspent, so it is the one that would break that reading first.
    function test_aPartiallySoldAuctionStillReadsAsMigrated() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p.requiredCurrencyRaised = p.requiredCurrencyRaised / 4;
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        uint128 amount = uint128(uint256(p.requiredCurrencyRaised) * 2);
        uint256 price = p.floorPriceQ96 * 8;
        price -= price % p.auctionTickSpacingQ96;

        vm.roll(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        vm.deal(alice, amount);
        vm.prank(alice);
        auction.submitBid{value: amount}(price, amount, alice, "");

        vm.roll(p.endBlock);
        auction.checkpoint();
        assertTrue(auction.isGraduated(), "graduated on part of the supply");
        assertGt(auction.remainingSupply(), genesis.DUST_THRESHOLD(), "a real unsold remainder");

        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(address(auction)));

        assertEq(genesis.launchState(), 3, "migrated, even though most of the reserve came back");
        genesis.settle();
        assertTrue(genesis.settled());
        assertEq(genesis.launchState(), 3, "still migrated after settlement");
    }

    /// @notice Registers, graduates and migrates a stranger KAY9 distribution on the official pool
    ///         key, which the failed migration left unreserved.
    /// @param p The failed launch parameters, reused for the price grid.
    function _strangerMigratesOnTheOfficialKey(LaunchParams memory p) internal {
        uint128 total = 10_000e18;
        uint128 reserve = 1_000e18;

        // A bidder already holds KAY9 by this point in a real launch.
        _fundKay9(stranger, total);

        uint256 required = (p.floorPriceQ96 * uint256(total - reserve)) >> 96;
        uint64 start = uint64(genesis.chainBlockNumber() + 10);
        uint64 end = start + 1_000;

        PositionDefinition[] memory positions = new PositionDefinition[](1);
        positions[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: 1e7,
            overridePositionRecipient: address(0)
        });
        LiquidityAllocationBracket[] memory brackets = new LiquidityAllocationBracket[](1);
        brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: 1e7});

        MigratorParameters memory mp = MigratorParameters({
            token: address(token),
            currency: address(0),
            migrationBlock: end + 1,
            reservedTokenAmountForLP: reserve,
            recipient: stranger,
            positionRecipient: stranger,
            poolParameters: PoolParameters({fee: 10_000, tickSpacing: 200, hook: address(uni.initializerHook)}),
            positionDefinitions: abi.encode(positions),
            lpAllocationSchedule: abi.encode(brackets)
        });

        AuctionParameters memory ap = AuctionParameters({
            currency: address(0),
            tokensRecipient: stranger,
            fundsRecipient: address(1),
            startBlock: start,
            endBlock: end,
            claimBlock: end,
            tickSpacing: p.auctionTickSpacingQ96,
            validationHook: address(0),
            floorPrice: p.floorPriceQ96,
            requiredCurrencyRaised: uint128(required),
            auctionStepsData: AuctionSteps.convexSchedule(start, end)
        });

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ILiquidityLauncher.depositToken, (address(token), total));
        calls[1] = abi.encodeCall(
            ILiquidityLauncher.distributeToken,
            (
                address(token),
                Distribution({
                    strategy: address(uni.lbpStrategy), amount: total, configData: abi.encode(mp, abi.encode(ap))
                }),
                bytes32(uint256(99))
            )
        );

        vm.startPrank(stranger);
        IERC20(address(token)).approve(address(uni.permit2), type(uint256).max);
        uni.permit2.approve(address(token), address(uni.launcher), total, uint48(block.timestamp + 600));
        uni.launcher.multicall(calls);
        vm.stopPrank();

        address strangerAuction = uni.lbpStrategy.registeredPoolIds(_officialKey().toId());
        assertTrue(strangerAuction != address(0), "the stranger reserved the freed official pool id");

        IContinuousClearingAuction strangerSale = IContinuousClearingAuction(strangerAuction);
        uint256 price = p.floorPriceQ96 * 2;
        price -= price % p.auctionTickSpacingQ96;
        uint128 bid = uint128(required * 3);

        vm.roll(start + 500);
        vm.deal(stranger, bid);
        vm.prank(stranger);
        strangerSale.submitBid{value: bid}(price, bid, stranger, "");

        vm.roll(end);
        strangerSale.checkpoint();
        assertTrue(strangerSale.isGraduated(), "the stranger auction graduated");

        vm.roll(end + 1);
        uni.lbpStrategy.migrate(ILBPInitializer(strangerAuction));
    }

    /// @notice Runs a graduating auction and forces the strategy migration to revert.
    /// @return p The launch parameters.
    /// @return clearingPrice The final clearing price.
    function _graduateThenFailMigration() internal returns (LaunchParams memory p, uint256 clearingPrice) {
        p = _runGraduatingAuction();
        clearingPrice = IContinuousClearingAuction(genesis.auction()).clearingPrice();

        vm.roll(p.migrationBlock);
        vm.mockCallRevert(
            address(uni.positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "position manager down"
        );
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        vm.clearMockedCalls();
    }

    /// @notice Launches and runs one auction to graduation.
    /// @return p The launch parameters.
    function _runGraduatingAuction() internal returns (LaunchParams memory p) {
        p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        uint128 amount = uint128(uint256(p.requiredCurrencyRaised) * 3);
        uint256 price = p.floorPriceQ96 * 8;
        price -= price % p.auctionTickSpacingQ96;

        vm.roll(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        vm.deal(alice, amount);
        vm.prank(alice);
        auction.submitBid{value: amount}(price, amount, alice, "");

        vm.roll(p.endBlock);
        auction.checkpoint();
        assertTrue(auction.isGraduated(), "auction graduated");
    }
}
