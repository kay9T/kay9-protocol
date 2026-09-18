// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {LBPStrategy} from "liquidity-launcher/src/strategies/lbp/LBPStrategy.sol";
import {LiquidityLauncher} from "liquidity-launcher/src/LiquidityLauncher.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {KAY9Token} from "../../src/KAY9Token.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
// The upstream structs, not KAY9's vendored copies: these are handed straight to the real launcher
// and the real strategy, and two structurally identical structs from different files are still two
// types to the compiler. Only `AuctionParameters` is KAY9's, because the auction takes it as bytes.
import {Distribution} from "liquidity-launcher/src/types/Distribution.sol";
import {PositionDefinition} from "liquidity-launcher/src/types/PositionPlannerTypes.sol";
import {
    MigratorParameters,
    LiquidityAllocationBracket,
    PoolParameters
} from "liquidity-launcher/src/libraries/MigratorParams.sol";
import {AuctionParameters} from "../../src/interfaces/uniswap/LauncherTypes.sol";

/// @title LaunchHandler
/// @notice Drives the launch state machine for the invariant run.
/// @dev The existing `Kay9Handler` covers the token, the vault, the hub and the registry and never
///      touches `KAY9Genesis`, which is why the fuzzer had nothing to say about the launch path —
///      and why the pool-resolution defect found on 2026-09-16 could not have been caught here.
///      This handler exists to close that gap, so it deliberately includes the adversarial action
///      as well as the honest ones: a stranger can register a distribution of KAY9 on the official
///      pool key once a failed migration has released it.
contract LaunchHandler is CommonBase, StdUtils {
    using PoolIdLibrary for PoolKey;

    /// @notice The vault under test.
    KAY9Genesis public immutable genesis;

    /// @notice The token it deployed.
    KAY9Token public immutable token;

    /// @notice The canonical strategy this launch migrates through.
    LBPStrategy public immutable strategy;

    /// @notice The launcher a distribution is registered through.
    LiquidityLauncher public immutable launcher;

    /// @notice Permit2, for the stranger's own distribution.
    IAllowanceTransfer public immutable permit2;

    /// @notice The position manager, mocked to force a migration failure.
    address public immutable positionManager;

    /// @notice The canonical initializer hook the official pool is keyed on.
    address public immutable poolHook;

    /// @notice The bidders.
    address[] public bidders;

    /// @notice The stranger who competes for the official pool key.
    address public immutable stranger;

    /// @notice Bid ids the handler has opened, so exits and claims have something to aim at.
    uint256[] public bidIds;

    // Counters, so `test_handlerReachesEveryState` can prove the run went somewhere.
    uint256 public bidsPlaced;
    uint256 public checkpoints;
    uint256 public migrationsAttempted;
    uint256 public migrationsForcedToFail;
    uint256 public settlements;
    uint256 public recoveries;
    uint256 public strangerPools;

    /// @notice Binds the handler to a launch that has already been configured.
    constructor(
        KAY9Genesis genesis_,
        LBPStrategy strategy_,
        LiquidityLauncher launcher_,
        IAllowanceTransfer permit2_,
        address positionManager_,
        address poolHook_,
        address[] memory bidders_,
        address stranger_
    ) {
        genesis = genesis_;
        token = genesis_.token();
        strategy = strategy_;
        launcher = launcher_;
        permit2 = permit2_;
        positionManager = positionManager_;
        poolHook = poolHook_;
        bidders = bidders_;
        stranger = stranger_;
    }

    /// @notice The auction of the current launch, or the zero address before one exists.
    function auction() public view returns (IContinuousClearingAuction) {
        return IContinuousClearingAuction(genesis.auction());
    }

    /// @notice How many bids the handler has opened.
    function bidCount() external view returns (uint256) {
        return bidIds.length;
    }

    // -----------------------------------------------------------------------------------------
    // Honest actions
    // -----------------------------------------------------------------------------------------

    /// @notice Places a bid inside the auction window.
    /// @param actorSeed Picks the bidder.
    /// @param amountSeed The currency committed.
    /// @param priceSeed How far above the floor the bidder is willing to go.
    function bid(uint256 actorSeed, uint256 amountSeed, uint256 priceSeed) external {
        IContinuousClearingAuction sale = auction();
        if (address(sale) == address(0)) return;
        LaunchParams memory p = genesis.launchParams();
        // A bid before the window opens is not an error, it is early: step into the window rather
        // than drop the call. Without this the run spends its depth on bids the auction refuses,
        // never graduates, and so never reaches the settlement and recovery paths at all — which is
        // how the first version of this suite passed while testing almost nothing.
        if (_blockNumber() < p.startBlock) _setBlock(uint256(p.startBlock) + 1);
        if (_blockNumber() >= p.endBlock) return;

        address bidder = bidders[actorSeed % bidders.length];
        uint128 amount = uint128(bound(amountSeed, 0.05 ether, 5 ether));
        uint256 price = p.floorPriceQ96 * bound(priceSeed, 2, 4000);
        price -= price % p.auctionTickSpacingQ96;

        vm.deal(bidder, amount);
        vm.prank(bidder);
        try sale.submitBid{value: amount}(price, amount, bidder, "") returns (uint256 id) {
            bidIds.push(id);
            bidsPlaced += 1;
        } catch {}
    }

    /// @notice Advances the auction clock and records a checkpoint. Permissionless in the auction.
    function checkpoint() external {
        IContinuousClearingAuction sale = auction();
        if (address(sale) == address(0)) return;
        try sale.checkpoint() {
            checkpoints += 1;
        } catch {}
    }

    /// @notice Moves the chain forward, which is the only way the window ever closes.
    /// @param blocksToRoll How far to move.
    function roll(uint32 blocksToRoll) external {
        uint256 step = bound(uint256(blocksToRoll), 1, 40_000);
        _setBlock(_blockNumber() + step);
    }

    /// @notice Jumps to the end of the auction window.
    /// @dev Without this the run has to random-walk tens of thousands of blocks before anything
    ///      after the auction is reachable at all, and the first version of this suite passed every
    ///      invariant having never once migrated, settled or recovered. A green suite that never
    ///      leaves the first state is the failure this file exists to avoid, so the later phases get
    ///      a door rather than a corridor.
    function rollToAuctionEnd() external {
        if (address(auction()) == address(0)) return;
        _setBlock(genesis.launchParams().endBlock);
    }

    /// @notice Carries the auction past graduation in one call, then closes the window.
    /// @dev Graduation needs a specific sequence — bid enough inside the window, roll to the end,
    ///      checkpoint — and a fuzzer picking eleven actions at random reaches it rarely and by
    ///      luck. Three consecutive runs of this suite reached one recovery, then none, then none,
    ///      which is a suite that reports whatever the seed felt like. One compound action makes the
    ///      interesting region reachable in a single draw, and every other action still explores
    ///      around it.
    function graduateTheAuction() external {
        IContinuousClearingAuction sale = auction();
        if (address(sale) == address(0)) return;
        LaunchParams memory p = genesis.launchParams();
        if (_blockNumber() >= p.endBlock) return;
        if (_blockNumber() < p.startBlock) _setBlock(uint256(p.startBlock) + 1);

        // Three times the graduation threshold, spread over three bidders, at a price high enough
        // that the clearing price never rises past it. A bidder pays the final clearing price, not
        // the maximum they named, so a generous maximum only keeps the bid alive.
        uint128 each = uint128(uint256(p.requiredCurrencyRaised));
        uint256 price = p.floorPriceQ96 * 1000;
        price -= price % p.auctionTickSpacingQ96;

        for (uint256 i = 0; i < bidders.length; ++i) {
            address bidder = bidders[i];
            vm.deal(bidder, each);
            vm.prank(bidder);
            try sale.submitBid{value: each}(price, each, bidder, "") returns (uint256 id) {
                bidIds.push(id);
                bidsPlaced += 1;
            } catch {}
        }

        _setBlock(p.endBlock);
        try sale.checkpoint() {
            checkpoints += 1;
        } catch {}
        _setBlock(p.migrationBlock);
    }

    /// @notice Jumps to the block the migration becomes possible at.
    function rollToMigrationBlock() external {
        if (address(auction()) == address(0)) return;
        _setBlock(genesis.launchParams().migrationBlock);
    }

    /// @notice Migrates through the strategy. Permissionless upstream.
    function migrate() external {
        IContinuousClearingAuction sale = auction();
        if (address(sale) == address(0)) return;
        try strategy.migrate(ILBPInitializer(address(sale))) {
            migrationsAttempted += 1;
        } catch {}
    }

    /// @notice Migrates with the position manager broken, which is the realistic shape of a failure.
    /// @dev The mock is cleared immediately, so only this one migration is affected.
    function migrateWithABrokenPositionManager() external {
        IContinuousClearingAuction sale = auction();
        if (address(sale) == address(0)) return;
        vm.mockCallRevert(
            positionManager,
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "position manager down"
        );
        try strategy.migrate(ILBPInitializer(address(sale))) {
            migrationsAttempted += 1;
            migrationsForcedToFail += 1;
        } catch {}
        vm.clearMockedCalls();
    }

    /// @notice Settles the leftover supply. Permissionless.
    function settle() external {
        try genesis.settle() {
            settlements += 1;
        } catch {}
    }

    /// @notice Rebuilds the pool after a failed migration. Permissionless.
    function recover() external {
        try genesis.recover() {
            recoveries += 1;
        } catch {}
    }

    /// @notice Starts the relaunch cooldown. Permissionless.
    function markFailed() external {
        try genesis.markFailed() {} catch {}
    }

    /// @notice Sweeps the auction's unsold supply, which only the vault may do.
    function claimBid(uint256 idSeed) external {
        if (bidIds.length == 0) return;
        uint256 id = bidIds[idSeed % bidIds.length];
        IContinuousClearingAuction sale = auction();
        address bidder = bidders[idSeed % bidders.length];
        vm.startPrank(bidder);
        try sale.exitBid(id) {} catch {}
        try sale.claimTokens(id) {} catch {}
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------------------------
    // The adversarial action
    // -----------------------------------------------------------------------------------------

    /// @notice A stranger registers their own distribution of KAY9 on the official pool key.
    /// @dev This is only possible once a failed migration has released the reservation, which is
    ///      exactly the window the 2026-09-16 defect lived in: the vault read the resulting pool as
    ///      proof that its own migration had succeeded, refused `recover` and stranded the raise.
    ///      The stranger's auction is tiny and graduates on its own terms.
    function strangerTakesTheOfficialKey(uint256 amountSeed) external {
        if (address(auction()) == address(0)) return;
        // Only possible once the key is unreserved, which is what a failed migration leaves behind.
        // Guarding on it is not only realistic, it stops this action from running its own auction —
        // and dragging the shared clock hundreds of blocks forward — on every call, which starved
        // the bid action of any window to bid in.
        if (strategy.registeredPoolIds(_officialPoolId()) != address(0)) return;
        uint128 total = uint128(bound(amountSeed, 2_000e18, 50_000e18));
        uint128 reserve = total / 10;
        if (reserve == 0) return;
        if (token.balanceOf(stranger) < total) {
            // A bidder holds KAY9 by this point in a real launch; this is the same supply.
            if (token.balanceOf(address(genesis)) < total) return;
            vm.prank(address(genesis));
            token.transfer(stranger, total);
        }

        LaunchParams memory p = genesis.launchParams();
        uint64 start = uint64(_blockNumber() + 10);
        uint64 end = start + 600;
        uint256 required = (p.floorPriceQ96 * uint256(total - reserve)) >> 96;
        if (required == 0) return;

        bytes memory configData = _strangerConfig(p, total, reserve, start, end, required);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(LiquidityLauncher.depositToken, (address(token), total));
        calls[1] = abi.encodeCall(
            LiquidityLauncher.distributeToken,
            (
                address(token),
                Distribution({strategy: address(strategy), amount: total, configData: configData}),
                bytes32(uint256(0xC0FFEE))
            )
        );

        vm.startPrank(stranger);
        IERC20(address(token)).approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(launcher), total, uint48(block.timestamp + 600));
        try launcher.multicall(calls) {}
        catch {
            vm.stopPrank();
            return;
        }
        vm.stopPrank();

        address theirs = strategy.registeredPoolIds(_officialPoolId());
        if (theirs == address(0) || theirs == address(auction())) return;

        uint128 bidAmount = uint128(required * 3);
        uint256 price = p.floorPriceQ96 * 1000;
        price -= price % p.auctionTickSpacingQ96;
        _setBlock(start + 300);
        vm.deal(stranger, bidAmount);
        vm.prank(stranger);
        try IContinuousClearingAuction(theirs).submitBid{value: bidAmount}(price, bidAmount, stranger, "") {}
        catch {
            return;
        }

        _setBlock(end);
        try IContinuousClearingAuction(theirs).checkpoint() {} catch {}
        _setBlock(end + 1);
        try strategy.migrate(ILBPInitializer(theirs)) {
            strangerPools += 1;
        } catch {}
    }

    // -----------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------

    /// @notice Builds the stranger's distribution, keyed exactly as the official pool is.
    function _strangerConfig(
        LaunchParams memory p,
        uint128 total,
        uint128 reserve,
        uint64 start,
        uint64 end,
        uint256 required
    ) private view returns (bytes memory) {
        PositionDefinition[] memory positions = new PositionDefinition[](1);
        positions[0] = PositionDefinition({
            offsetLower: -887272, offsetUpper: 887272, weight: 1e7, overridePositionRecipient: address(0)
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
            poolParameters: PoolParameters({fee: 10_000, tickSpacing: 200, hook: poolHook}),
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

        return abi.encode(mp, abi.encode(ap));
    }

    /// @notice The official pool id, derived the way the vault derives it.
    function _officialPoolId() private view returns (PoolId) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(poolHook)
        }).toId();
    }

    /// @notice The clock both the auction and the vault read.
    function _blockNumber() private view returns (uint256) {
        return vm.getBlockNumber();
    }

    /// @notice Moves that clock forward, never back.
    function _setBlock(uint256 target) private {
        if (target > vm.getBlockNumber()) vm.roll(target);
    }
}
