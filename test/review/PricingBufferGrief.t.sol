// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Pricing, PricingStatus} from "../../src/KAY9Pricing.sol";

/// @title PricingBufferGriefTest
/// @notice An attacker must not be able to starve the TWAP window by flooding the ring buffer.
contract PricingBufferGriefTest is Kay9TestBase {
    address internal attacker = makeAddr("attacker");

    /// @notice Fills the ring buffer faster than the window, at Robinhood Chain's 0.1 s cadence.
    function test_bufferFloodCannotStarveTheWindow() public {
        _seedAndWarm(2_500_000e18);
        assertTrue(pricing.pricingStatus().available, "price available before the flood");

        // Ten blocks per second, one poke per block: 2048 samples in about 205 seconds, which is
        // far shorter than the 1800 s averaging window.
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 2200; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            if (i % 10 == 0) vm.warp(vm.getBlockTimestamp() + 1);
            pricing.poke();
        }
        vm.stopPrank();

        PricingStatus memory status = pricing.pricingStatus();
        assertTrue(status.available, "the flood must not make the price unavailable");
        assertEq(status.failureCode, 0, "no window-coverage failure");
    }
}
