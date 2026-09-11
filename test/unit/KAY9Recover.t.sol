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

    /// @notice Runs a graduating auction and forces the strategy's migration to fail.
    /// @dev The failure is induced by making the PositionManager revert during the strategy's mint,
    ///      which is the only realistic shape of a migration failure: the pool initialization inside
    ///      tryMigrate is rolled back with it, so no pool exists afterwards.
    /// @return p The launch parameters.
    /// @return clearingPrice The auction's final clearing price.
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
