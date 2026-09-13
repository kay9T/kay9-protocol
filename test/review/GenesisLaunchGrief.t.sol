// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {InitializerHook} from "../utils/InitializerHook.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title GenesisLaunchGriefTest
/// @notice The official pool key must not be squattable, and the hookless pool with the same pair,
///         fee and spacing must be irrelevant to the launch.
contract GenesisLaunchGriefTest is Kay9TestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice A four-hour auction on the auction's own clock: 14,400 s at the chain's 0.1 s cadence.
    /// @dev The auction reads `ArbSys.arbBlockNumber()` through Uniswap's `BlockNumberish`, and so
    ///      does `KAY9Genesis`; neither reads `block.number`, which on this Orbit chain is the
    ///      parent chain's height. See the note on `KAY9Genesis.MIN_DURATION_BLOCKS`.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;
    uint160 internal constant ONE_TO_ONE = 79_228_162_514_264_337_593_543_950_336;

    address internal attacker = makeAddr("attacker");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// @notice Nobody but the LBP strategy can bring the official pool into being, so the key
    ///         cannot be squatted and `launch()` cannot be bricked.
    function test_officialPoolKeyCannotBeSquatted() public {
        vm.prank(attacker);
        vm.expectRevert();
        uni.poolManager.initialize(_officialKey(), ONE_TO_ONE);

        // Not even the vault's own owner can do it.
        vm.prank(owner);
        vm.expectRevert();
        uni.poolManager.initialize(_officialKey(), ONE_TO_ONE);

        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);
        assertEq(genesis.launchCount(), 1, "the launch went through");
    }

    /// @notice Initializing the hookless pool with the same pair, fee and spacing has no effect on
    ///         the launch, the migration, the resolved pool key or the settlement.
    function test_hooklessPoolIsIrrelevantToTheLaunch() public {
        vm.prank(attacker);
        uni.poolManager.initialize(_hooklessKey(), ONE_TO_ONE);

        LaunchParams memory p = _runGraduatingAuction();

        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        assertEq(genesis.launchState(), 3, "migrated");

        PoolKey memory key = genesis.poolKey();
        assertEq(address(key.hooks), address(uni.initializerHook), "the official pool is the hooked one");

        uint128 decoyBefore = uni.poolManager.getLiquidity(_hooklessKey().toId());
        genesis.settle();
        assertEq(uni.poolManager.getLiquidity(_hooklessKey().toId()), decoyBefore, "the decoy stayed empty");
        assertGt(uni.poolManager.getLiquidity(key.toId()), 0, "settlement went into the official pool");
    }

    /// @notice Deploying the vault and launching in the same transaction still works, and is still
    ///         the recommended shape, even though the hook has removed the reason it was mandatory.
    function test_atomicDeployAndLaunchStillWorks() public {
        KAY9Genesis fresh = new KAY9Genesis(
            address(this),
            teamBeneficiary,
            tge,
            unlock6m,
            unlock12m,
            creatorFeeRecipient,
            address(uni.launcher),
            address(uni.lbpStrategy),
            address(uni.positionManager),
            address(uni.poolManager),
            address(uni.permit2),
            address(uni.feeSplitter),
            address(uni.beneficiaryVault),
            address(uni.initializerHook)
        );

        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        fresh.launch(p);
        assertEq(fresh.launchCount(), 1, "launched in the same transaction the token was created in");
    }

    /// @notice The vault refuses any hook that is not a canonical InitializerHook bound to its own
    ///         strategy with the beforeInitialize permission alone.
    function test_constructorRejectsBadHooks() public {
        _expectHookRejected(address(0xBEEF)); // no code
        _expectHookRejected(address(uni.lbpStrategy)); // right flags, but not an InitializerHook
        _expectHookRejected(address(uni.positionManager)); // live contract, wrong interface

        // A well-formed hook whose authorized initializer is somebody else.
        InitializerHook wrong = _mineHook(makeAddr("notTheStrategy"));
        _expectHookRejected(address(wrong));
    }

    /// @notice Deploys a hook bound to `authorized` at an address carrying beforeInitialize only.
    function _mineHook(address authorized) internal returns (InitializerHook) {
        bytes memory creationCode =
            abi.encodePacked(type(InitializerHook).creationCode, abi.encode(uni.poolManager, authorized));
        for (uint256 salt = 0; salt < 200_000; ++salt) {
            address candidate = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xFF), address(this), bytes32(salt), keccak256(creationCode)))
                    )
                )
            );
            if (uint160(candidate) & 0x3FFF == 0x2000 && candidate.code.length == 0) {
                return new InitializerHook{salt: bytes32(salt)}(uni.poolManager, authorized);
            }
        }
        revert("no salt");
    }

    /// @notice Asserts that constructing a vault with `hook` reverts with InvalidPoolHook.
    function _expectHookRejected(address hook) internal {
        vm.expectRevert(abi.encodeWithSelector(KAY9Genesis.InvalidPoolHook.selector, hook));
        new KAY9Genesis(
            address(this),
            teamBeneficiary,
            tge,
            unlock6m,
            unlock12m,
            creatorFeeRecipient,
            address(uni.launcher),
            address(uni.lbpStrategy),
            address(uni.positionManager),
            address(uni.poolManager),
            address(uni.permit2),
            address(uni.feeSplitter),
            address(uni.beneficiaryVault),
            hook
        );
    }

    /// @notice The strategy creates the official pool for any registered distribution of KAY9, so a
    ///         KAY9 holder can create it before the launch does. The launch must then refuse, rather
    ///         than run an auction whose migration could only fail and whose raise would be frozen.
    function test_launchRefusesAnExistingOfficialPool() public {
        // Stands in for a stranger's distribution migrating through the strategy, the only caller
        // the InitializerHook admits.
        vm.prank(address(uni.lbpStrategy));
        uni.poolManager.initialize(_officialKey(), ONE_TO_ONE);

        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.OfficialPoolExists.selector);
        genesis.launch(p);
        assertEq(genesis.launchState(), 0, "nothing launched");
    }

    /// @notice A launch that did not graduate stays failed when somebody else's distribution later
    ///         creates the official pool: `settle` must not pour the supply into that pool, and the
    ///         relaunch refuses to run an auction that could never migrate.
    function test_failedLaunchIgnoresAStrangersOfficialPool() public {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(genesis.auction()));
        assertEq(genesis.launchState(), 4, "failed");

        vm.prank(address(uni.lbpStrategy));
        uni.poolManager.initialize(_officialKey(), ONE_TO_ONE);

        assertEq(genesis.launchState(), 4, "still failed: the pool is not this launch's");
        vm.expectRevert(KAY9Genesis.PoolNotReady.selector);
        genesis.settle();
        vm.expectRevert(KAY9Genesis.NothingToRecover.selector);
        genesis.recover();

        genesis.markFailed();
        vm.warp(genesis.earliestRelaunchTimestamp());
        LaunchParams memory p2 = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        p2.salt = bytes32(uint256(7));
        vm.prank(owner);
        vm.expectRevert(KAY9Genesis.OfficialPoolExists.selector);
        genesis.launch(p2);
    }

    /// @notice Runs a full auction that graduates.
    function _runGraduatingAuction() internal returns (LaunchParams memory p) {
        p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        uint128 amount = uint128(uint256(p.requiredCurrencyRaised) * 3);
        vm.roll(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        _bid(auction, alice, p.floorPriceQ96 * 8, amount);
        vm.roll(p.endBlock - 1);
        _bid(auction, bob, p.floorPriceQ96 * 8, amount);
        vm.roll(p.endBlock);
        auction.checkpoint();
        assertTrue(auction.isGraduated(), "auction graduated");
    }

    /// @notice Places one bid at a price snapped to the auction tick grid.
    function _bid(IContinuousClearingAuction auction, address bidder, uint256 rawPriceQ96, uint128 amount) internal {
        LaunchParams memory p = genesis.launchParams();
        uint256 price = rawPriceQ96 - (rawPriceQ96 % p.auctionTickSpacingQ96);
        vm.deal(bidder, amount);
        vm.prank(bidder);
        auction.submitBid{value: amount}(price, amount, bidder, "");
    }
}
