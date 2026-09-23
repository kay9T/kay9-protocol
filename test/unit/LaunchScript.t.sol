// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {Launch} from "../../script/Launch.s.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";

/// @notice A Chainlink-shaped feed whose every answer is set by the test.
/// @dev The launch economics are derived from one reading of one of these and are permanent once
///      signed, so what matters here is not that the arithmetic inverts — `test_impliedValuations`
///      already shows that, using the same scale on both sides — but that a reading the script
///      should not accept is refused before the arithmetic ever runs.
contract MockFeed {
    uint8 public decimals = 8;
    int256 public answer = 2500e8;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    uint256 public updatedAt;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function setAnswer(int256 value) external {
        answer = value;
    }

    function setUpdatedAt(uint256 value) external {
        updatedAt = value;
    }

    function setRounds(uint80 round, uint80 answered) external {
        roundId = round;
        answeredInRound = answered;
    }

    function description() external pure returns (string memory) {
        return "ETH / USD";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}

/// @notice Exposes the script's feed reader, which is where a bad reading has to be stopped.
contract LaunchHarness is Launch {
    function ethUsd(address feed) external view returns (uint256) {
        return _ethUsd(feed);
    }
}

/// @title LaunchScriptTest
/// @notice Proves that the parameters the launch script derives from human inputs are exactly the
///         parameters the genesis vault accepts, so the owner Safe never signs calldata that would
///         revert.
contract LaunchScriptTest is Kay9TestBase {
    /// @notice The script under test.
    Launch internal script;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();
        script = new Launch();
    }

    /// @notice A four-hour, thousand-dollar-floor launch derives parameters the vault accepts.
    function test_derivedParamsAreAccepted() public {
        LaunchParams memory p = script.derive(genesis, 1_000, 10_000, 4, 30, bytes32(uint256(1)), 2500e8);

        assertEq(p.endBlock - p.startBlock, 144_000, "four hours at 0.1 s per block on the auction's clock");
        assertEq(p.startBlock, uint64(block.number + 18_000), "thirty minutes of lead time, 1,800 s / 0.1 s");
        assertEq(p.claimBlock, p.endBlock);
        assertEq(p.migrationBlock, p.endBlock + 1);
        assertEq(p.floorPriceQ96 % p.auctionTickSpacingQ96, 0, "the floor sits on a tick boundary");
        assertGt(p.requiredCurrencyRaised, 0);

        (uint256 totalMps, uint64 totalBlocks, uint256 steps) = AuctionSteps.totals(p.auctionStepsData);
        assertEq(totalMps, 1e7);
        assertEq(totalBlocks, p.endBlock - p.startBlock);
        assertEq(steps, 13);

        // The vault accepts them, which is the property that actually matters.
        vm.prank(owner);
        genesis.launch(p);
        assertEq(genesis.launchCount(), 1);
    }

    /// @notice The implied valuations match the dollar inputs at the supplied ETH price.
    function test_impliedValuations() public {
        uint256 ethUsdE8 = 2500e8;
        LaunchParams memory p = script.derive(genesis, 1_000, 10_000, 4, 30, bytes32(uint256(1)), ethUsdE8);

        uint256 impliedFloorWei = AuctionPriceLib.impliedFdvWei(p.floorPriceQ96, token.TOTAL_SUPPLY());
        uint256 impliedFloorUsd = (impliedFloorWei * ethUsdE8) / 1e18 / 1e8;
        assertApproxEqAbs(impliedFloorUsd, 1_000, 1, "a thousand dollar floor valuation");

        // The graduation threshold is the ETH needed to clear the auction supply at 10,000 dollars.
        uint256 expected = (10_000 * 1e18 * 1e8) / ethUsdE8;
        expected = (expected * 455) / 1000;
        assertApproxEqRel(uint256(p.requiredCurrencyRaised), expected, 0.01e18, "graduation raise");
    }

    /*
     * The feed boundary.
     *
     * `test_impliedValuations` above starts from a correctly scaled answer and inverts the
     * calculation with that same answer, so it cannot see a feed reporting in the wrong scale — and
     * neither can the operator, because the script's printed "implied … usd" lines perform exactly
     * that same inversion and round-trip back to the dollar figures that were typed in. A wrong
     * `decimals()` is therefore invisible in the one place a human would look for it. These tests
     * cover the reading itself.
     */

    /// @notice A well-formed, fresh, 8-decimal answer is accepted.
    function test_feedAcceptsAGoodReading() public {
        LaunchHarness harness = new LaunchHarness();
        MockFeed feed = new MockFeed();
        vm.warp(block.timestamp + 1 hours);
        feed.setUpdatedAt(block.timestamp - 60);
        assertEq(harness.ethUsd(address(feed)), 2500e8);
    }

    /// @notice A feed reporting in any other scale is refused rather than silently rescaled.
    /// @dev An 18-decimal aggregator would put the derived floor and graduation raise out by 1e10.
    function test_feedRefusesTheWrongDecimals() public {
        LaunchHarness harness = new LaunchHarness();
        MockFeed feed = new MockFeed();
        feed.setDecimals(18);
        vm.expectRevert(Launch.BadFeedDecimals.selector);
        harness.ethUsd(address(feed));

        feed.setDecimals(6);
        vm.expectRevert(Launch.BadFeedDecimals.selector);
        harness.ethUsd(address(feed));
    }

    /// @notice An answer older than the bound is refused, and the bound matches the website's.
    function test_feedRefusesAStaleAnswer() public {
        LaunchHarness harness = new LaunchHarness();
        MockFeed feed = new MockFeed();
        vm.warp(block.timestamp + 200_000);

        feed.setUpdatedAt(block.timestamp - 90_001);
        vm.expectPartialRevert(Launch.BadFeedAge.selector);
        harness.ethUsd(address(feed));

        // Exactly at the bound is still usable; one second past it is not.
        feed.setUpdatedAt(block.timestamp - 90_000);
        assertEq(harness.ethUsd(address(feed)), 2500e8, "the bound itself is inclusive");
    }

    /// @notice An answer stamped in the future is refused rather than read as very fresh.
    function test_feedRefusesAFutureTimestamp() public {
        LaunchHarness harness = new LaunchHarness();
        MockFeed feed = new MockFeed();
        feed.setUpdatedAt(block.timestamp + 1);
        vm.expectPartialRevert(Launch.BadFeedAge.selector);
        harness.ethUsd(address(feed));
    }

    /// @notice The pre-existing guards still hold: no answer, no round, an incomplete round.
    function test_feedRefusesAnUnusableAnswer() public {
        LaunchHarness harness = new LaunchHarness();
        MockFeed feed = new MockFeed();

        feed.setAnswer(0);
        vm.expectRevert(Launch.BadFeed.selector);
        harness.ethUsd(address(feed));

        feed.setAnswer(-1);
        vm.expectRevert(Launch.BadFeed.selector);
        harness.ethUsd(address(feed));

        feed.setAnswer(2500e8);
        feed.setUpdatedAt(0);
        vm.expectRevert(Launch.BadFeed.selector);
        harness.ethUsd(address(feed));

        feed.setUpdatedAt(block.timestamp);
        feed.setRounds(9, 8);
        vm.expectRevert(Launch.BadFeed.selector);
        harness.ethUsd(address(feed));
    }

    /// @notice A zero feed address is refused.
    function test_feedRefusesTheZeroAddress() public {
        LaunchHarness harness = new LaunchHarness();
        vm.expectRevert(Launch.BadFeed.selector);
        harness.ethUsd(address(0));
    }

    /// @notice A graduation valuation below the floor is refused.
    function test_rejectsGraduationBelowFloor() public {
        vm.expectPartialRevert(Launch.BadParameters.selector);
        script.derive(genesis, 10_000, 1_000, 4, 30, bytes32(uint256(1)), 2500e8);
    }

    /// @notice A floor valuation too small to carry a tick grid is refused.
    function test_rejectsUnpriceableFloor() public {
        vm.expectPartialRevert(Launch.BadParameters.selector);
        script.derive(genesis, 0, 10_000, 4, 30, bytes32(uint256(1)), 2500e8);
    }

    /// @notice Inputs the narrowing casts would have truncated in silence are refused first.
    function test_rejectsOversizedDurationAndDelay() public {
        // 2^64 + 4 hours would have truncated to a valid four-hour window.
        vm.expectPartialRevert(Launch.BadParameters.selector);
        script.derive(genesis, 1_000, 10_000, uint256(type(uint64).max) + 5, 30, bytes32(uint256(1)), 2500e8);
        vm.expectPartialRevert(Launch.BadParameters.selector);
        script.derive(genesis, 1_000, 10_000, 25, 30, bytes32(uint256(1)), 2500e8);
        vm.expectPartialRevert(Launch.BadParameters.selector);
        script.derive(genesis, 1_000, 10_000, 0, 30, bytes32(uint256(1)), 2500e8);
        vm.expectPartialRevert(Launch.BadParameters.selector);
        script.derive(genesis, 1_000, 10_000, 4, 30 * 24 * 60 + 1, bytes32(uint256(1)), 2500e8);
    }

    /// @notice Every duration the vault allows produces an acceptable schedule.
    /// @param durationHours The auction length in hours.
    function testFuzz_anyAllowedDurationIsAccepted(uint8 durationHours) public {
        uint256 hoursBound = bound(durationHours, 1, 24);
        LaunchParams memory p = script.derive(genesis, 1_000, 10_000, hoursBound, 30, bytes32(uint256(1)), 2500e8);

        (uint256 totalMps, uint64 totalBlocks,) = AuctionSteps.totals(p.auctionStepsData);
        assertEq(totalMps, 1e7);
        assertEq(totalBlocks, p.endBlock - p.startBlock);

        vm.prank(owner);
        genesis.launch(p);
    }
}
