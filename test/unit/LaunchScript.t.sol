// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {Launch} from "../../script/Launch.s.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";

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

        assertEq(p.endBlock - p.startBlock, 1_200, "four hours at 12 s per block.number");
        assertEq(p.startBlock, uint64(block.number + 150), "thirty minutes of lead time, 1,800 s / 12 s");
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
