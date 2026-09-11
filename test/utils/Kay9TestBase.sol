// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Permit2} from "permit2/src/Permit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolManager as IV4PoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {KAY9Token} from "../../src/KAY9Token.sol";
import {KAY9TeamVesting} from "../../src/KAY9TeamVesting.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {KAY9LiquidityLock} from "../../src/KAY9LiquidityLock.sol";
import {KAY9AuditorRegistry} from "../../src/KAY9AuditorRegistry.sol";
import {KAY9Registry} from "../../src/KAY9Registry.sol";
import {KAY9AccessVault} from "../../src/KAY9AccessVault.sol";
import {KAY9AuditHub} from "../../src/KAY9AuditHub.sol";
import {AuctionSteps} from "../../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../../src/libraries/AuctionPriceLib.sol";
import {UniswapDeployment, UniswapStack} from "./UniswapStack.sol";

/// @title Kay9TestBase
/// @notice Shared fixture that deploys the real Uniswap stack and the whole KAY9 protocol.
/// @dev Every test inherits from this so that unit, fuzz and invariant runs all exercise the same
///      wiring the deployment scripts produce.
abstract contract Kay9TestBase is Test {
    /// @notice The project owner Safe stand-in.
    address internal owner = makeAddr("owner");

    /// @notice The team vesting beneficiary.
    address internal teamBeneficiary = makeAddr("teamBeneficiary");

    /// @notice The address that receives LP fee beneficiary NFTs.
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");

    /// @notice The vault's native fallback recipient.
    address internal nativeFallback = makeAddr("nativeFallback");

    /// @notice The vault's token fallback recipient, the canonical burn address on mainnet.
    address internal tokenFallback = address(0xdEaD);

    /// @notice The deployed Uniswap contracts.
    UniswapDeployment internal uni;

    /// @notice The governance timelock that owns the audit protocol.
    TimelockController internal timelock;

    /// @notice The genesis vault.
    KAY9Genesis internal genesis;

    /// @notice The KAY9 token.
    KAY9Token internal token;

    /// @notice The team vesting contract.
    KAY9TeamVesting internal vesting;

    /// @notice The liquidity lock.
    KAY9LiquidityLock internal lock;

    /// @notice The auditor set.
    KAY9AuditorRegistry internal auditorRegistry;

    /// @notice The report log.
    KAY9Registry internal reportRegistry;

    /// @notice The access lock that holds deposits and quota.
    KAY9AccessVault internal accessVault;

    /// @notice The audit hub.
    KAY9AuditHub internal hub;

    /// @notice A router used to move the pool price in tests.
    PoolSwapTest internal swapRouter;

    /// @notice A router used to seed pool liquidity in tests.
    PoolModifyLiquidityTest internal liquidityRouter;

    /// @notice The token generation event timestamp used by the fixture.
    uint64 internal tge;

    /// @notice The six-month unlock timestamp used by the fixture.
    uint64 internal unlock6m;

    /// @notice The twelve-month unlock timestamp used by the fixture.
    uint64 internal unlock12m;

    /// @notice The KAY9 a deep period locks, as the vault's constructor sets it.
    uint256 internal constant DEEP_REQUIREMENT = 5_000e18;

    /// @notice The KAY9 a forensic period locks, as the vault's constructor sets it.
    uint256 internal constant FORENSIC_REQUIREMENT = 10_000e18;

    /// @notice The deep access tier.
    /// @dev Mirrored as a constant rather than read from the contract so that a tier argument never
    ///      makes an external call: a view call in the statement after `vm.expectRevert` would
    ///      consume the expectation. `test_theMirroredConstantsMatchTheContracts` pins the values.
    uint8 internal constant TIER_DEEP = 1;

    /// @notice The forensic access tier.
    uint8 internal constant TIER_FORENSIC = 2;

    /// @notice The requester declared nothing about itself.
    uint8 internal constant KIND_UNKNOWN = 0;

    /// @notice The requester declared itself unrelated to the asset.
    uint8 internal constant KIND_INDEPENDENT = 1;

    /// @notice The requester declared itself the asset's creator.
    uint8 internal constant KIND_CREATOR = 2;

    /// @notice The requester declared itself an integration acting for someone else.
    uint8 internal constant KIND_INTEGRATION = 3;

    /// @notice The auditor private keys, deterministic so tests can sign.
    uint256[3] internal auditorKeys = [uint256(0xA11CE), uint256(0xB0B), uint256(0xC0FFEE)];

    /// @notice The auditor addresses derived from the keys.
    address[3] internal auditorAddresses;

    /// @notice Deploys the full stack.
    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.roll(1_000_000);

        Permit2 permit2 = new Permit2();
        uni = UniswapStack.deploy(IAllowanceTransfer(address(permit2)), nativeFallback, tokenFallback);

        tge = uint64(block.timestamp);
        unlock6m = tge + 182 days;
        unlock12m = tge + 365 days;

        genesis = new KAY9Genesis(
            owner,
            teamBeneficiary,
            tge,
            unlock6m,
            unlock12m,
            creatorFeeRecipient,
            address(uni.launcher),
            address(uni.lbpStrategy),
            address(uni.positionManager),
            address(uni.poolManager),
            address(permit2),
            address(uni.feeSplitter),
            address(uni.beneficiaryVault),
            address(uni.initializerHook)
        );
        token = genesis.token();
        vesting = genesis.teamVesting();
        lock = genesis.liquidityLock();

        _deployAuditProtocol();

        swapRouter = new PoolSwapTest(uni.poolManager);
        liquidityRouter = new PoolModifyLiquidityTest(uni.poolManager);
    }

    /// @notice Deploys the audit protocol against the already-deployed token.
    function _deployAuditProtocol() private {
        address[] memory proposers = new address[](1);
        proposers[0] = owner;
        address[] memory executors = new address[](1);
        executors[0] = owner;
        timelock = new TimelockController(48 hours, proposers, executors, address(0));

        for (uint256 i = 0; i < 3; ++i) {
            auditorAddresses[i] = vm.addr(auditorKeys[i]);
        }
        address[] memory sorted = _sortedAuditors();
        auditorRegistry = new KAY9AuditorRegistry(address(timelock), sorted, 2);

        // The vault is deployed before the hub because the hub takes its address at construction,
        // so it is owned by the test long enough to point it at the hub, exactly as the deployment
        // script does, and then handed to the timelock.
        accessVault = new KAY9AccessVault(address(this), IERC20(address(token)));

        uint256 nonce = vm.getNonce(address(this));
        address predictedHub = vm.computeCreateAddress(address(this), nonce + 1);
        reportRegistry = new KAY9Registry(predictedHub);
        hub = new KAY9AuditHub(address(timelock), address(reportRegistry), auditorRegistry, accessVault);
        assertEq(address(hub), predictedHub, "hub address prediction");

        accessVault.setAuditHub(address(hub));
        accessVault.transferOwnership(address(timelock));
        vm.prank(address(timelock));
        accessVault.acceptOwnership();
        assertEq(accessVault.owner(), address(timelock), "the vault is owned by the timelock");
    }

    /// @notice The auditor addresses in ascending order, which is the order signatures must use.
    /// @return sorted The sorted addresses.
    function _sortedAuditors() internal view returns (address[] memory sorted) {
        sorted = new address[](3);
        for (uint256 i = 0; i < 3; ++i) {
            sorted[i] = auditorAddresses[i];
        }
        for (uint256 i = 0; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (sorted[j] < sorted[i]) (sorted[i], sorted[j]) = (sorted[j], sorted[i]);
            }
        }
    }

    /// @notice The private key that belongs to an auditor address.
    /// @param auditor The auditor address.
    /// @return The private key.
    function _keyOf(address auditor) internal view returns (uint256) {
        for (uint256 i = 0; i < 3; ++i) {
            if (auditorAddresses[i] == auditor) return auditorKeys[i];
        }
        revert("unknown auditor");
    }

    /// @notice Executes a call through the governance timelock, waiting out the delay.
    /// @param target The contract to call.
    /// @param data The calldata.
    function _governanceCall(address target, bytes memory data) internal {
        vm.prank(owner);
        timelock.schedule(target, 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(owner);
        timelock.execute(target, 0, data, bytes32(0), bytes32(0));
    }

    /// @notice Builds a realistic set of launch parameters.
    /// @param floorFdvWei The fully diluted valuation the floor price should express, in wei.
    /// @param durationBlocks The auction duration in blocks.
    /// @return p The launch parameters.
    function _launchParams(uint256 floorFdvWei, uint64 durationBlocks) internal view returns (LaunchParams memory p) {
        uint64 startBlock = uint64(block.number + 100);
        uint64 endBlock = startBlock + durationBlocks;

        uint256 rawFloor = AuctionPriceLib.fdvWeiToPriceQ96(floorFdvWei, token.TOTAL_SUPPLY());
        uint256 tickSpacing = rawFloor / 100;
        if (tickSpacing < 2) tickSpacing = 2;
        uint256 floorPrice = rawFloor - (rawFloor % tickSpacing);

        uint256 required = (floorPrice * genesis.AUCTION_ALLOCATION()) >> 96;

        p = LaunchParams({
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: endBlock,
            migrationBlock: endBlock + 1,
            floorPriceQ96: floorPrice,
            auctionTickSpacingQ96: tickSpacing,
            requiredCurrencyRaised: uint128(required),
            auctionStepsData: AuctionSteps.convexSchedule(startBlock, endBlock),
            salt: bytes32(uint256(1))
        });
    }

    /// @notice The official KAY9 pool key, keyed on the canonical InitializerHook.
    /// @return The pool key.
    function _officialKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(uni.initializerHook))
        });
    }

    /// @notice The hookless pool with the same pair, fee and spacing. Only `recover` ever uses it,
    ///         and anyone can initialize it, which is what several review tests rely on.
    /// @return The pool key.
    function _hooklessKey() internal view returns (PoolKey memory) {
        PoolKey memory key = _officialKey();
        key.hooks = IHooks(address(0));
        return key;
    }

    // -------------------------------------------------------------------------------------------
    // Access helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Moves KAY9 out of the genesis vault to a test account.
    /// @param to The receiver.
    /// @param amount The amount to move.
    function _fundKay9(address to, uint256 amount) internal {
        vm.prank(address(genesis));
        token.transfer(to, amount);
    }

    /// @notice Gives an account a live access period at a tier, funding it with exactly the
    ///         requirement so that a later balance assertion has nothing else in it.
    /// @param account The account to give access to.
    /// @param tier The tier to open: 1 deep, 2 forensic.
    /// @return locked The KAY9 the vault took, which is the tier's requirement at that moment.
    function _grantAccess(address account, uint8 tier) internal returns (uint256 locked) {
        locked = accessVault.requirementOf(tier);
        _fundKay9(account, locked);
        vm.startPrank(account);
        token.approve(address(accessVault), type(uint256).max);
        accessVault.lock(tier, locked);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // Pool helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Initializes the official pool at a KAY9-per-ETH price and seeds deep liquidity.
    /// @param kay9PerEth The desired KAY9-per-ETH price, scaled by 1e18.
    function _seedPool(uint256 kay9PerEth) internal virtual {
        PoolKey memory key = _officialKey();
        uint160 sqrtPriceX96 = uint160(_sqrt(FullMath.mulDiv(kay9PerEth, 1 << 192, 1e18)));
        vm.prank(address(uni.lbpStrategy));
        uni.poolManager.initialize(key, sqrtPriceX96);

        vm.prank(address(genesis));
        token.transfer(address(this), 400_000_000e18);
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 20_000 ether);

        liquidityRouter.modifyLiquidity{value: 10_000 ether}(
            key,
            ModifyLiquidityParams({tickLower: -600_000, tickUpper: 600_000, liquidityDelta: 1e21, salt: bytes32(0)}),
            ""
        );
    }

    /// @notice Advances the clock and the block height together.
    /// @dev The cheatcode getters are used instead of block.timestamp and block.number because the
    ///      optimizer hoists those opcodes out of a loop, which would silently freeze the clock.
    /// @param secondsToAdvance The number of seconds to move forward.
    function _advance(uint256 secondsToAdvance) internal {
        vm.warp(vm.getBlockTimestamp() + secondsToAdvance);
        vm.roll(vm.getBlockNumber() + secondsToAdvance * 10);
    }

    /// @notice Buys KAY9 with ETH, which pushes the tick down.
    /// @param ethIn The ETH to spend.
    function _buyKay9(uint256 ethIn) internal {
        vm.deal(address(this), address(this).balance + ethIn);
        swapRouter.swap{value: ethIn}(
            _officialKey(),
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Sells KAY9 for ETH, which pushes the tick up.
    /// @param tokenIn The KAY9 to sell.
    function _sellKay9(uint256 tokenIn) internal {
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            _officialKey(),
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(tokenIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Integer square root.
    /// @param x The value.
    /// @return The square root.
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /// @notice Accepts the ETH the Uniswap routers return.
    receive() external payable {}
}
