// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickRange} from "../../src/libraries/TickRange.sol";

/// @notice Repairs a squatted recovery pool's price and recovers in the same call, the way a
///         keeper would, so nobody can move the price again in between.
contract RepairAndRecover {
    PoolSwapTest internal immutable ROUTER;
    KAY9Genesis internal immutable GENESIS;

    constructor(PoolSwapTest router, KAY9Genesis genesis_) {
        ROUTER = router;
        GENESIS = genesis_;
    }

    function run(PoolKey memory key, uint160 target) external {
        ROUTER.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        GENESIS.recover();
    }

    receive() external payable {}
}

/// @title KAY9RecoverTest
/// @notice Covers the path where the auction graduates but the strategy's migration reverts, so the
///         genesis vault has to build the pool itself.
contract KAY9RecoverTest is Kay9TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice A four-hour auction on the auction's own clock: 14,400 s at the chain's 0.1 s cadence.
    /// @dev The auction reads `ArbSys.arbBlockNumber()` through Uniswap's `BlockNumberish`, and so
    ///      does `KAY9Genesis`; neither reads `block.number`, which on this Orbit chain is the
    ///      parent chain's height. See the note on `KAY9Genesis.MIN_DURATION_BLOCKS`.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;

    /// @notice A one-thousand-dollar floor valuation, expressed in wei at 2500 dollars per ETH.
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;

    /// @notice A bidder.
    address internal alice = makeAddr("alice");

    /// @notice Recovery rebuilds the pool at the clearing price and locks the position.
    function test_recoverAfterFailedMigration() public {
        (LaunchParams memory p, uint256 clearingPrice) = _graduateThenFailMigration();

        assertEq(genesis.launchState(), 4, "failed");
        assertGt(address(genesis).balance, 0, "the raise landed in the vault");
        assertGt(token.balanceOf(address(genesis)), 0, "the reserve came back too");

        uint256 ethBefore = address(genesis).balance;
        genesis.recover();

        PoolKey memory key = genesis.poolKey();
        (uint160 sqrtPriceX96,,,) = uni.poolManager.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "pool built by the vault");
        assertEq(sqrtPriceX96, AuctionPriceLib.toSqrtPriceX96(clearingPrice, true), "priced at the clearing price");
        assertEq(key.fee, 10_000);
        assertEq(key.tickSpacing, int24(200));

        assertLt(address(genesis).balance, ethBefore / 1000, "essentially all ETH went into the pool");
        assertLt(token.balanceOf(address(genesis)), genesis.DUST_THRESHOLD(), "at most dust left");
        assertTrue(genesis.settled(), "the remainder was settled in the same call");

        uint256 fullRangeId = lock.lockedTokenIds(0);
        assertTrue(lock.isLocked(fullRangeId));
        assertEq(IERC721(address(uni.positionManager)).ownerOf(fullRangeId), address(uni.feeSplitter));
        assertEq(uni.beneficiaryVault.ownerOf(fullRangeId), creatorFeeRecipient);

        assertEq(genesis.launchState(), 3, "the launch now reads as migrated");
        assertGt(p.migrationBlock, 0);
    }

    /// @notice Recovery sweeps the auction's unsold supply too. Only this contract can sweep it,
    ///         and recovery is the last call that settles the launch, so a recovery that forgot the
    ///         sweep would strand those tokens in the auction forever.
    function test_recoverSweepsUnsoldSupply() public {
        // Graduate on a quarter of the default threshold with a bid that buys half of the supply
        // at the floor, so half of the auction supply is genuinely unsold.
        _graduateThenFailMigration(4, 2);
        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());

        uint256 unsold = auction.remainingSupply();
        uint256 auctionBalanceBefore = token.balanceOf(address(auction));
        assertGt(unsold, genesis.DUST_THRESHOLD(), "the bid left a real unsold remainder in the auction");
        assertEq(auction.sweepUnsoldTokensBlock(), 0, "nothing swept before recovery");

        genesis.recover();

        assertGt(auction.sweepUnsoldTokensBlock(), 0, "recovery swept the unsold supply");
        assertEq(
            auctionBalanceBefore - token.balanceOf(address(auction)),
            unsold,
            "the auction kept only what bidders have yet to claim"
        );
        assertLt(token.balanceOf(address(genesis)), genesis.DUST_THRESHOLD(), "and the vault placed it");
        assertTrue(genesis.settled());
        assertEq(lock.lockedCount(), 2, "full-range recovery position plus the single-sided remainder");
    }

    /// @notice Recovery cannot run twice and cannot run on a healthy launch.
    function test_recoverGuards() public {
        _graduateThenFailMigration();
        genesis.recover();
        vm.expectRevert(KAY9Genesis.NothingToRecover.selector);
        genesis.recover();
    }

    /// @notice Recovery is refused while migration has not been attempted.
    function test_recoverBeforeMigration() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);
        vm.expectRevert(KAY9Genesis.NothingToRecover.selector);
        genesis.recover();
    }

    /// @notice Recovery is refused after a non-graduated auction, where there is no ETH to place.
    function test_recoverRefusedWithoutGraduation() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        vm.expectRevert(KAY9Genesis.NothingToRecover.selector);
        genesis.recover();
    }

    /// @notice A squatter who initializes the recovery pool at the wrong price delays recovery by
    ///         one swap, and no more.
    /// @dev `recover` refuses any price but the auction's, which is what stops a stranger choosing
    ///      the price the whole raise is minted at. The question that leaves is whether refusing can
    ///      be made permanent. It cannot while the squatted pool is empty: a swap that fills nothing
    ///      moves an empty pool's price to any limit it is given, so anyone can put it back.
    function test_recoveryOutlastsAnEmptySquattedPool() public {
        (, uint256 clearingPrice) = _graduateThenFailMigration();
        uint160 target = AuctionPriceLib.toSqrtPriceX96(clearingPrice, true);
        PoolKey memory key = _hooklessKey();

        // The squatter gets there first, at a price of their choosing.
        uint160 squatted = target * 2;
        uni.poolManager.initialize(key, squatted);

        vm.expectRevert(abi.encodeWithSelector(KAY9Genesis.RecoveryPoolPriceMismatch.selector, squatted, target));
        genesis.recover();
        assertGt(address(genesis).balance, 0, "the raise is still in the vault, untouched");

        // Anyone walks the empty pool back. With no liquidity the swap trades nothing.
        uint256 ethBefore = address(this).balance;
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(address(this).balance, ethBefore, "moving an empty pool costs nothing but gas");
        (uint160 repaired,,,) = uni.poolManager.getSlot0(key.toId());
        assertEq(repaired, target, "the price is the auction's again");

        genesis.recover();
        assertTrue(genesis.settled(), "recovery went through");
        assertLt(token.balanceOf(address(genesis)), genesis.DUST_THRESHOLD());
    }

    /// @notice A squatter who also funds the wrong-priced pool makes the repair cost money, and
    ///         recovery still completes once somebody pays it.
    /// @dev The repair trades against the squatter's own liquidity, so what it costs the repairer
    ///      is bounded by what the squatter put in, and the squatter's position takes the other
    ///      side of that trade at a price they chose wrongly. The exit is never closed.
    function test_recoveryOutlastsAFundedSquattedPool() public {
        (, uint256 clearingPrice) = _graduateThenFailMigration();
        uint160 target = AuctionPriceLib.toSqrtPriceX96(clearingPrice, true);
        PoolKey memory key = _hooklessKey();

        // Twice the square-root price: KAY9 at a quarter of its auction price in ETH terms.
        uni.poolManager.initialize(key, target * 2);
        address squatter = makeAddr("squatter");
        _fundKay9FromAuctionWinner(squatter, 1_000e18);
        vm.deal(squatter, 1 ether);
        vm.startPrank(squatter);
        token.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{value: 1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickRange.minUsableTick(200),
                tickUpper: TickRange.maxUsableTick(200),
                liquidityDelta: 1e15,
                salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();

        vm.expectRevert();
        genesis.recover();

        // The price has to fall back to the target, which means selling ETH into the pool.
        vm.deal(address(this), address(this).balance + 10 ether);
        swapRouter.swap{value: 10 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint160 repaired,,,) = uni.poolManager.getSlot0(key.toId());
        assertEq(repaired, target, "the swap stopped exactly at the auction's price");

        genesis.recover();
        assertTrue(genesis.settled(), "recovery went through");
    }

    /// @notice A front-runner who moves the price again between the repair and the recovery only
    ///         makes that one transaction revert, which is why the two belong in one transaction.
    function test_repairAndRecoveryInOneCallCannotBeSplit() public {
        (, uint256 clearingPrice) = _graduateThenFailMigration();
        uint160 target = AuctionPriceLib.toSqrtPriceX96(clearingPrice, true);
        PoolKey memory key = _hooklessKey();
        uni.poolManager.initialize(key, target * 2);

        RepairAndRecover helper = new RepairAndRecover(swapRouter, genesis);
        helper.run(key, target);

        assertTrue(genesis.settled(), "one call repaired the price and recovered");
    }

    /// @notice The owner has no way to take the recovered ETH out of the vault.
    function test_ownerCannotTouchRecoveredEth() public {
        _graduateThenFailMigration();
        uint256 balance = address(genesis).balance;
        assertGt(balance, 0);

        string[5] memory signatures = [
            "withdraw()", "withdraw(uint256)", "sweep(address)", "rescueEth(address)", "execute(address,uint256,bytes)"
        ];
        for (uint256 i = 0; i < signatures.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(genesis)
                .call(abi.encodeWithSelector(bytes4(keccak256(bytes(signatures[i]))), owner, balance, bytes("")));
            assertFalse(ok, signatures[i]);
        }
        assertEq(address(genesis).balance, balance);
    }

    /// @notice Gives an account KAY9 the way a real holder gets it after a failed migration: out of
    ///         the vault's returned reserve, which is the only KAY9 in existence outside the auction.
    function _fundKay9FromAuctionWinner(address to, uint256 amount) internal {
        vm.prank(address(genesis));
        token.transfer(to, amount);
    }

    /// @notice Runs a graduating auction and forces the strategy's migration to fail.
    /// @dev The failure is induced by making the PositionManager revert during the strategy's mint,
    ///      which is the only realistic shape of a migration failure: the pool initialization inside
    ///      tryMigrate is rolled back with it, so no pool exists afterwards.
    /// @return p The launch parameters.
    /// @return clearingPrice The auction's final clearing price.
    function _graduateThenFailMigration() internal returns (LaunchParams memory p, uint256 clearingPrice) {
        return _graduateThenFailMigration(1, 3);
    }

    /// @param requiredDivisor Divides the default graduation threshold, so a bid can graduate the
    ///        auction while filling only part of the supply and leave a real unsold remainder.
    /// @param bidMultiplier How many times the (divided) threshold the single bid commits.
    function _graduateThenFailMigration(uint128 requiredDivisor, uint256 bidMultiplier)
        internal
        returns (LaunchParams memory p, uint256 clearingPrice)
    {
        p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p.requiredCurrencyRaised = p.requiredCurrencyRaised / requiredDivisor;
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        uint128 amount = uint128(uint256(p.requiredCurrencyRaised) * bidMultiplier);
        uint256 price = p.floorPriceQ96 * 8;
        price -= price % p.auctionTickSpacingQ96;

        vm.roll(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        vm.deal(alice, amount);
        vm.prank(alice);
        auction.submitBid{value: amount}(price, amount, alice, "");

        vm.roll(p.endBlock);
        auction.checkpoint();
        assertTrue(auction.isGraduated());
        clearingPrice = auction.clearingPrice();

        vm.roll(p.migrationBlock);
        vm.mockCallRevert(
            address(uni.positionManager),
            abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector),
            "position manager down"
        );
        uni.lbpStrategy.migrate(ILBPInitializer(address(auction)));
        vm.clearMockedCalls();
    }
}
