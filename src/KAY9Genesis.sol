// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {KAY9Token} from "./KAY9Token.sol";
import {KAY9TeamVesting, ILaunchSettlement} from "./KAY9TeamVesting.sol";
import {KAY9LiquidityLock} from "./KAY9LiquidityLock.sol";
import {TickRange} from "./libraries/TickRange.sol";
import {AuctionPriceLib} from "./libraries/AuctionPriceLib.sol";
import {ILiquidityLauncher} from "./interfaces/uniswap/ILiquidityLauncher.sol";
import {ILBPStrategy} from "./interfaces/uniswap/ILBPStrategy.sol";
import {ILBPInitializer} from "./interfaces/uniswap/ILBPInitializer.sol";
import {IDistributorFactory} from "./interfaces/uniswap/IDistributorFactory.sol";
import {IContinuousClearingAuction} from "./interfaces/uniswap/IContinuousClearingAuction.sol";
import {IBeneficiaryVault} from "./interfaces/uniswap/IBeneficiaryVault.sol";
import {IInitializerHook} from "./interfaces/uniswap/IInitializerHook.sol";
import {
    AuctionParameters,
    Distribution,
    LiquidityAllocationBracket,
    MigratorParameters,
    PoolParameters,
    PositionDefinition
} from "./interfaces/uniswap/LauncherTypes.sol";

/// @notice The pricing and timing choices the owner supplies for a launch. Everything else about
///         the launch is fixed by the contract.
struct LaunchParams {
    uint64 startBlock;
    uint64 endBlock;
    uint64 claimBlock;
    uint64 migrationBlock;
    uint256 floorPriceQ96;
    uint256 auctionTickSpacingQ96;
    uint128 requiredCurrencyRaised;
    bytes auctionStepsData;
    bytes32 salt;
}

