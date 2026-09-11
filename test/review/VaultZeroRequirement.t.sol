// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AccessVault} from "../../src/KAY9AccessVault.sol";
import {KAY9Pricing} from "../../src/KAY9Pricing.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title VaultZeroRequirementTest
/// @notice A period must never open on a requirement of zero KAY9.
/// @dev `lockedKay9 == 0` is how the vault spells "no record". Before the guard, an oracle quote
///      that truncated to zero — a USD target set tiny, or KAY9 priced absurdly high — let `lock`
///      write a record that `consume` and `unlock` could not see, and let `renew` and `upgrade`
///      wipe a live principal down to nothing while keeping the period. The fixture puts the pool
///      at a price where a one-cent target quotes zero, which the ordinary fixture cannot reach.
contract VaultZeroRequirementTest is Kay9TestBase {
    address internal alice = makeAddr("alice");

    /// @notice One KAY9 per billion ETH, in 1e18 units: the price at which small targets vanish.
    uint256 internal constant EXTREME_KAY9_PER_ETH = 1e9;

    function setUp() public override {
        super.setUp();
        _seedAndWarm(EXTREME_KAY9_PER_ETH);
    }

    /// @notice Seeds the pool with just enough liquidity to satisfy the oracle at an extreme price.
    /// @dev The base fixture's 1e21 liquidity would need more ETH than exists at this price.
    function _seedPool(uint256 kay9PerEth) internal override {
        PoolKey memory key = _officialKey();
        uint160 sqrtPriceX96 = uint160(_sqrt(FullMath.mulDiv(kay9PerEth, 1 << 192, 1e18)));
        vm.prank(address(uni.lbpStrategy));
        uni.poolManager.initialize(key, sqrtPriceX96);

        vm.prank(address(genesis));
        token.transfer(address(this), 1_000e18);
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 1_000 ether);

        liquidityRouter.modifyLiquidity{value: 500 ether}(
            key,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: 1e15, salt: bytes32(0)}),
            ""
        );
    }

    /// @notice The fixture really is at a price where the deep target still quotes something.
    function test_theFixtureQuotesADeepRequirementButNotATinyOne() public {
        (uint256 deep,) = accessVault.quoteLock(TIER_DEEP);
        assertGt(deep, 0, "the deep target is still worth some KAY9 here");

        vm.prank(address(timelock));
        pricing.setUsdTarget(TIER_FORENSIC, 1);
        (uint256 forensic,) = accessVault.quoteLock(TIER_FORENSIC);
        assertEq(forensic, 0, "a one-hundred-millionth of a dollar quotes zero at this price");
    }

    /// @notice `lock` refuses a zero requirement rather than writing an invisible record.
    function test_lockRefusesAZeroRequirement() public {
        vm.prank(address(timelock));
        pricing.setUsdTarget(TIER_DEEP, 1);

        vm.prank(alice);
        vm.expectRevert(KAY9AccessVault.ZeroRequirement.selector);
        accessVault.lock(TIER_DEEP, type(uint256).max);

        assertEq(accessVault.accessOf(alice).lockedKay9, 0, "no record");
        assertEq(accessVault.accessOf(alice).startedAt, 0, "no period");
        assertFalse(accessVault.isActive(alice), "nothing opened");
    }

    /// @notice `upgrade` refuses to shrink a live principal to zero.
    function test_upgradeRefusesAZeroRequirement() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        assertGt(locked, 0);

        vm.prank(address(timelock));
        pricing.setUsdTarget(TIER_FORENSIC, 1);

        vm.prank(alice);
        vm.expectRevert(KAY9AccessVault.ZeroRequirement.selector);
        accessVault.upgrade(type(uint256).max);

        assertEq(accessVault.accessOf(alice).lockedKay9, locked, "the principal is untouched");
        assertEq(accessVault.accessOf(alice).tier, TIER_DEEP, "and the tier did not move");
    }

    /// @notice `renew` refuses a zero requirement, and `unlock` still returns everything.
    function test_renewRefusesAZeroRequirementAndUnlockStillWorks() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        vm.warp(accessVault.accessOf(alice).expiresAt);
        _warmBuffer();

        vm.prank(address(timelock));
        pricing.setUsdTarget(TIER_DEEP, 1);

        vm.prank(alice);
        vm.expectRevert(KAY9AccessVault.ZeroRequirement.selector);
        accessVault.renew(TIER_DEEP, type(uint256).max);
        assertEq(accessVault.accessOf(alice).lockedKay9, locked, "the principal is untouched");

        vm.prank(alice);
        accessVault.unlock();
        assertEq(token.balanceOf(alice), locked, "and it all comes home");
    }
}
