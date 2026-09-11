// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Pricing, PricingStatus} from "../../src/KAY9Pricing.sol";
import {MockV3Aggregator} from "../utils/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "../../src/interfaces/external/AggregatorV3Interface.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title KAY9PricingTest
/// @notice Covers the oracle safety checks, the conservatism rule and the worked price examples.
contract KAY9PricingTest is Kay9TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice The pool the oracle observes.
    PoolKey internal key;

    /// @notice One second of the default 1800 s window.
    uint32 internal constant WINDOW = 1800;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();
        key = _officialKey();
    }

    // -------------------------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------------------------

    /// @notice The pool can only be bound once, only by the owner, and only if it is the KAY9 pool.
    function test_configurePoolGuards() public {
        _seedPool(2_500_000e18);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        pricing.configurePool(key);

        PoolKey memory wrong = key;
        wrong.currency1 = key.currency0;
        vm.prank(address(timelock));
        vm.expectRevert(KAY9Pricing.NotTheKay9Pool.selector);
        pricing.configurePool(wrong);

        vm.prank(address(timelock));
        pricing.configurePool(key);
        assertTrue(pricing.poolConfigured());
        assertEq(pricing.observationCount(), 1, "configuring records the first sample");

        vm.prank(address(timelock));
        vm.expectRevert(KAY9Pricing.PoolAlreadyConfigured.selector);
        pricing.configurePool(key);
    }

    /// @notice An uninitialized pool is rejected.
    function test_configurePoolRejectsUninitialized() public {
        vm.prank(address(timelock));
        vm.expectRevert(KAY9Pricing.PoolNotInitialized.selector);
        pricing.configurePool(key);
    }

    /// @notice A pool at another fee or spacing is a different market and is refused, whoever
    ///         proposes it; the hookless recovery pool at the official fee and spacing is accepted.
    function test_configurePoolRejectsAnotherFeeOrSpacing() public {
        _seedPool(2_500_000e18);

        PoolKey memory wrongFee = key;
        wrongFee.fee = 3000;
        vm.prank(address(timelock));
        vm.expectRevert(KAY9Pricing.NotTheKay9Pool.selector);
        pricing.configurePool(wrongFee);

        PoolKey memory wrongSpacing = key;
        wrongSpacing.tickSpacing = 60;
        vm.prank(address(timelock));
        vm.expectRevert(KAY9Pricing.NotTheKay9Pool.selector);
        pricing.configurePool(wrongSpacing);

        assertEq(pricing.POOL_FEE(), 10_000, "the official fee");
        assertEq(pricing.POOL_TICK_SPACING(), int24(200), "the official spacing");

        // The pool `recover` builds differs only in its hook, and that is allowed.
        PoolKey memory hookless = _hooklessKey();
        uni.poolManager.initialize(hookless, TickMath.getSqrtPriceAtTick(0));
        vm.prank(address(timelock));
        pricing.configurePool(hookless);
        assertTrue(pricing.poolConfigured(), "the recovery pool binds");
    }

    /// @notice Parameter bounds are enforced.
    function test_setParamsBounds() public {
        vm.startPrank(address(timelock));
        vm.expectRevert(KAY9Pricing.InvalidParams.selector);
        pricing.setParams(60, 10, 300, 1e15, 5000, 90_000);
        vm.expectRevert(KAY9Pricing.InvalidParams.selector);
        pricing.setParams(9000, 10, 300, 1e15, 5000, 90_000);
        vm.expectRevert(KAY9Pricing.InvalidParams.selector);
        pricing.setParams(1800, 1, 300, 1e15, 5000, 90_000);
        vm.expectRevert(KAY9Pricing.InvalidParams.selector);
        pricing.setParams(1800, 10, 0, 1e15, 5000, 90_000);
        vm.expectRevert(KAY9Pricing.InvalidParams.selector);
        pricing.setParams(1800, 10, 300, 1e15, 10_001, 90_000);
        vm.expectRevert(KAY9Pricing.InvalidParams.selector);
        pricing.setParams(1800, 10, 300, 1e15, 5000, 86_399);
        pricing.setParams(3600, 20, 600, 1e16, 3000, 100_000);
        vm.stopPrank();
        assertEq(pricing.twapWindow(), 3600);
        assertEq(pricing.maxFeedAge(), 100_000);
    }

    // -------------------------------------------------------------------------------------------
    // Worked examples
    // -------------------------------------------------------------------------------------------

    /// @notice A KAY9 price of one tenth of a cent makes a deep access lock 100,000 KAY9.
    function test_workedExampleDeepAccessLock() public {
        // ETH is 2500 dollars, so KAY9 at 0.001 dollars means 2,500,000 KAY9 per ETH.
        _seedAndWarm(2_500_000e18);
        uint256 required = pricing.getDeepAccessRequirement();
        assertApproxEqRel(required, 100_000e18, 0.01e18, "one hundred dollars at 0.001 per KAY9");
        assertApproxEqRel(pricing.getKay9UsdPriceE8(), 0.001e8, 0.01e18, "KAY9 USD price");
    }

    /// @notice A KAY9 price of one cent makes a deep access lock 10,000 KAY9.
    function test_workedExampleDeepAccessLockAtOneCent() public {
        // KAY9 at 0.01 dollars means 250,000 KAY9 per ETH.
        _seedAndWarm(250_000e18);
        uint256 required = pricing.getDeepAccessRequirement();
        assertApproxEqRel(required, 10_000e18, 0.01e18, "one hundred dollars at 0.01 per KAY9");
    }

    /// @notice The forensic lock is five times the deep one, because its target is five times larger.
    function test_workedExampleForensicAccessLock() public {
        _seedAndWarm(2_500_000e18);
        uint256 deepRequired = pricing.getDeepAccessRequirement();
        uint256 forensicRequired = pricing.getForensicAccessRequirement();
        assertApproxEqRel(forensicRequired, 500_000e18, 0.01e18, "five hundred dollars at 0.001 per KAY9");
        // The two quotes are independent floor-rounded mulDivs, so they agree on the proportion to
        // within the few wei that rounding each one down can cost.
        assertApproxEqAbs(forensicRequired, deepRequired * 5, 10, "the two targets are in proportion");
        assertEq(pricing.usdTarget(1), DEEP_ACCESS_USD_E8, "the deep target is the constructor argument");
        assertEq(pricing.usdTarget(2), FORENSIC_ACCESS_USD_E8, "the forensic target is the second argument");
    }

    /// @notice A tier without a USD target cannot be priced.
    function test_inactiveTierReverts() public {
        _seedAndWarm(2_500_000e18);
        // The free tier has no target and never gets one.
        vm.expectRevert(abi.encodeWithSelector(KAY9Pricing.InactiveTier.selector, uint8(0)));
        pricing.getPriceInKay9(0);

        _governanceCall(address(pricing), abi.encodeCall(KAY9Pricing.setUsdTarget, (2, 0)));
        // The governance call warps past the observation window, so refill it before pricing again.
        _warmBuffer();
        vm.expectRevert(abi.encodeWithSelector(KAY9Pricing.InactiveTier.selector, uint8(2)));
        pricing.getForensicAccessRequirement();
    }

    // -------------------------------------------------------------------------------------------
    // Safety checks
    // -------------------------------------------------------------------------------------------

    /// @notice Before the pool is bound, the oracle reports failure code one.
    function test_failureNoPool() public {
        PricingStatus memory status = pricing.pricingStatus();
        assertFalse(status.available);
        assertEq(status.failureCode, 1);
        vm.expectRevert(abi.encodeWithSelector(KAY9Pricing.PricingUnavailable.selector, uint8(1)));
        pricing.getKay9UsdPriceE8();
    }

    /// @notice Too few samples inside the window makes the price unavailable.
    function test_failureTooFewObservations() public {
        _seedPool(2_500_000e18);
        vm.prank(address(timelock));
        pricing.configurePool(key);

        // Only five samples over the window: fewer than the required ten.
        for (uint256 i = 0; i < 5; ++i) {
            _advance(60);
            pricing.poke();
        }
        _advance(WINDOW);
        PricingStatus memory status = pricing.pricingStatus();
        assertEq(status.observationsInWindow, 0, "the window has drifted past every sample");
        assertEq(status.failureCode, 2, "too few observations");

        // Four more samples still leaves the window short of the required ten.
        for (uint256 i = 0; i < 4; ++i) {
            _advance(60);
            pricing.poke();
        }
        status = pricing.pricingStatus();
        assertFalse(status.available);
        assertEq(status.failureCode, 2);
    }

    /// @notice A gap wider than the tolerance makes the price unavailable.
    function test_failureGapTooLarge() public {
        _seedAndWarm(2_500_000e18);
        assertTrue(pricing.pricingStatus().available);

        _advance(pricing.maxObservationGap() + 1);
        PricingStatus memory status = pricing.pricingStatus();
        assertFalse(status.available);
        assertEq(status.failureCode, 3);
        vm.expectRevert(abi.encodeWithSelector(KAY9Pricing.PricingUnavailable.selector, uint8(3)));
        pricing.getDeepAccessRequirement();
    }

    /// @notice A window the samples do not span makes the price unavailable.
    function test_failureWindowNotCovered() public {
        _seedPool(2_500_000e18);
        vm.prank(address(timelock));
        pricing.configurePool(key);
        for (uint256 i = 0; i < 20; ++i) {
            _advance(30);
            pricing.poke();
        }
        PricingStatus memory status = pricing.pricingStatus();
        assertEq(status.failureCode, 7, "the buffer does not reach back a full window yet");
    }

    /// @notice Liquidity below the floor makes the price unavailable.
    function test_failureLowLiquidity() public {
        _seedAndWarm(2_500_000e18);
        uint128 liquidity = uni.poolManager.getLiquidity(key.toId());
        _governanceCall(
            address(pricing), abi.encodeCall(KAY9Pricing.setParams, (WINDOW, 10, 300, liquidity + 1, 5000, 90_000))
        );
        // The governance call warps 48 h, so refill the buffer before checking the liquidity gate.
        _warmBuffer();
        PricingStatus memory status = pricing.pricingStatus();
        assertFalse(status.available);
        assertEq(status.failureCode, 4);
    }

    /// @notice A stale Chainlink answer makes the price unavailable.
    function test_failureStaleFeed() public {
        _seedAndWarm(2_500_000e18);
        ethUsdFeed.updateAnswerAt(INITIAL_ETH_USD, vm.getBlockTimestamp() - pricing.maxFeedAge() - 1);
        PricingStatus memory status = pricing.pricingStatus();
        assertFalse(status.available);
        assertEq(status.failureCode, 5);
    }

    /// @notice A non-positive or incomplete Chainlink answer makes the price unavailable.
    function test_failureInvalidFeed() public {
        _seedAndWarm(2_500_000e18);
        ethUsdFeed.updateAnswer(0);
        assertEq(pricing.pricingStatus().failureCode, 6);

        ethUsdFeed.updateAnswer(INITIAL_ETH_USD);
        ethUsdFeed.setRounds(10, 9);
        assertEq(pricing.pricingStatus().failureCode, 6);
    }

    /// @notice A feed that reverts is treated as invalid rather than bricking the oracle.
    function test_failureRevertingFeed() public {
        _seedAndWarm(2_500_000e18);
        RevertingAggregator broken = new RevertingAggregator();
        _governanceCall(address(pricing), abi.encodeCall(KAY9Pricing.setFeed, (AggregatorV3Interface(address(broken)))));
        _warmBuffer();
        assertEq(pricing.pricingStatus().failureCode, 6);
    }

    // -------------------------------------------------------------------------------------------
    // Manipulation resistance
    // -------------------------------------------------------------------------------------------

    /// @notice A single-block spike barely moves the time-weighted average.
    function test_singleBlockSpikeBarelyMovesTwap() public {
        _seedAndWarm(2_500_000e18);
        uint256 twapBefore = pricing.pricingStatus().twapKay9PerEthE18;

        // A large buy inside one block, immediately observed.
        _buyKay9(20 ether);
        _advance(1);
        pricing.poke();

        PricingStatus memory status = pricing.pricingStatus();
        uint256 twapAfter = status.twapKay9PerEthE18;
        uint256 movedBps = twapBefore > twapAfter
            ? ((twapBefore - twapAfter) * 10_000) / twapBefore
            : ((twapAfter - twapBefore) * 10_000) / twapBefore;
        assertLt(movedBps, 100, "one block out of a 1800 s window moves the average by well under 1 %");
        assertLt(status.spotKay9PerEthE18, twapAfter, "the pump made KAY9 look expensive on spot");
    }

    /// @notice A pump cannot cheapen an audit, because the higher KAY9-per-ETH reading is used.
    function test_pumpCannotCheapenAudits() public {
        _seedAndWarm(2_500_000e18);
        uint256 priceBefore = pricing.getDeepAccessRequirement();

        _buyKay9(20 ether);
        _advance(1);
        pricing.poke();

        uint256 priceAfter = pricing.getDeepAccessRequirement();
        assertGe(priceAfter, (priceBefore * 99) / 100, "the pumped spot price is discarded");
    }

    /// @notice A dump cannot make an audit arbitrarily expensive, because spot is capped.
    function test_dumpIsCappedByMaxDeviation() public {
        _seedAndWarm(2_500_000e18);
        uint256 priceBefore = pricing.getDeepAccessRequirement();

        _sellKay9(40_000_000e18);
        _advance(1);
        pricing.poke();

        PricingStatus memory status = pricing.pricingStatus();
        assertGt(status.spotKay9PerEthE18, status.twapKay9PerEthE18, "the dump raised KAY9 per ETH on spot");

        uint256 priceAfter = pricing.getDeepAccessRequirement();
        uint256 cap = (priceBefore * (10_000 + pricing.maxDeviationBps())) / 10_000;
        assertLe(priceAfter, (cap * 101) / 100, "capped at the configured deviation");
    }

    // -------------------------------------------------------------------------------------------
    // Observation bookkeeping
    // -------------------------------------------------------------------------------------------

    /// @notice Only one observation is stored per block, and never faster than the sampling floor.
    function test_oneObservationPerBlock() public {
        _seedPool(2_500_000e18);
        vm.prank(address(timelock));
        pricing.configurePool(key);
        uint256 before = pricing.observationCount();
        pricing.poke();
        pricing.poke();
        pricing.poke();
        assertEq(pricing.observationCount(), before, "same block, no new sample");

        // A new block that arrives inside the sampling floor is still not recorded: at a 0.1 s
        // block cadence the floor is what stops the ring buffer being churned faster than the
        // averaging window.
        _advance(uint256(pricing.MIN_OBSERVATION_INTERVAL()) - 1);
        pricing.poke();
        assertEq(pricing.observationCount(), before, "inside the sampling floor, no new sample");

        _advance(1);
        pricing.poke();
        assertEq(pricing.observationCount(), before + 1);
    }

    /// @notice poke reverts cleanly when no pool has been bound.
    function test_pokeWithoutPool() public {
        vm.expectRevert(abi.encodeWithSelector(KAY9Pricing.PricingUnavailable.selector, uint8(1)));
        pricing.poke();
    }

    // -------------------------------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------------------------------

    /// @notice The price formula is the exact inverse of the USD price at any reasonable market.
    /// @param kay9PerEthWhole The KAY9-per-ETH price in whole tokens.
    /// @param ethUsdWhole The ETH price in whole dollars.
    function testFuzz_priceMathIsConsistent(uint256 kay9PerEthWhole, uint256 ethUsdWhole) public {
        kay9PerEthWhole = bound(kay9PerEthWhole, 1_000, 100_000_000);
        ethUsdWhole = bound(ethUsdWhole, 100, 100_000);

        _seedPool(kay9PerEthWhole * 1e18);
        vm.prank(address(timelock));
        pricing.configurePool(key);
        _warmBuffer();
        ethUsdFeed.updateAnswer(int256(ethUsdWhole * 1e8));

        PricingStatus memory status = pricing.pricingStatus();
        vm.assume(status.available);

        uint256 required = pricing.getDeepAccessRequirement();

        // The conservative reading is the higher KAY9-per-ETH value, with spot capped above the TWAP.
        uint256 cap = FullMath.mulDiv(status.twapKay9PerEthE18, 10_000 + pricing.maxDeviationBps(), 10_000);
        uint256 spot = status.spotKay9PerEthE18 > cap ? cap : status.spotKay9PerEthE18;
        uint256 effective = spot > status.twapKay9PerEthE18 ? spot : status.twapKay9PerEthE18;

        assertEq(
            required,
            FullMath.mulDiv(DEEP_ACCESS_USD_E8, effective, status.ethUsdE8),
            "the price is exactly usdTarget x kay9PerEth / ethUsd"
        );

        // The 1e8-scaled display price round-trips to the target within its own rounding.
        uint256 usdPriceE8 = pricing.getKay9UsdPriceE8();
        uint256 impliedUsdE8 = FullMath.mulDiv(required, usdPriceE8, 1e18);
        assertApproxEqRel(impliedUsdE8, DEEP_ACCESS_USD_E8, 0.05e18, "round trip within display rounding");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------
}

/// @notice A Chainlink aggregator that always reverts, used to prove the oracle degrades safely.
contract RevertingAggregator {
    /// @notice Always reverts.
    fallback() external {
        revert("feed down");
    }
}
