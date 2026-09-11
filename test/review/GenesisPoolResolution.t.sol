// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title GenesisPoolResolutionTest
/// @notice The vault must only ever report a pool it or the strategy actually created, and the
///         recovery path must never mint the raise at a price a stranger chose.
contract GenesisPoolResolutionTest is Kay9TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice A four-hour auction on the auction's own clock: 14,400 s at the chain's 0.1 s cadence.
    /// @dev The auction reads `ArbSys.arbBlockNumber()` through Uniswap's `BlockNumberish`, and so
    ///      does `KAY9Genesis`; neither reads `block.number`, which on this Orbit chain is the
    ///      parent chain's height. See the note on `KAY9Genesis.MIN_DURATION_BLOCKS`.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;
    uint160 internal constant ONE_TO_ONE = 79_228_162_514_264_337_593_543_950_336;

    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    /// @notice Before any migration the vault reports the official key and refuses to settle, even
    ///         when a lookalike hookless pool exists.
    function test_poolKeyIsTheOfficialKeyBeforeMigration() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        vm.prank(attacker);
        uni.poolManager.initialize(_hooklessKey(), ONE_TO_ONE);

        PoolKey memory key = genesis.poolKey();
        assertEq(address(key.hooks), address(uni.initializerHook), "official key");

        vm.roll(p.endBlock + 1);
        assertEq(genesis.launchState(), 4, "failed, not migrated");
        vm.expectRevert(KAY9Genesis.PoolNotReady.selector);
        genesis.settle();
    }

    /// @notice Recovery refuses to mint into a hookless pool a third party priced.
    function test_recoveryRefusesASquattedPoolPrice() public {
        (, uint256 clearingPrice) = _graduateThenFailMigration();

        uint160 expected = AuctionPriceLib.toSqrtPriceX96(clearingPrice, true);
        vm.prank(attacker);
        uni.poolManager.initialize(_hooklessKey(), ONE_TO_ONE);

        uint256 ethBefore = address(genesis).balance;
        vm.expectRevert(abi.encodeWithSelector(KAY9Genesis.RecoveryPoolPriceMismatch.selector, ONE_TO_ONE, expected));
        genesis.recover();
        assertEq(address(genesis).balance, ethBefore, "not a wei left the vault");
        assertFalse(genesis.recovered());
    }

    /// @notice A squatted recovery pool that already sits at the clearing price is used as is.
    function test_recoveryAcceptsASquattedPoolAtTheClearingPrice() public {
        (, uint256 clearingPrice) = _graduateThenFailMigration();
        uint160 expected = AuctionPriceLib.toSqrtPriceX96(clearingPrice, true);

        vm.prank(attacker);
        uni.poolManager.initialize(_hooklessKey(), expected);

        uint256 ethBefore = address(genesis).balance;
        genesis.recover();

        PoolKey memory key = genesis.poolKey();
        assertTrue(genesis.recovered(), "recovery recorded");
        assertEq(address(key.hooks), address(0), "the recovery pool is the hookless one");
        (uint160 sqrtPriceX96,,,) = uni.poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, expected, "priced by the auction, not by the squatter");
        assertLt(address(genesis).balance, ethBefore / 1000, "the raise went into the pool");
    }

    /// @notice Runs a graduating auction and forces the strategy's migration to fail.
    function _graduateThenFailMigration() internal returns (LaunchParams memory p, uint256 clearingPrice) {
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