/// @title KAY9Genesis
/// @notice The launch vault. It deploys the token and the team vesting contract, holds the
///         910,000,000 KAY9 launch allocation, and is the only route by which those tokens can
///         leave: into a Uniswap fair auction and, from there, into a permanently locked liquidity
///         position. The contract has no withdraw function and the owner cannot move tokens or ETH
///         anywhere except through the launch pipeline.
/// @dev The owner supplies pricing and timing only. Every trust-relevant field of the auction and
///      of the migration is constructed by this contract from its own immutables, so the owner
///      cannot redirect the raise, change the pool parameters, change the position recipient or
///      keep unsold supply.
///
///      The official pool is `(native ETH, KAY9, fee 10000, tickSpacing 200, InitializerHook)`. The
///      hook is Uniswap's canonical initializer gate: it holds the beforeInitialize permission and
///      no other, takes no hook data, and refuses every caller but the LBPStrategy. That makes the
///      pool key unsquattable before the launch, which is what stops a stranger from bricking
///      `launch()` for the price of one transaction, and makes an initialized pool proof that the
///      strategy's migration ran, which is what makes the pool key resolve unambiguously
///      afterwards. It is the same class of pool as the strategy's own hooked fallback.
/// @custom:security-contact security@kay9.io
contract KAY9Genesis is Ownable2Step, ReentrancyGuard, BlockNumberish {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice Emitted once, at construction, with the addresses of the deployed satellites.
    /// @param token The KAY9 token.
    /// @param teamVesting The team vesting contract.
    /// @param liquidityLock The one-way liquidity lock.
    event Deployed(address indexed token, address indexed teamVesting, address indexed liquidityLock);

    /// @notice Emitted with the complete configuration of a launch, before it is executed.
    /// @param launchIndex The one-based index of this launch attempt.
    /// @param auction The predicted auction address.
    /// @param params The owner-supplied parameters.
    /// @param impliedFloorFdvWei The fully diluted valuation the floor price implies, in wei.
    /// @param impliedGraduationRaiseWei The ETH the auction must raise to graduate, in wei.
    event LaunchConfigured(
        uint256 indexed launchIndex,
        address indexed auction,
        LaunchParams params,
        uint256 impliedFloorFdvWei,
        uint256 impliedGraduationRaiseWei
    );

    /// @notice Emitted once a launch has been executed and the auction exists on-chain.
    /// @param launchIndex The one-based index of this launch attempt.
    /// @param auction The deployed auction.
    /// @param startBlock The auction start block.
    /// @param endBlock The auction end block.
    event Launched(uint256 indexed launchIndex, address indexed auction, uint64 startBlock, uint64 endBlock);

    /// @notice Emitted when a failed launch starts its relaunch cooldown.
    /// @param earliestRelaunchTimestamp The timestamp a new launch becomes possible at.
    event RelaunchScheduled(uint256 earliestRelaunchTimestamp);

    /// @notice Emitted for each settlement of unsold and leftover supply.
    /// @param amountToLiquidity The KAY9 placed into the single-sided position.
    /// @param amountBurned The KAY9 destroyed as dust.
    /// @param positionTokenId The minted position, or zero when everything was dust.
    event UnsoldSettled(uint256 amountToLiquidity, uint256 amountBurned, uint256 positionTokenId);

    /// @notice Emitted when a graduated auction whose migration failed is recovered into a pool.
    /// @param ethAmount The ETH placed into the pool.
    /// @param tokenAmount The KAY9 placed into the pool.
    /// @param positionTokenId The minted full-range position.
    event Recovered(uint256 ethAmount, uint256 tokenAmount, uint256 positionTokenId);

    /// @notice Emitted once per launch, when the migration outcome is written down.
    /// @param succeeded True when this launch's own migration built the official pool.
    event MigrationOutcomeRecorded(bool succeeded);

    /// @notice Thrown when a constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a launch is attempted while the previous one is still resolvable.
    /// @param state The current launch state.
    error WrongLaunchState(uint8 state);

    /// @notice Thrown when a relaunch is attempted before the cooldown has elapsed.
    /// @param earliest The timestamp a relaunch becomes possible at.
    error RelaunchTooEarly(uint256 earliest);

    /// @notice Thrown when the failure cooldown has not been started yet.
    error FailureNotMarked();

    /// @notice Thrown when markFailed is called on a launch that has not failed.
    error NotFailed();

    /// @notice Thrown when the auction window is shorter or longer than the allowed range.
    /// @param durationBlocks The requested duration.
    error InvalidDuration(uint64 durationBlocks);

    /// @notice Thrown when the auction start block is not in the future.
    error StartBlockInPast();

    /// @notice Thrown when the claim block precedes the end block.
    error InvalidClaimBlock();

    /// @notice Thrown when the migration block does not follow the end block.
    error InvalidMigrationBlock();

    /// @notice Thrown when the floor price is zero or not on a tick boundary.
    error InvalidFloorPrice();

    /// @notice Thrown when the auction tick spacing is below the protocol minimum.
    error InvalidAuctionTickSpacing();

    /// @notice Thrown when the graduation threshold is zero.
    error InvalidRequiredRaise();

    /// @notice Thrown when the emission schedule is empty or malformed.
    error InvalidAuctionSteps();

    /// @notice Thrown when the vault does not hold the full launch allocation.
    /// @param balance The current balance.
    error InsufficientLaunchBalance(uint256 balance);

    /// @notice Thrown when the auction the strategy created is not the one that was predicted.
    /// @param predicted The predicted address.
    error AuctionMismatch(address predicted);

    /// @notice Thrown when a launch is attempted while the official pool already exists.
    /// @dev The strategy initializes the official key for any registered distribution of KAY9, not
    ///      only this contract's, so a KAY9 holder can bring it into being while no launch of ours
    ///      holds the key. An auction launched after that could never migrate. See `launch`.
    error OfficialPoolExists();

    /// @notice Thrown when settle or recover is called before the pool exists.
    error PoolNotReady();

    /// @notice Thrown when settle is called after everything has already been settled.
    error AlreadySettled();

    /// @notice Thrown when recover is called on a launch that does not need recovery.
    error NothingToRecover();

    /// @notice Thrown when the supplied initialization hook is not a canonical InitializerHook
    ///         bound to this contract's LBPStrategy with the beforeInitialize permission alone.
    /// @param hook The rejected hook.
    error InvalidPoolHook(address hook);

    /// @notice Thrown when the hookless recovery pool already exists at a price other than the
    ///         auction's final clearing price.
    /// @param existing The price the pool is already at.
    /// @param expected The auction's clearing price, converted to a v4 sqrt price.
    error RecoveryPoolPriceMismatch(uint160 existing, uint160 expected);

    /// @notice The KAY9 token, deployed by this contract.
    KAY9Token public immutable token;

    /// @notice The team vesting contract, deployed and funded by this contract.
    KAY9TeamVesting public immutable teamVesting;

    /// @notice The one-way liquidity lock, deployed by this contract.
    KAY9LiquidityLock public immutable liquidityLock;

    /// @notice The canonical Uniswap LiquidityLauncher.
    ILiquidityLauncher public immutable launcher;

    /// @notice The canonical Uniswap LBPStrategy.
    ILBPStrategy public immutable lbpStrategy;

    /// @notice The canonical Uniswap v4 PositionManager.
    IPositionManager public immutable positionManager;

    /// @notice The canonical Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice The canonical Permit2.
    IAllowanceTransfer public immutable permit2;

    /// @notice The canonical Uniswap InitializerHook the official pool is keyed on.
    /// @dev The hook carries the beforeInitialize permission and nothing else, and its
    ///      `authorized()` is the LBPStrategy, so the strategy's migration is the only transaction
    ///      in existence that can bring the official pool into being. That is what makes the pool
    ///      key unsquattable before the launch and unambiguous afterwards. It has no swap, liquidity
    ///      or donate callbacks, takes no hook data, and can never charge or divert anything.
    address public immutable poolHook;

    /// @notice The auction factory the strategy deploys through, read from the strategy itself.
    IDistributorFactory public immutable auctionFactory;

    /// @notice The total supply handed to the launch pipeline.
    uint256 public constant LAUNCH_ALLOCATION = 910_000_000e18;

    /// @notice The share of the launch allocation offered in the auction.
    uint256 public constant AUCTION_ALLOCATION = 455_000_000e18;

    /// @notice The share of the launch allocation reserved for the initial liquidity position.
    uint256 public constant LIQUIDITY_RESERVE = 455_000_000e18;

    /// @notice The static pool fee, in hundredths of a basis point. 10000 is 1 %.
    uint24 public constant POOL_FEE = 10_000;

    /// @notice The pool tick spacing.
    int24 public constant POOL_TICK_SPACING = 200;

    /**
     * @notice The shortest auction window, in blocks. About one hour.
     *
     * @dev Counted on the clock the auction itself reads, which on this chain is **not**
     *      `block.number`.
     *
     *      Robinhood Chain is an Arbitrum Orbit chain. Two block numbers exist inside a contract
     *      here: `block.number` is the parent chain's height (about one every 12 s; 11,679,667 on
     *      testnet and 25,951,849 on mainnet on 2026-09-11), and `ArbSys.arbBlockNumber()` is the
     *      chain's own height (about one every 0.1 s; 117,236,896 and 59,983,529 the same day, the
     *      number every explorer and `eth_blockNumber` show). The Continuous Clearing Auction and
     *      the LBP strategy read the second one through Uniswap's `BlockNumberish`, so every block
     *      figure in a launch, start, end, claim and migration, is a height on that clock.
     *
     *      This contract therefore reads the same clock through the same helper, for its own
     *      validation and for `launchState`. An earlier revision compared the window against
     *      `block.number` and bounded it at 300–7,200 blocks: on the auction's clock that is 30 s
     *      to 12 min, and a launch made that way on testnet on 2026-09-11 was over before its
     *      first bid (`AuctionIsOver`) while `launchState` reported it live, and would have gone
     *      on reporting it live until Ethereum reached block 11,679,956, decades later.
     *
     *      3,600 s / 0.1 s = 36,000 blocks. The measured cadence is 0.1012 s, so a window derived
     *      at 0.1 s runs slightly longer in wall-clock terms than requested, never shorter.
     */
    uint64 public constant MIN_DURATION_BLOCKS = 36_000;

    /// @notice The longest auction window, in blocks. About twenty-four hours, 86,400 s / 0.1 s.
    /// @dev See MIN_DURATION_BLOCKS for which clock this counts.
    uint64 public constant MAX_DURATION_BLOCKS = 864_000;

    /// @notice Leftover KAY9 below this amount is burned instead of being placed as liquidity.
    uint256 public constant DUST_THRESHOLD = 1_000e18;

    /// @notice How long after a failure the owner must wait before relaunching.
    uint256 public constant RELAUNCH_DELAY = 48 hours;

    /// @notice The full liquidity weight of a position plan, in milli-percent.
    uint24 internal constant FULL_WEIGHT = 1e7;

    /// @notice The Continuous Clearing Auction's minimum price tick spacing.
    uint256 internal constant MIN_AUCTION_TICK_SPACING = 2;

    /// @notice The Continuous Clearing Auction's minimum floor price.
    uint256 internal constant MIN_AUCTION_FLOOR_PRICE = (1 << 32) + 1;

    /// @notice The address(1) sentinel the auction factory rewrites to its caller.
    address internal constant FUNDS_RECIPIENT_SENTINEL = address(1);

    /// @notice The current auction, or the zero address before the first launch.
    address public auction;

    /// @notice The number of launches that have been executed.
    uint256 public launchCount;

    /// @notice The timestamp a relaunch becomes possible at, or zero when no failure is pending.
    uint256 public earliestRelaunchTimestamp;

    /// @notice Whether the leftover supply of the current launch has been fully settled.
    bool public settled;

    /// @notice Whether the current launch was rebuilt by `recover` into the hookless pool.
    /// @dev Set once, by `recover`, and read by `poolKey` so the website and the oracle are told
    ///      which pool the liquidity actually ended up in.
    bool public recovered;

    /// @notice Whether the migration outcome of the current launch has been written down.
    /// @dev `settle` and `recover` both move the balances the outcome is read from, so the first of
    ///      them to run records the answer and every later read returns the recorded one.
    bool public outcomeRecorded;

    /// @notice The recorded outcome: true when this launch's own migration built the official pool.
    bool public migrationSucceeded;

    /// @notice The parameters of the current launch, kept for state resolution and for the website.
    LaunchParams private _params;

    /// @notice The migration parameters of the current launch, kept so the pool key can be rebuilt.
    MigratorParameters private _migrationParams;

    /// @notice Deploys the token, the vesting contract and the liquidity lock, and funds vesting.
    /// @param owner_ The project owner, in production a Safe.
    /// @param teamBeneficiary The initial team vesting beneficiary.
    /// @param tge The token generation event timestamp.
    /// @param unlock6m The six-month unlock timestamp.
    /// @param unlock12m The twelve-month unlock timestamp.
    /// @param creatorFeeRecipient The address that receives the LP fee beneficiary NFTs.
    /// @param launcher_ The canonical LiquidityLauncher.
    /// @param lbpStrategy_ The canonical LBPStrategy.
    /// @param positionManager_ The canonical v4 PositionManager.
    /// @param poolManager_ The canonical v4 PoolManager.
    /// @param permit2_ The canonical Permit2.
    /// @param feeSplitter The FeeSplitter that permanently custodies the positions.
    /// @param beneficiaryVault The vault that mints the fee beneficiary NFTs.
    /// @param poolHook_ The canonical InitializerHook the official pool is keyed on. It must be a
    ///        live contract that answers ERC-165 for IInitializerHook, whose `authorized()` is
    ///        `lbpStrategy_`, and whose address carries the beforeInitialize permission bit and no
    ///        other v4 hook permission.
    constructor(
        address owner_,
        address teamBeneficiary,
        uint64 tge,
        uint64 unlock6m,
        uint64 unlock12m,
        address creatorFeeRecipient,
        address launcher_,
        address lbpStrategy_,
        address positionManager_,
        address poolManager_,
        address permit2_,
        address feeSplitter,
        address beneficiaryVault,
        address poolHook_
    ) Ownable(owner_) {
        if (
            launcher_ == address(0) || lbpStrategy_ == address(0) || positionManager_ == address(0)
                || poolManager_ == address(0) || permit2_ == address(0) || poolHook_ == address(0)
        ) revert ZeroAddress();

        _validatePoolHook(poolHook_, lbpStrategy_);
        poolHook = poolHook_;

        launcher = ILiquidityLauncher(launcher_);
        lbpStrategy = ILBPStrategy(lbpStrategy_);
        positionManager = IPositionManager(positionManager_);
        poolManager = IPoolManager(poolManager_);
        permit2 = IAllowanceTransfer(permit2_);
        auctionFactory = ILBPStrategy(lbpStrategy_).initializerFactory();

        KAY9Token token_ = new KAY9Token(address(this));
        // The vesting contract releases nothing until this launch has settled: see its notes.
        KAY9TeamVesting vesting = new KAY9TeamVesting(
            IERC20(address(token_)), teamBeneficiary, ILaunchSettlement(address(this)), tge, unlock6m, unlock12m
        );
        KAY9LiquidityLock lock = new KAY9LiquidityLock(
            IPositionManager(positionManager_), feeSplitter, IBeneficiaryVault(beneficiaryVault), creatorFeeRecipient
        );

        token = token_;
        teamVesting = vesting;
        liquidityLock = lock;

        IERC20(address(token_)).safeTransfer(address(vesting), vesting.TOTAL_ALLOCATION());

        emit Deployed(address(token_), address(vesting), address(lock));
    }

    /// @notice Checks that a hook is a canonical InitializerHook bound to this launch's strategy.
    /// @dev Every one of these is load bearing. Live code and the ERC-165 answer prove it is the
    ///      right kind of contract; `authorized() == strategy` proves the strategy is the only party
    ///      that can initialize the pool; the exact-flag check proves the low fourteen bits of the
    ///      address grant beforeInitialize and nothing else, so the hook can never intercept a swap,
    ///      a liquidity change or a donation, and `isValidHookAddress` repeats v4's own admission
    ///      rule for the static fee this launch uses. The LBP strategy re-runs the ERC-165, the
    ///      `authorized` and the permission checks at `initializeDistribution`; they are duplicated
    ///      here so a mis-wired deployment fails at construction rather than at launch.
    /// @param hook The hook to validate.
    /// @param strategy The strategy that must be the hook's authorized initializer.
    function _validatePoolHook(address hook, address strategy) private view {
        if (hook.code.length == 0) revert InvalidPoolHook(hook);
        if (!ERC165Checker.supportsInterface(hook, type(IInitializerHook).interfaceId)) revert InvalidPoolHook(hook);
        if (IInitializerHook(hook).authorized() != strategy) revert InvalidPoolHook(hook);
        if (uint160(hook) & Hooks.ALL_HOOK_MASK != Hooks.BEFORE_INITIALIZE_FLAG) revert InvalidPoolHook(hook);
        if (!Hooks.isValidHookAddress(IHooks(hook), POOL_FEE)) revert InvalidPoolHook(hook);
    }

    /// @notice Accepts the ETH the strategy returns when a migration fails.
    /// @dev The only way this ETH can leave again is `recover`, which puts it into the pool.
    receive() external payable {}

    // -------------------------------------------------------------------------------------------
    // Launch
    // -------------------------------------------------------------------------------------------

    /// @notice Configures and executes the fair launch.
    /// @dev Only the owner may call this, and only before the first launch or after a previous
    ///      launch has been marked failed and the cooldown has elapsed.
    /// @param p The pricing and timing parameters.
    function launch(LaunchParams calldata p) external onlyOwner nonReentrant {
        if (launchCount == 0) {
            if (auction != address(0)) revert WrongLaunchState(launchState());
        } else {
            uint8 state = launchState();
            if (state != uint8(LaunchState.Failed)) revert WrongLaunchState(state);
            if (earliestRelaunchTimestamp == 0) revert FailureNotMarked();
            if (block.timestamp < earliestRelaunchTimestamp) revert RelaunchTooEarly(earliestRelaunchTimestamp);
            _releaseStrategyReserve();
            _sweepUnsoldTokens();
        }

        _validate(p);

        // The InitializerHook stops anyone but the strategy from creating the official pool, but
        // the strategy creates it for any registered distribution of KAY9. If one already has, this
        // auction's migration could only fail, and its raise would come back to a vault that reads
        // the stranger's pool as the migrated one. Refusing here keeps every bidder's ETH out of it.
        (uint160 officialPrice,,,) = poolManager.getSlot0(_officialKey().toId());
        if (officialPrice != 0) revert OfficialPoolExists();

        uint256 balance = token.balanceOf(address(this));
        if (balance < LAUNCH_ALLOCATION) revert InsufficientLaunchBalance(balance);

        (MigratorParameters memory mp, AuctionParameters memory ap) = _buildParams(p);
        address predicted = _predictAuction(mp, ap, p.salt);

        uint256 index = launchCount + 1;
        emit LaunchConfigured(
            index,
            predicted,
            p,
            AuctionPriceLib.impliedFdvWei(p.floorPriceQ96, token.TOTAL_SUPPLY()),
            uint256(p.requiredCurrencyRaised)
        );

        _params = p;
        _migrationParams = mp;
        auction = predicted;
        launchCount = index;
        earliestRelaunchTimestamp = 0;
        settled = false;
        recovered = false;
        outcomeRecorded = false;
        migrationSucceeded = false;

        _execute(mp, ap, p.salt);

        if (lbpStrategy.initializers(ILBPInitializer(predicted)).migrationBlock != p.migrationBlock) {
            revert AuctionMismatch(predicted);
        }

        emit Launched(index, predicted, p.startBlock, p.endBlock);
    }

    /// @notice Previews the auction address and the valuations a set of parameters implies.
    /// @param p The pricing and timing parameters.
    /// @return predictedAuction The address the auction would be deployed to.
    /// @return impliedFloorFdvWei The fully diluted valuation the floor price implies, in wei.
    /// @return impliedGraduationRaiseWei The ETH the auction would have to raise to graduate.
    function previewLaunch(LaunchParams calldata p)
        external
        view
        returns (address predictedAuction, uint256 impliedFloorFdvWei, uint256 impliedGraduationRaiseWei)
    {
        (MigratorParameters memory mp, AuctionParameters memory ap) = _buildParams(p);
        predictedAuction = _predictAuction(mp, ap, p.salt);
        impliedFloorFdvWei = AuctionPriceLib.impliedFdvWei(p.floorPriceQ96, token.TOTAL_SUPPLY());
        impliedGraduationRaiseWei = uint256(p.requiredCurrencyRaised);
    }

    /// @notice The block number the launch is measured against: the chain's own height on an
    ///         Arbitrum chain, `block.number` elsewhere. Exactly what the auction reads.
    /// @dev Exposed so a launch script and a website derive `startBlock` and friends from the
    ///      clock this contract will validate them on, rather than guessing which of the two
    ///      heights that is.
    /// @return The current block number on the auction's clock.
    function chainBlockNumber() external view returns (uint256) {
        return _getBlockNumberish();
    }

    /// @notice The parameters of the current launch.
    /// @return The stored launch parameters.
    function launchParams() external view returns (LaunchParams memory) {
        return _params;
    }

    /// @notice The migration parameters of the current launch.
    /// @return The stored migration parameters.
    function migrationParams() external view returns (MigratorParameters memory) {
        return _migrationParams;
    }

    /// @notice The states a launch can be in.
    enum LaunchState {
        NotLaunched,
        AuctionLive,
        AuctionEnded,
        Migrated,
        Failed
    }

    /// @notice The state of the current launch.
    /// @dev Compared on the auction's own clock (`chainBlockNumber`), never on `block.number`,
    ///      which on this Orbit chain is the parent chain's height. See MIN_DURATION_BLOCKS.
    ///      1 is also reported between `launch` and the start block, while bids still revert; a
    ///      reader that needs "scheduled" apart from "live" compares `chainBlockNumber` with
    ///      `launchParams().startBlock`. 4 is reported for a non-graduated auction only once the
    ///      auction has checkpointed its end block; anyone can call the auction's `checkpoint()`.
    /// @return 0 not launched, 1 auction live, 2 auction ended, 3 migrated, 4 failed.
    function launchState() public view returns (uint8) {
        address currentAuction = auction;
        if (currentAuction == address(0)) return uint8(LaunchState.NotLaunched);

        if (_getBlockNumberish() < _params.endBlock) return uint8(LaunchState.AuctionLive);

        (bool attempted, bool succeeded,) = _migrationOutcome();
        if (!attempted) {
            // The auction is over. Once a non-graduated auction can no longer graduate, the launch
            // has failed even though nobody has called migrate yet. That is only settled once the
            // auction has checkpointed its end block: `isGraduated` reads the figure stored at the
            // last checkpoint, and the launch schedule releases its largest slice in the final
            // block, so an auction can read as not graduated right up to the checkpoint that
            // graduates it. Until then the honest answer is "ended".
            if (!_graduated(currentAuction) && _finalized(currentAuction)) return uint8(LaunchState.Failed);
            return uint8(LaunchState.AuctionEnded);
        }
        return succeeded ? uint8(LaunchState.Migrated) : uint8(LaunchState.Failed);
    }

    /// @notice Starts the 48-hour relaunch cooldown after a failure. Permissionless.
    /// @dev A launch that failed has to be marked explicitly, because the chain does not record the
    ///      timestamp at which the failure became observable. Marking is public so anybody can
    ///      start the clock as soon as the failure is visible.
    function markFailed() public {
        if (launchState() != uint8(LaunchState.Failed)) revert NotFailed();
        if (earliestRelaunchTimestamp != 0) return;
        uint256 earliest = block.timestamp + RELAUNCH_DELAY;
        earliestRelaunchTimestamp = earliest;
        emit RelaunchScheduled(earliest);
    }

    // -------------------------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------------------------

    /// @notice The pool key the launch's liquidity lives in.
    /// @dev Before and after a normal migration this is the official hooked pool. After a `recover`
    ///      it is the hookless pool the recovery built, because the official pool can only be
    ///      created by the strategy and a failed migration never created it.
    /// @return key The resolved pool key.
    function poolKey() public view returns (PoolKey memory key) {
        (,, key) = _migrationOutcome();
        if (Currency.unwrap(key.currency1) == address(0)) key = _officialKey();
    }

    /// @notice Places every KAY9 the vault still holds as a single-sided position and locks it.
    ///         Permissionless.
    /// @dev The position sits entirely below the current tick, which is where a currency1-only
    ///      range lives when currency0 is native ETH: buying KAY9 pushes the tick down, so the
    ///      offered supply sits at KAY9 prices above the current one. Its upper edge is anchored
    ///      at the lower of the current tick and the auction's clearing tick, so the leftover is
    ///      never offered below the clearing price and moving the price down before calling this
    ///      gains nothing. Amounts below the dust threshold are burned rather than placed.
    function settle() external nonReentrant {
        if (settled) revert AlreadySettled();
        (bool attempted, bool succeeded, PoolKey memory key) = _migrationOutcome();
        if (!attempted || !succeeded) revert PoolNotReady();

        _recordOutcome(true);
        _sweepUnsoldTokens();
        _settleRemainder(key);
    }

    /// @notice Rebuilds the pool from a graduated auction whose migration failed. Permissionless.
    /// @dev A migration that reverted never initialized the official pool, and the InitializerHook
    ///      lets only the strategy do that, so recovery falls back to the hookless pool with the
    ///      same pair, fee and spacing. The recovery price is the auction's final clearing price and
    ///      nothing else: if a third party has already initialized that hookless key at some other
    ///      price, this reverts rather than minting the whole raise at a price a stranger chose. A
    ///      squatted key can be nudged back — an empty pool's price moves to any target for the cost
    ///      of a swap that fills nothing — after which recovery proceeds. The ETH has no other exit:
    ///      this function is the only code path that spends it, and it can only spend it into a pool
    ///      priced by the auction.
    function recover() external nonReentrant {
        (bool attempted, bool succeeded,) = _migrationOutcome();
        if (!attempted || succeeded) revert NothingToRecover();

        address currentAuction = auction;
        if (!_graduated(currentAuction)) revert NothingToRecover();

        uint256 ethAmount = address(this).balance;
        if (ethAmount == 0) revert NothingToRecover();

        _recordOutcome(false);

        // The auction hands unsold supply only to its tokensRecipient, which is this contract, and
        // `_settleRemainder` below marks the launch settled. Sweeping here is therefore the last
        // chance those tokens get: without it they would stay in the auction with no caller left.
        _sweepUnsoldTokens();

        PoolKey memory key = _recoveryKey();
        uint160 sqrtPriceX96 =
            AuctionPriceLib.toSqrtPriceX96(IContinuousClearingAuction(currentAuction).clearingPrice(), true);
        (uint160 existing,,,) = poolManager.getSlot0(key.toId());
        if (existing == 0) {
            poolManager.initialize(key, sqrtPriceX96);
        } else if (existing != sqrtPriceX96) {
            revert RecoveryPoolPriceMismatch(existing, sqrtPriceX96);
        }
        recovered = true;

        uint256 tokenAmount = token.balanceOf(address(this));
        int24 tickLower = TickRange.minUsableTick(POOL_TICK_SPACING);
        int24 tickUpper = TickRange.maxUsableTick(POOL_TICK_SPACING);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            tokenAmount
        );
        if (liquidity == 0) revert NothingToRecover();

        uint256 tokenId =
            _mintAndLock(key, tickLower, tickUpper, liquidity, uint128(ethAmount), uint128(tokenAmount), ethAmount);

        emit Recovered(ethAmount, tokenAmount, tokenId);

        _settleRemainder(key);
    }

    // -------------------------------------------------------------------------------------------
    // Internals: parameter construction
    // -------------------------------------------------------------------------------------------

    /// @notice Validates the owner-supplied parameters.
    /// @param p The parameters to validate.
    function _validate(LaunchParams calldata p) private view {
        if (p.startBlock <= _getBlockNumberish()) revert StartBlockInPast();
        if (p.endBlock <= p.startBlock) revert InvalidDuration(0);

        uint64 duration = p.endBlock - p.startBlock;
        if (duration < MIN_DURATION_BLOCKS || duration > MAX_DURATION_BLOCKS) revert InvalidDuration(duration);
        if (p.claimBlock < p.endBlock) revert InvalidClaimBlock();
        if (p.migrationBlock <= p.endBlock) revert InvalidMigrationBlock();

        if (p.auctionTickSpacingQ96 < MIN_AUCTION_TICK_SPACING) revert InvalidAuctionTickSpacing();
        if (p.floorPriceQ96 < MIN_AUCTION_FLOOR_PRICE) revert InvalidFloorPrice();
        if (p.floorPriceQ96 % p.auctionTickSpacingQ96 != 0) revert InvalidFloorPrice();
        if (p.requiredCurrencyRaised == 0) revert InvalidRequiredRaise();

        uint256 stepsLength = p.auctionStepsData.length;
        if (stepsLength == 0 || stepsLength % 8 != 0) revert InvalidAuctionSteps();
    }

    /// @notice Builds the migration and auction parameters from the owner's inputs.
    /// @param p The owner-supplied parameters.
    /// @return migrationParams_ The migration parameters.
    /// @return auctionParams The auction parameters.
    function _buildParams(LaunchParams calldata p)
        private
        view
        returns (MigratorParameters memory migrationParams_, AuctionParameters memory auctionParams)
    {
        PositionDefinition[] memory positions = new PositionDefinition[](1);
        positions[0] = PositionDefinition({
            offsetLower: TickMath.MIN_TICK,
            offsetUpper: TickMath.MAX_TICK,
            weight: FULL_WEIGHT,
            overridePositionRecipient: address(0)
        });

        LiquidityAllocationBracket[] memory brackets = new LiquidityAllocationBracket[](1);
        brackets[0] = LiquidityAllocationBracket({lowerThreshold: 0, rate: FULL_WEIGHT});

        migrationParams_ = MigratorParameters({
            token: address(token),
            currency: address(0),
            migrationBlock: p.migrationBlock,
            reservedTokenAmountForLP: uint128(LIQUIDITY_RESERVE),
            recipient: address(this),
            positionRecipient: address(liquidityLock),
            poolParameters: PoolParameters({fee: POOL_FEE, tickSpacing: POOL_TICK_SPACING, hook: poolHook}),
            positionDefinitions: abi.encode(positions),
            lpAllocationSchedule: abi.encode(brackets)
        });

        auctionParams = AuctionParameters({
            currency: address(0),
            tokensRecipient: address(this),
            fundsRecipient: FUNDS_RECIPIENT_SENTINEL,
            startBlock: p.startBlock,
            endBlock: p.endBlock,
            claimBlock: p.claimBlock,
            tickSpacing: p.auctionTickSpacingQ96,
            validationHook: address(0),
            floorPrice: p.floorPriceQ96,
            requiredCurrencyRaised: p.requiredCurrencyRaised,
            auctionStepsData: p.auctionStepsData
        });
    }

    /// @notice Predicts the auction address the strategy will deploy.
    /// @dev The launcher domain-separates the caller's salt as `keccak256(abi.encode(msg.sender,
    ///      salt))` before handing it to the strategy, and the strategy derives the factory salt as
    ///      `keccak256(abi.encode(strategySalt, migrationParams))`. The factory then salts the
    ///      CREATE2 deployment with `keccak256(abi.encode(sender, salt))` where the sender is the
    ///      strategy. All three hops are reproduced here.
    /// @param migrationParams_ The migration parameters.
    /// @param auctionParams The auction parameters.
    /// @param salt The owner-supplied salt.
    /// @return The predicted auction address.
    function _predictAuction(
        MigratorParameters memory migrationParams_,
        AuctionParameters memory auctionParams,
        bytes32 salt
    ) private view returns (address) {
        bytes32 strategySalt = keccak256(abi.encode(address(this), salt));
        bytes32 initializerSalt = keccak256(abi.encode(strategySalt, migrationParams_));
        return auctionFactory.getAddress(
            address(token), AUCTION_ALLOCATION, abi.encode(auctionParams), initializerSalt, address(lbpStrategy)
        );
    }

    /// @notice Approves Permit2 and runs the launcher multicall.
    /// @param migrationParams_ The migration parameters.
    /// @param auctionParams The auction parameters.
    /// @param salt The owner-supplied salt.
    function _execute(MigratorParameters memory migrationParams_, AuctionParameters memory auctionParams, bytes32 salt)
        private
    {
        IERC20(address(token)).forceApprove(address(permit2), LAUNCH_ALLOCATION);
        permit2.approve(address(token), address(launcher), uint160(LAUNCH_ALLOCATION), uint48(block.timestamp + 60));

        bytes memory configData = abi.encode(migrationParams_, abi.encode(auctionParams));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ILiquidityLauncher.depositToken, (address(token), uint160(LAUNCH_ALLOCATION)));
        calls[1] = abi.encodeCall(
            ILiquidityLauncher.distributeToken,
            (
                address(token),
                Distribution({
                    strategy: address(lbpStrategy), amount: uint128(LAUNCH_ALLOCATION), configData: configData
                }),
                salt
            )
        );
        launcher.multicall(calls);

        permit2.approve(address(token), address(launcher), 0, 0);
        IERC20(address(token)).forceApprove(address(permit2), 0);
    }

    // -------------------------------------------------------------------------------------------
    // Internals: state resolution
    // -------------------------------------------------------------------------------------------

    /// @notice The pool key of the official KAY9 pool.
    /// @dev Native ETH sorts first, so it is always currency0. The key is keyed on the canonical
    ///      InitializerHook, which only the LBPStrategy may initialize; that is what stops anyone
    ///      squatting the key before the launch and what makes an initialized pool proof that the
    ///      migration ran.
    /// @return key The official pool key.
    function _officialKey() private view returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: POOL_TICK_SPACING,
            hooks: IHooks(poolHook)
        });
    }

    /// @notice The pool key `recover` rebuilds into when a migration failed.
    /// @dev The official pool can only be created by the strategy, so a migration that reverted
    ///      before `PoolManager.initialize` leaves it non-existent and out of this contract's reach.
    ///      Recovery therefore uses the same pair, fee and spacing with no hook, which this contract
    ///      can initialize itself.
    /// @return key The hookless recovery pool key.
    function _recoveryKey() private view returns (PoolKey memory key) {
        key = _officialKey();
        key.hooks = IHooks(address(0));
    }

    /// @notice Resolves whether migration has been attempted and whether this launch's own
    ///         migration produced a pool.
    /// @dev The InitializerHook stops anyone but the strategy from creating the official pool, but
    ///      the strategy creates it for any registered distribution of KAY9, and it frees the pool
    ///      id before it attempts a migration and never takes it back when that migration reverts.
    ///      An initialized official pool is therefore not on its own proof that *this* launch
    ///      migrated: after a failed migration a stranger holding a little KAY9 can register their
    ///      own distribution on the same key and migrate it. Reading such a pool as this launch's
    ///      would refuse `recover`, refuse `markFailed` and refuse a relaunch, which would leave the
    ///      whole raise in this contract with no code path able to spend it.
    ///
    ///      The discriminator is the raise. A migration that reverts makes the strategy sweep the
    ///      auction's currency and hand all of it to this contract; a migration that succeeds spends
    ///      it on the position instead and returns only dust. The currency side is the one that
    ///      always binds: the auction sold at most its whole allocation at the clearing price, so
    ///      pairing the equally sized liquidity reserve against the raise consumes the raise and
    ///      leaves part of the reserve over, never the other way round. Holding half the raise or
    ///      more therefore means the migration failed, whoever else has since built a pool on the
    ///      key. The answer is still written down by the first of `settle` and `recover` to run,
    ///      because both of them move that balance afterwards.
    /// @return attempted True once the strategy has released the reserved pool id.
    /// @return succeeded True when the pool this launch's migration or recovery produced is
    ///         initialized.
    /// @return key The resolved pool key, or a zeroed key.
    function _migrationOutcome() private view returns (bool attempted, bool succeeded, PoolKey memory key) {
        address currentAuction = auction;
        if (currentAuction == address(0)) return (false, false, key);

        PoolKey memory official = _officialKey();
        PoolId officialId = official.toId();

        attempted = lbpStrategy.registeredPoolIds(officialId) != currentAuction;
        if (!attempted) return (false, false, key);

        if (recovered) return (true, true, _recoveryKey());
        if (outcomeRecorded) return (true, migrationSucceeded, migrationSucceeded ? official : key);

        // A migration attempt checkpoints the auction's end block in both of the strategy's
        // branches, so graduation is final here, and the strategy cannot migrate an auction that
        // did not graduate. An official pool that exists anyway was created by somebody else's
        // distribution of KAY9, and this launch still failed: `settle` must not pour the supply
        // into it, and the relaunch path must stay open.
        if (!_graduated(currentAuction)) return (true, false, key);

        (uint160 officialPrice,,,) = poolManager.getSlot0(officialId);
        if (officialPrice != 0 && !_raiseCameBack(currentAuction)) return (true, true, official);

        return (true, false, key);
    }

    /// @notice Whether the strategy handed the auction's raise back, which is what it does only
    ///         when a migration reverted.
    /// @dev A successful migration leaves this contract with currency dust, several orders of
    ///      magnitude below the raise, so the half-way mark separates the two outcomes with room to
    ///      spare. A reverting read counts as not returned, which keeps a launch whose auction has
    ///      become unreadable out of the recovery path.
    ///
    ///      A balance is something anybody can add to, and this one is read knowing that. Whoever
    ///      gives this contract half the raise, after a good migration and before `settle` has
    ///      written the outcome down, makes that migration read as failed. `settle` then refuses
    ///      and `recover` runs: the gift and the leftover supply go into the hookless pool and are
    ///      locked, the official pool keeps the real raise, and `poolKey` names the recovery pool
    ///      from then on. Nothing is stranded and nothing comes back to the giver, so the price of
    ///      the confusion is half the raise, paid into KAY9 liquidity for good. It is accepted for
    ///      what the alternative costs. Every other signal available here - that the official pool
    ///      exists, that the lock holds a position on it - can be forged in the *other* direction,
    ///      by a stranger's own distribution on the freed key, and reading a failed migration as a
    ///      good one leaves the whole raise in this contract with no code path able to spend it.
    ///      Calling `settle` in the transaction that migrates closes the window entirely.
    /// @param currentAuction The auction to measure against.
    /// @return True when this contract holds at least half of what the auction raised.
    function _raiseCameBack(address currentAuction) private view returns (bool) {
        try IContinuousClearingAuction(currentAuction).currencyRaised() returns (uint256 raised) {
            return raised != 0 && address(this).balance >= raised / 2;
        } catch {
            return false;
        }
    }

    /// @notice Writes the migration outcome down, before the balances it is read from move.
    /// @param succeeded True when this launch's own migration built the official pool.
    function _recordOutcome(bool succeeded) private {
        if (outcomeRecorded) return;
        outcomeRecorded = true;
        migrationSucceeded = succeeded;
        emit MigrationOutcomeRecorded(succeeded);
    }

    /// @notice Whether the auction reached its graduation threshold.
    /// @param currentAuction The auction to query.
    /// @return True when the auction has graduated.
    function _graduated(address currentAuction) private view returns (bool) {
        try IContinuousClearingAuction(currentAuction).isGraduated() returns (bool graduated) {
            return graduated;
        } catch {
            return false;
        }
    }

    /// @notice Whether the auction has checkpointed its end block, after which its graduation can
    ///         no longer change.
    /// @dev Every call that settles an ended auction (`exitBid`, `claimTokens`, both sweeps)
    ///      checkpoints the end block first, and its public `checkpoint()` does so on its own. A
    ///      reverting read counts as not finalized, which keeps the state at AuctionEnded rather
    ///      than declaring a launch failed on no evidence.
    /// @param currentAuction The auction to query.
    /// @return True once the auction's last checkpoint is its end block.
    function _finalized(address currentAuction) private view returns (bool) {
        try IContinuousClearingAuction(currentAuction).lastCheckpointedBlock() returns (uint64 lastBlock) {
            return lastBlock >= _params.endBlock;
        } catch {
            return false;
        }
    }

    /// @notice Makes the strategy give the liquidity reserve back after an auction that did not
    ///         graduate, if nobody has done so yet.
    /// @dev The strategy keeps the reserve and the official pool id registered until `migrate` is
    ///      called on the failed auction. A relaunch needs both released: the reserve because the
    ///      vault must hold the full allocation again, the pool id because the strategy refuses to
    ///      register it twice. Only reached from the relaunch branch, which has already established
    ///      that the auction did not graduate, so the strategy's call can only take its recovery
    ///      branch and never build a pool. If the migration block has not arrived yet the strategy
    ///      reverts, and the relaunch reverts with it, which is the honest answer at that point.
    function _releaseStrategyReserve() private {
        address currentAuction = auction;
        if (currentAuction == address(0)) return;
        if (lbpStrategy.registeredPoolIds(_officialKey().toId()) != currentAuction) return;
        lbpStrategy.migrate(ILBPInitializer(currentAuction));
    }

    /// @notice Claims unsold tokens from the auction if they have not been claimed yet.
    function _sweepUnsoldTokens() private {
        address currentAuction = auction;
        if (currentAuction == address(0)) return;
        if (IContinuousClearingAuction(currentAuction).sweepUnsoldTokensBlock() != 0) return;
        try IContinuousClearingAuction(currentAuction).sweepUnsoldTokens() {} catch {}
    }

    // -------------------------------------------------------------------------------------------
    // Internals: liquidity
    // -------------------------------------------------------------------------------------------

    /// @notice Places the remaining KAY9 balance as a single-sided position, or burns it as dust.
    /// @param key The pool to place liquidity into.
    function _settleRemainder(PoolKey memory key) private {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) {
            settled = true;
            emit UnsoldSettled(0, 0, 0);
            return;
        }
        if (balance < DUST_THRESHOLD) {
            settled = true;
            token.burn(balance);
            emit UnsoldSettled(0, balance, 0);
            return;
        }

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert PoolNotReady();

        // The ladder starts no cheaper than the auction's final clearing price. A currency1-only
        // range holds its tokens in proportion to sqrt(price), so the ticks nearest its anchor hold
        // the most: anchored at spot alone, anyone holding KAY9 could push the price down, call
        // settle and buy a large share of the leftover back below what every bidder paid, all in
        // one transaction. The lower tick of the two is the dearer KAY9 price, and it is always at
        // or below the current tick, so the range stays single-sided.
        int24 clearingTick = TickMath.getTickAtSqrtPrice(
            AuctionPriceLib.toSqrtPriceX96(IContinuousClearingAuction(auction).clearingPrice(), true)
        );
        int24 anchor = clearingTick < currentTick ? clearingTick : currentTick;
        int24 tickUpper = TickRange.floorToSpacing(anchor - POOL_TICK_SPACING, POOL_TICK_SPACING);
        int24 tickLower = TickRange.minUsableTick(POOL_TICK_SPACING);
        if (tickUpper <= tickLower) revert PoolNotReady();

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), balance
        );

        uint128 cap = TickRange.maxLiquidityPerTick(POOL_TICK_SPACING);
        if (liquidity > cap) liquidity = cap;
        if (liquidity == 0) {
            settled = true;
            token.burn(balance);
            emit UnsoldSettled(0, balance, 0);
            return;
        }

        uint256 tokenId = _mintAndLock(key, tickLower, tickUpper, liquidity, 0, uint128(balance), 0);

        uint256 leftover = token.balanceOf(address(this));
        uint256 placed = balance - leftover;
        uint256 burned;
        if (leftover != 0 && leftover < DUST_THRESHOLD) {
            burned = leftover;
            token.burn(leftover);
            leftover = 0;
        }
        settled = leftover == 0;

        emit UnsoldSettled(placed, burned, tokenId);
    }

    /// @notice Mints one position to the liquidity lock and locks it immediately.
    /// @param key The pool to mint into.
    /// @param tickLower The lower tick of the range.
    /// @param tickUpper The upper tick of the range.
    /// @param liquidity The liquidity to mint.
    /// @param amount0Max The most currency0 the mint may consume.
    /// @param amount1Max The most currency1 the mint may consume, which is also the amount handed
    ///        to the position manager up front.
    /// @param nativeValue The ETH forwarded with the call.
    /// @return tokenId The minted position id.
    function _mintAndLock(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 nativeValue
    ) private returns (uint256 tokenId) {
        tokenId = positionManager.nextTokenId();

        if (amount1Max != 0) {
            IERC20(address(token)).safeTransfer(address(positionManager), amount1Max);
        }

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](4);
        params[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(liquidityLock), bytes(""));
        params[1] = abi.encode(key.currency0, ActionConstants.CONTRACT_BALANCE, false);
        params[2] = abi.encode(key.currency1, ActionConstants.CONTRACT_BALANCE, false);
        params[3] = abi.encode(key.currency0, key.currency1, address(this));

        positionManager.modifyLiquidities{value: nativeValue}(abi.encode(actions, params), block.timestamp);

        liquidityLock.lock(tokenId);
    }
}
