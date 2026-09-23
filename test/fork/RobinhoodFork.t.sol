// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IFeeSplitter} from "liquidity-launcher/src/interfaces/IFeeSplitter.sol";

import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {KAY9Token} from "../../src/KAY9Token.sol";
import {KAY9LiquidityLock} from "../../src/KAY9LiquidityLock.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {IBeneficiaryVault} from "../../src/interfaces/uniswap/IBeneficiaryVault.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/AggregatorV3Interface.sol";
import {ChainAddresses, RobinhoodAddresses} from "../../script/config/RobinhoodAddresses.sol";

/// @title RobinhoodForkTest
/// @notice Runs the real launch against the real canonical contracts on a fork of Robinhood Chain
///         mainnet. The suite skips itself when ROBINHOOD_RPC_URL is not set, so it never blocks a
///         local run.
/// @dev Robinhood Chain is an Arbitrum Orbit chain, so the launcher stack reads the auction clock
///      from the ArbSys precompile at address 0x64 rather than from `block.number`, and since
///      2026-09-11 so does `KAY9Genesis`. The suite models the two clocks the way the real chain
///      has them: `block.number` is pinned once to a parent-chain-like height and never moved, the
///      precompile is given code so `BlockNumberish` detects it at construction, and every time the
///      auction clock has to advance only `arbBlockNumber()` is mocked. A `KAY9Genesis` that still
///      read `block.number` anywhere would fail here, which is the regression this guards.
contract RobinhoodForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice The ArbSys precompile.
    address internal constant ARB_SYS = address(0x64);

    /// @notice The `arbBlockNumber()` selector.
    bytes4 internal constant ARB_BLOCK_NUMBER = 0xa3b1b31d;

    /// @notice A four-hour auction on the auction's own clock: 14,400 s at the chain's 0.1 s cadence.
    /// @dev The auction reads `ArbSys.arbBlockNumber()` through Uniswap's `BlockNumberish`, and so
    ///      does `KAY9Genesis`; neither reads `block.number`, which on this Orbit chain is the
    ///      parent chain's height. See the note on `KAY9Genesis.MIN_DURATION_BLOCKS`.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;

    /// @notice The floor valuation used for the rehearsal, in whole US dollars.
    uint256 internal constant FLOOR_FDV_USD = 1_000;

    /// @notice The graduation valuation used for the rehearsal, in whole US dollars.
    uint256 internal constant GRADUATION_FDV_USD = 10_000;

    /// @notice Whether the fork is available; every test returns early when it is not.
    bool internal enabled;

    /// @notice The canonical address book.
    ChainAddresses internal book;

    /// @notice The genesis vault under test.
    KAY9Genesis internal genesis;

    /// @notice The KAY9 token.
    KAY9Token internal token;

    /// @notice The liquidity lock.
    KAY9LiquidityLock internal lock;

    /// @notice The project owner stand-in.
    address internal owner = makeAddr("forkOwner");

    /// @notice The creator fee recipient stand-in.
    address internal creatorFeeRecipient = makeAddr("forkCreatorFeeRecipient");

    /// @notice The team beneficiary stand-in.
    address internal teamBeneficiary = makeAddr("forkTeamBeneficiary");

    /// @notice The live ETH/USD answer, scaled by 1e8.
    uint256 internal ethUsdE8;

    /// @notice The auction clock, tracked so it can be pushed into the ArbSys mock.
    uint64 internal currentBlock;

    /// @notice A parent-chain-like `block.number`, deliberately far below the auction clock.
    /// @dev 25,951,849 was `Multicall3.getBlockNumber()` on mainnet on 2026-09-11, while ArbSys
    ///      answered 59,983,529. The gap is what the earlier, wrong revision of the vault was blind to.
    uint64 internal constant PARENT_CHAIN_BLOCK = 25_951_849;

    /// @notice Sets up the fork and deploys the genesis vault against the canonical addresses.
    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        uint256 pinned = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pinned == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pinned);
        }
        if (block.chainid != RobinhoodAddresses.MAINNET_CHAIN_ID) return;
        enabled = true;

        book = RobinhoodAddresses.mainnet();
        _assertHasCode(book.poolManager, "PoolManager");
        _assertHasCode(book.positionManager, "PositionManager");
        _assertHasCode(book.permit2, "Permit2");
        _assertHasCode(book.liquidityLauncher, "LiquidityLauncher");
        _assertHasCode(book.lbpStrategy, "LBPStrategy");
        _assertHasCode(book.initializerHook, "InitializerHook");
        _assertHasCode(book.auctionFactory, "CCA factory");
        _assertHasCode(book.feeSplitter, "FeeSplitter");
        _assertHasCode(book.beneficiaryVault, "BeneficiaryVault");
        _assertHasCode(book.ethUsdFeed, "Chainlink ETH/USD");

        (, int256 answer,,,) = AggregatorV3Interface(book.ethUsdFeed).latestRoundData();
        assertGt(answer, 0, "live ETH/USD answer");
        ethUsdE8 = uint256(answer);

        currentBlock = uint64(_arbBlockNumber());
        // Give the precompile code so `BlockNumberish` constructors detect ArbSys the way they do
        // on the real chain, then pin `block.number` to a parent-chain-like height that never moves.
        vm.etch(ARB_SYS, hex"fe");
        _setBlock(currentBlock);
        vm.roll(PARENT_CHAIN_BLOCK);

        genesis = new KAY9Genesis(
            owner,
            teamBeneficiary,
            uint64(block.timestamp),
            uint64(block.timestamp + 182 days),
            uint64(block.timestamp + 365 days),
            creatorFeeRecipient,
            book.liquidityLauncher,
            book.lbpStrategy,
            book.positionManager,
            book.poolManager,
            book.permit2,
            book.feeSplitter,
            book.beneficiaryVault,
            book.initializerHook
        );
        token = genesis.token();
        lock = genesis.liquidityLock();
    }

    // -------------------------------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------------------------------

    /// @notice The full launch, migration, lock, settlement and fee-collection cycle on mainnet code.
    function test_fork_fullLaunchCycle() public {
        if (!enabled) return;

        LaunchParams memory p = _params();
        (address predicted,,) = genesis.previewLaunch(p);

        vm.prank(owner);
        genesis.launch(p);
        assertEq(genesis.auction(), predicted, "the canonical factory deployed where we predicted");

        IContinuousClearingAuction auction = IContinuousClearingAuction(predicted);
        assertEq(auction.tokensRecipient(), address(genesis));
        assertEq(auction.fundsRecipient(), book.lbpStrategy);
        assertEq(token.balanceOf(predicted), genesis.AUCTION_ALLOCATION());

        _runBiddingToGraduation(auction, p);

        _setBlock(p.migrationBlock);
        vm.prank(makeAddr("anyone"));
        (bool migrated,) = book.lbpStrategy.call(abi.encodeWithSignature("migrate(address)", address(auction)));
        assertTrue(migrated, "migration call succeeded");
        assertEq(genesis.launchState(), 3, "migrated");
        assertEq(block.number, PARENT_CHAIN_BLOCK, "block.number never moved, and nothing needed it to");

        PoolKey memory key = genesis.poolKey();
        (uint160 sqrtPriceX96,,,) = IPoolManager(book.poolManager).getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "pool initialized");
        assertEq(key.fee, 10_000, "one percent");
        assertEq(key.tickSpacing, int24(200), "tick spacing 200");
        assertEq(Currency.unwrap(key.currency0), address(0), "native ETH is currency0");
        assertEq(Currency.unwrap(key.currency1), address(token), "KAY9 is currency1");
        assertEq(address(key.hooks), book.initializerHook, "keyed on the canonical initializer hook");

        // Nobody but the strategy can create a pool keyed on this hook: the same key with a
        // different spacing has never been touched, and initializing it is still refused.
        vm.prank(makeAddr("squatter"));
        vm.expectRevert();
        IPoolManager(book.poolManager)
            .initialize(
                PoolKey({
                    currency0: Currency.wrap(address(0)),
                    currency1: Currency.wrap(address(token)),
                    fee: 10_000,
                    tickSpacing: 100,
                    hooks: IHooks(book.initializerHook)
                }),
                sqrtPriceX96
            );

        uint256 migrationTokenId = IPositionManager(book.positionManager).nextTokenId() - 1;
        assertEq(IERC721(book.positionManager).ownerOf(migrationTokenId), address(lock), "LP NFT reached the lock");

        lock.lock(migrationTokenId);
        assertEq(IERC721(book.positionManager).ownerOf(migrationTokenId), book.feeSplitter, "LP NFT is irrecoverable");
        assertEq(
            IBeneficiaryVault(book.beneficiaryVault).ownerOf(migrationTokenId),
            creatorFeeRecipient,
            "beneficiary NFT minted to the creator fee recipient"
        );

        genesis.settle();
        assertTrue(genesis.settled(), "settled");
        assertLt(token.balanceOf(address(genesis)), genesis.DUST_THRESHOLD(), "genesis holds at most dust");
        // The strategy forwards its leftover ETH dust to the vault. There is deliberately no
        // withdrawal path, so that dust stays frozen forever rather than becoming an owner power.
        assertLt(address(genesis).balance, 0.001 ether, "at most ETH dust remains, and it is frozen");

        uint256 settleTokenId = IPositionManager(book.positionManager).nextTokenId() - 1;
        assertEq(IERC721(book.positionManager).ownerOf(settleTokenId), book.feeSplitter, "unsold supply locked");

        // Trade through the pool so fees accrue, then collect and distribute them.
        PoolSwapTest router = new PoolSwapTest(IPoolManager(book.poolManager));
        address trader = makeAddr("forkTrader");
        vm.deal(trader, 5 ether);
        vm.prank(trader);
        router.swap{value: 2 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -2 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256[] memory ids = new uint256[](1);
        ids[0] = migrationTokenId;
        uint256 vaultBefore = book.beneficiaryVault.balance;
        IFeeSplitter(book.feeSplitter).collectFees(ids);
        assertGt(book.beneficiaryVault.balance, vaultBefore, "40 % of native fees reached the vault");

        console2.log("fork launch cycle complete at block", currentBlock);
    }

    // -------------------------------------------------------------------------------------------
    // Failure paths
    // -------------------------------------------------------------------------------------------

    /// @notice An auction that does not reach its graduation threshold returns everything.
    function test_fork_nonGraduation() public {
        if (!enabled) return;

        LaunchParams memory p = _params();
        vm.prank(owner);
        genesis.launch(p);
        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());

        _setBlock(p.endBlock + 1);
        auction.checkpoint();
        assertFalse(auction.isGraduated());
        assertEq(genesis.launchState(), 4, "failed");

        _setBlock(p.migrationBlock);
        (bool ok,) = book.lbpStrategy.call(abi.encodeWithSignature("migrate(address)", address(auction)));
        assertTrue(ok, "migrate ran the recovery branch");

        genesis.markFailed();
        assertGt(genesis.earliestRelaunchTimestamp(), 0);
        assertEq(token.balanceOf(address(genesis)), genesis.LIQUIDITY_RESERVE(), "reserve returned");

        // The relaunch itself, on the canonical stack, with the owner-facing salt unchanged: what
        // the testnet relaunch of 2026-09-23 does. The strategy salts the auction with the
        // migration parameters as well, so a later window is a new address; the recovery branch
        // above freed the pool id; and `launch()` sweeps the failed auction before it checks the
        // balance, so the whole 910 M is back in the vault when the second distribution starts.
        vm.warp(genesis.earliestRelaunchTimestamp());
        LaunchParams memory p2 = _params();
        assertEq(p2.salt, p.salt, "same owner-facing salt");
        vm.prank(owner);
        genesis.launch(p2);

        assertEq(genesis.launchCount(), 2, "relaunched");
        assertEq(genesis.launchState(), 1, "the new auction is live");
        assertTrue(genesis.auction() != address(auction), "a new auction");
        assertEq(token.balanceOf(address(genesis)), 0, "the whole allocation moved again");
        assertEq(token.balanceOf(address(auction)), 0, "the failed auction was swept");
        assertEq(token.balanceOf(book.lbpStrategy), genesis.LIQUIDITY_RESERVE(), "one reserve, not two");
    }

    /// @notice A graduated auction whose migration reverts is rebuilt by the vault itself.
    function test_fork_recoverAfterFailedMigration() public {
        if (!enabled) return;

        LaunchParams memory p = _params();
        vm.prank(owner);
        genesis.launch(p);
        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());

        _runBiddingToGraduation(auction, p);
        uint256 clearingPrice = auction.clearingPrice();

        _setBlock(p.migrationBlock);
        vm.mockCallRevert(
            book.positionManager, abi.encodeWithSelector(IPositionManager.modifyLiquidities.selector), "down"
        );
        (bool ok,) = book.lbpStrategy.call(abi.encodeWithSignature("migrate(address)", address(auction)));
        assertTrue(ok);
        // clearMockedCalls also drops the ArbSys clock mock, and without it the auction reads a clock
        // that is not past its end, so its sweep reverts AuctionIsNotOver. Before UnsoldNotSwept the
        // vault swallowed that and recovered without sweeping, which this test never noticed.
        vm.clearMockedCalls();
        _setBlock(p.migrationBlock);

        uint256 ethBefore = address(genesis).balance;
        assertGt(ethBefore, 0, "the raise landed in the vault");
        genesis.recover();

        PoolKey memory key = genesis.poolKey();
        assertTrue(genesis.recovered(), "recovery flag set");
        assertEq(address(key.hooks), address(0), "recovery rebuilds the hookless pool");
        (uint160 sqrtPriceX96,,,) = IPoolManager(book.poolManager).getSlot0(key.toId());
        assertEq(sqrtPriceX96, AuctionPriceLib.toSqrtPriceX96(clearingPrice, true), "priced at the clearing price");
        assertLe(address(genesis).balance, 1, "at most one wei of rounding stays behind");
        assertTrue(genesis.settled());
        // What stays in the auction is what bidders bought and have not claimed yet; the unsold part
        // has been swept.
        assertGt(auction.sweepUnsoldTokensBlock(), 0, "the unsold supply was swept");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Builds realistic launch parameters against the live ETH price.
    /// @return p The launch parameters.
    function _params() internal view returns (LaunchParams memory p) {
        uint64 startBlock = currentBlock + 6_000;
        uint64 endBlock = startBlock + FOUR_HOURS_BLOCKS;

        uint256 floorFdvWei = (FLOOR_FDV_USD * 1e18 * 1e8) / ethUsdE8;
        uint256 graduationFdvWei = (GRADUATION_FDV_USD * 1e18 * 1e8) / ethUsdE8;

        uint256 rawFloor = AuctionPriceLib.fdvWeiToPriceQ96(floorFdvWei, token.TOTAL_SUPPLY());
        uint256 tickSpacing = rawFloor / 100;
        uint256 floorPrice = rawFloor - (rawFloor % tickSpacing);

        uint256 graduationPrice = AuctionPriceLib.fdvWeiToPriceQ96(graduationFdvWei, token.TOTAL_SUPPLY());
        uint256 required = (graduationPrice * genesis.AUCTION_ALLOCATION()) >> 96;

        p = LaunchParams({
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: endBlock,
            migrationBlock: endBlock + 1,
            floorPriceQ96: floorPrice,
            auctionTickSpacingQ96: tickSpacing,
            requiredCurrencyRaised: uint128(required),
            auctionStepsData: AuctionSteps.convexSchedule(startBlock, endBlock),
            salt: keccak256("KAY9 fork rehearsal")
        });
    }

    /// @notice Runs a bidding sequence that carries the auction past its graduation threshold.
    /// @dev Three bidders arrive across the window, each willing to pay four times whatever the
    ///      book has already cleared to, which is how a real contested auction behaves.
    /// @param auction The auction.
    /// @param p The launch parameters.
    function _runBiddingToGraduation(IContinuousClearingAuction auction, LaunchParams memory p) internal {
        uint128 each = uint128(uint256(p.requiredCurrencyRaised));

        _setBlock(p.startBlock + FOUR_HOURS_BLOCKS / 4);
        _bidAboveClearing(auction, p, makeAddr("forkAlice"), each);

        _setBlock(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        _bidAboveClearing(auction, p, makeAddr("forkBob"), each);

        _setBlock(p.endBlock - 1);
        _bidAboveClearing(auction, p, makeAddr("forkCarol"), each);

        _setBlock(p.endBlock);
        auction.checkpoint();
        assertTrue(auction.isGraduated(), "graduated");
    }

    /// @notice Places a bid four ticks-worth above whatever the auction has cleared to so far.
    /// @param auction The auction.
    /// @param p The launch parameters, for the tick grid and the floor.
    /// @param bidder The bidder.
    /// @param amount The ETH committed.
    function _bidAboveClearing(
        IContinuousClearingAuction auction,
        LaunchParams memory p,
        address bidder,
        uint128 amount
    ) internal {
        auction.checkpoint();
        uint256 cleared = auction.clearingPrice();
        uint256 base = cleared > p.floorPriceQ96 ? cleared : p.floorPriceQ96;
        uint256 price = base * 4;
        price -= price % p.auctionTickSpacingQ96;
        _bid(auction, bidder, price, amount);
    }

    /// @notice Places one bid.
    /// @param auction The auction.
    /// @param bidder The bidder.
    /// @param priceQ96 The bid price, already snapped to the tick grid.
    /// @param amount The ETH committed.
    function _bid(IContinuousClearingAuction auction, address bidder, uint256 priceQ96, uint128 amount) internal {
        vm.deal(bidder, amount);
        vm.prank(bidder);
        auction.submitBid{value: amount}(priceQ96, amount, bidder, "");
    }

    /// @notice Moves the ArbSys clock the launcher stack and the vault read. `block.number` stays
    ///         pinned at the parent-chain height, exactly as on the real chain.
    /// @param blockNumber The new height.
    function _setBlock(uint64 blockNumber) internal {
        currentBlock = blockNumber;
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(ARB_BLOCK_NUMBER), abi.encode(uint256(blockNumber)));
        assertEq(uint256(genesisClock()), uint256(blockNumber), "the vault reads the auction clock");
    }

    /// @notice The clock the vault reads, or the mocked clock before the vault exists.
    function genesisClock() internal view returns (uint256) {
        if (address(genesis) == address(0)) return _arbBlockNumber();
        return genesis.chainBlockNumber();
    }

    /// @notice Reads the ArbSys height from the fork.
    /// @return The height.
    function _arbBlockNumber() internal view returns (uint256) {
        (bool ok, bytes memory data) = ARB_SYS.staticcall(abi.encodeWithSelector(ARB_BLOCK_NUMBER));
        if (!ok || data.length != 32) return block.number;
        return abi.decode(data, (uint256));
    }

    /// @notice Asserts that a canonical address actually has code on the fork.
    /// @param target The address.
    /// @param name The name used in the failure message.
    function _assertHasCode(address target, string memory name) internal view {
        assertGt(target.code.length, 0, name);
    }
}
