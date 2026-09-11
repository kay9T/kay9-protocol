// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BlockNumberish} from "@uniswap/blocknumberish/src/BlockNumberish.sol";
import {AggregatorV3Interface} from "./interfaces/external/AggregatorV3Interface.sol";

/// @notice Everything the website needs to explain why a price is or is not available.
/// @dev failureCode is 0 when available; see KAY9Pricing for the code table.
struct PricingStatus {
    bool available;
    uint256 twapKay9PerEthE18;
    uint256 spotKay9PerEthE18;
    uint256 ethUsdE8;
    uint64 feedUpdatedAt;
    uint32 observationsInWindow;
    uint64 oldestObservationAge;
    uint64 largestGap;
    uint128 poolLiquidity;
    uint8 failureCode;
}

/// @title KAY9Pricing
/// @notice Prices audits in KAY9 against a USD target. Uniswap v4 pools carry no built-in oracle,
///         so this contract keeps its own ring buffer of the official KAY9/ETH pool's tick and
///         combines a time-weighted average of it with the Chainlink ETH/USD feed.
/// @dev Every safety check makes the price unavailable rather than degrading it: a caller either
///      gets a price that passed all of them, or a revert carrying the failure code. The audit hub
///      therefore never charges against a stale, thin or manipulated market.
///
///      Conservatism rule. The KAY9 price in USD is `ethUsd / kay9PerEth`, so a lower KAY9 USD
///      price means more KAY9 per audit. The contract deliberately takes the LOWER of the two
///      candidate KAY9 USD prices, which is the HIGHER of the two KAY9-per-ETH readings. A pump
///      that makes KAY9 look expensive for a single block therefore cannot cheapen an audit,
///      because the pumped reading has the lower KAY9-per-ETH value and is discarded. In the
///      opposite direction a dump would make audits more expensive, so the spot reading is capped
///      at `maxDeviationBps` above the TWAP before it is used.
/// @custom:security-contact security@kay9.io
contract KAY9Pricing is Ownable2Step, BlockNumberish {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @notice One recorded tick sample.
    /// @dev The three fields pack into a single storage slot. `blockNumber` is the chain's own
    ///      height (ArbSys on this Orbit chain), the number an explorer shows.
    struct Observation {
        uint64 blockNumber;
        uint64 timestamp;
        int24 tick;
    }

    /// @notice Emitted for every recorded observation.
    /// @param blockNumber The block the sample was taken in.
    /// @param timestamp The block timestamp of the sample.
    /// @param tick The pool tick at that moment.
    event Observed(uint64 indexed blockNumber, uint64 timestamp, int24 tick);

    /// @notice Emitted once, when the official pool is bound to this contract.
    /// @param poolId The bound pool id.
    event PoolConfigured(bytes32 indexed poolId);

    /// @notice Emitted when a tier's USD target changes.
    /// @param tier The tier index.
    /// @param usdE8 The new target in USD, scaled by 1e8. Zero deactivates the tier.
    event TargetUpdated(uint8 indexed tier, uint256 usdE8);

    /// @notice Emitted when the oracle safety parameters change.
    /// @param twapWindow The averaging window in seconds.
    /// @param minObservations The minimum samples inside the window.
    /// @param maxObservationGap The largest tolerated gap between samples, in seconds.
    /// @param minPoolLiquidity The minimum in-range pool liquidity.
    /// @param maxDeviationBps The cap on how far spot may sit above the TWAP.
    /// @param maxFeedAge The maximum tolerated Chainlink answer age, in seconds.
    event ParamsUpdated(
        uint32 twapWindow,
        uint32 minObservations,
        uint32 maxObservationGap,
        uint128 minPoolLiquidity,
        uint16 maxDeviationBps,
        uint32 maxFeedAge
    );

    /// @notice Emitted when the ETH/USD feed address changes.
    /// @param feed The new feed.
    event FeedUpdated(address feed);

    /// @notice Thrown by every price getter when at least one safety check fails.
    /// @param code The failure code, matching the table in the contract documentation.
    error PricingUnavailable(uint8 code);

    /// @notice Thrown when a constructor or setter argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when configurePool is called more than once.
    error PoolAlreadyConfigured();

    /// @notice Thrown when the configured pool does not pair native ETH with KAY9.
    error NotTheKay9Pool();

    /// @notice Thrown when the configured pool has never been initialized.
    error PoolNotInitialized();

    /// @notice Thrown when a tier has no USD target and therefore cannot be priced.
    /// @param tier The inactive tier.
    error InactiveTier(uint8 tier);

    /// @notice Thrown when a safety parameter is outside its allowed range.
    error InvalidParams();

    /// @notice The free tier. It is never priced on-chain.
    uint8 public constant TIER_BASIC = 0;

    /// @notice The paid deep audit tier.
    uint8 public constant TIER_DEEP = 1;

    /// @notice The forensic tier, inactive until a USD target is set.
    uint8 public constant TIER_FORENSIC = 2;

    /// @notice The number of observation slots in the ring buffer.
    uint256 public constant CARDINALITY = 2048;

    /// @notice The official pool fee, in hundredths of a basis point. 10000 is 1 %.
    /// @dev Mirrors `KAY9Genesis.POOL_FEE`. The oracle only ever prices the official pool, and a
    ///      pool at another fee is a different market that governance must not be able to bind by
    ///      mistake; the hook is left free because `recover` legitimately builds a hookless pool.
    uint24 public constant POOL_FEE = 10_000;

    /// @notice The official pool tick spacing. Mirrors `KAY9Genesis.POOL_TICK_SPACING`.
    int24 public constant POOL_TICK_SPACING = 200;

    /// @notice The shortest interval between two recorded samples, in seconds.
    /// @dev Robinhood Chain produces a block roughly every 0.1 s, so a one-sample-per-block rule on
    ///      its own lets anyone overwrite the whole ring buffer in about three and a half minutes
    ///      and leave the averaging window uncovered, which makes every price permanently
    ///      unavailable for as long as the flood lasts. This floor bounds the buffer's turnover at
    ///      `CARDINALITY * MIN_OBSERVATION_INTERVAL` = 8192 s, which is above MAX_TWAP_WINDOW, so a
    ///      full buffer always spans more than the widest configurable window.
    uint64 public constant MIN_OBSERVATION_INTERVAL = 4;

    /// @notice The narrowest averaging window governance may configure, in seconds.
    uint32 public constant MIN_TWAP_WINDOW = 15 minutes;

    /// @notice The widest averaging window governance may configure, in seconds.
    uint32 public constant MAX_TWAP_WINDOW = 120 minutes;

    /// @notice The Uniswap v4 pool manager holding the official pool.
    IPoolManager public immutable poolManager;

    /// @notice The KAY9 token. The configured pool must pair it with native ETH.
    address public immutable kay9;

    /// @notice The Chainlink ETH/USD aggregator.
    AggregatorV3Interface public feed;

    /// @notice The official pool key, set once by configurePool.
    PoolKey public poolKey;

    /// @notice The id of the official pool, or zero before configuration.
    PoolId public poolId;

    /// @notice Whether the official pool has been bound.
    bool public poolConfigured;

    /// @notice The averaging window in seconds.
    uint32 public twapWindow;

    /// @notice The minimum number of samples that must sit inside the window.
    uint32 public minObservations;

    /// @notice The largest tolerated gap between consecutive samples, in seconds.
    uint32 public maxObservationGap;

    /// @notice The minimum in-range liquidity the pool must carry.
    uint128 public minPoolLiquidity;

    /// @notice How far above the TWAP the spot reading may sit before it is capped, in bps.
    uint16 public maxDeviationBps;

    /// @notice The maximum tolerated Chainlink answer age, in seconds.
    uint32 public maxFeedAge;

    /// @notice The USD target of each tier, scaled by 1e8. Zero means the tier is inactive.
    mapping(uint8 tier => uint256 usdE8) public usdTarget;

    /// @notice The ring buffer of tick samples.
    Observation[CARDINALITY] private _observations;

    /// @notice The index of the most recent sample.
    uint16 private _index;

    /// @notice The number of samples stored, saturating at CARDINALITY.
    uint32 private _count;

    /// @notice Deploys the pricing oracle with the launch defaults.
    /// @param owner_ The owner, which in production is the TimelockController.
    /// @param poolManager_ The Uniswap v4 pool manager.
    /// @param kay9_ The KAY9 token.
    /// @param feed_ The Chainlink ETH/USD aggregator.
    /// @param deepAccessUsdE8 The USD value of KAY9 a deep access lock must hold, scaled by 1e8.
    /// @param forensicAccessUsdE8 The USD value of KAY9 a forensic access lock must hold, by 1e8.
    constructor(
        address owner_,
        IPoolManager poolManager_,
        address kay9_,
        AggregatorV3Interface feed_,
        uint256 deepAccessUsdE8,
        uint256 forensicAccessUsdE8
    ) Ownable(owner_) {
        if (address(poolManager_) == address(0) || kay9_ == address(0) || address(feed_) == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        kay9 = kay9_;
        feed = feed_;

        twapWindow = 1800;
        minObservations = 10;
        maxObservationGap = 300;
        minPoolLiquidity = 1e15;
        maxDeviationBps = 5000;
        maxFeedAge = 90_000;

        usdTarget[TIER_DEEP] = deepAccessUsdE8;
        usdTarget[TIER_FORENSIC] = forensicAccessUsdE8;

        emit FeedUpdated(address(feed_));
        emit ParamsUpdated(1800, 10, 300, 1e15, 5000, 90_000);
        emit TargetUpdated(TIER_DEEP, deepAccessUsdE8);
        emit TargetUpdated(TIER_FORENSIC, forensicAccessUsdE8);
    }

    // -------------------------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------------------------

    /// @notice Binds the official KAY9/ETH pool. Callable once.
    /// @dev The pool must already be initialized, must pair native ETH as currency0 with KAY9 as
    ///      currency1 (the only ordering possible because the zero address sorts first), and must
    ///      carry the official fee and tick spacing. Either the hooked pool the launch migrates
    ///      into or the hookless pool `recover` builds satisfies that; a pool at another fee does
    ///      not, whoever proposes it.
    /// @param key The pool key of the official pool.
    function configurePool(PoolKey calldata key) external onlyOwner {
        if (poolConfigured) revert PoolAlreadyConfigured();
        if (Currency.unwrap(key.currency0) != address(0)) revert NotTheKay9Pool();
        if (Currency.unwrap(key.currency1) != kay9) revert NotTheKay9Pool();
        if (key.fee != POOL_FEE || key.tickSpacing != POOL_TICK_SPACING) revert NotTheKay9Pool();

        PoolId id = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        poolKey = key;
        poolId = id;
        poolConfigured = true;
        emit PoolConfigured(PoolId.unwrap(id));

        _record(tick);
    }

    /// @notice Sets a tier's USD target.
    /// @param tier The tier index.
    /// @param usdE8 The target in USD scaled by 1e8. Zero deactivates the tier.
    function setUsdTarget(uint8 tier, uint256 usdE8) external onlyOwner {
        usdTarget[tier] = usdE8;
        emit TargetUpdated(tier, usdE8);
    }

    /// @notice Sets every oracle safety parameter at once.
    /// @param twapWindow_ The averaging window in seconds, within [MIN_TWAP_WINDOW, MAX_TWAP_WINDOW].
    /// @param minObservations_ The minimum samples inside the window. Must be at least two.
    /// @param maxObservationGap_ The largest tolerated gap between samples, in seconds.
    /// @param minPoolLiquidity_ The minimum in-range liquidity.
    /// @param maxDeviationBps_ The spot cap above the TWAP, in bps, at most 10000.
    /// @param maxFeedAge_ The maximum Chainlink answer age in seconds. Must exceed the 86400 s heartbeat.
    function setParams(
        uint32 twapWindow_,
        uint32 minObservations_,
        uint32 maxObservationGap_,
        uint128 minPoolLiquidity_,
        uint16 maxDeviationBps_,
        uint32 maxFeedAge_
    ) external onlyOwner {
        if (twapWindow_ < MIN_TWAP_WINDOW || twapWindow_ > MAX_TWAP_WINDOW) revert InvalidParams();
        if (minObservations_ < 2 || minObservations_ > CARDINALITY) revert InvalidParams();
        // A tolerated gap below the sampling floor could never be met, which would make every
        // price permanently unavailable.
        if (maxObservationGap_ < MIN_OBSERVATION_INTERVAL || maxObservationGap_ > twapWindow_) revert InvalidParams();
        if (maxDeviationBps_ > 10_000) revert InvalidParams();
        if (maxFeedAge_ < 86_400) revert InvalidParams();

        twapWindow = twapWindow_;
        minObservations = minObservations_;
        maxObservationGap = maxObservationGap_;
        minPoolLiquidity = minPoolLiquidity_;
        maxDeviationBps = maxDeviationBps_;
        maxFeedAge = maxFeedAge_;

        emit ParamsUpdated(
            twapWindow_, minObservations_, maxObservationGap_, minPoolLiquidity_, maxDeviationBps_, maxFeedAge_
        );
    }

    /// @notice Replaces the Chainlink ETH/USD aggregator.
    /// @param feed_ The new aggregator.
    function setFeed(AggregatorV3Interface feed_) external onlyOwner {
        if (address(feed_) == address(0)) revert ZeroAddress();
        feed = feed_;
        emit FeedUpdated(address(feed_));
    }

    // -------------------------------------------------------------------------------------------
    // Observation
    // -------------------------------------------------------------------------------------------

    /// @notice Records the current pool tick. Permissionless.
    /// @dev At most one sample per block is kept, and never more than one per
    ///      MIN_OBSERVATION_INTERVAL seconds; a call that arrives too soon is a no-op so a keeper
    ///      batching transactions never reverts, and so nobody can churn the ring buffer faster
    ///      than the averaging window. Requires the pool to be configured and initialized.
    function poke() external {
        if (!poolConfigured) revert PricingUnavailable(1);
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PricingUnavailable(1);
        if (_count != 0) {
            Observation memory latest = _observations[_index];
            if (latest.blockNumber == uint64(_getBlockNumberish())) return;
            if (uint64(block.timestamp) - latest.timestamp < MIN_OBSERVATION_INTERVAL) return;
        }
        _record(tick);
    }

    /// @notice The number of samples currently held in the ring buffer.
    /// @return The stored sample count, saturating at CARDINALITY.
    function observationCount() external view returns (uint256) {
        return _count;
    }

    /// @notice Reads one sample, counting back from the most recent.
    /// @param age Zero for the newest sample, one for the one before it, and so on.
    /// @return The requested sample.
    function observationAt(uint256 age) external view returns (Observation memory) {
        require(age < _count, "no observation");
        return _observations[_ringIndex(age)];
    }

    // -------------------------------------------------------------------------------------------
    // Pricing
    // -------------------------------------------------------------------------------------------

    /// @notice The full state of every safety check, for display and diagnostics.
    /// @dev Never reverts. When available is false, the price fields may be zero.
    /// @return status The evaluated pricing status.
    function pricingStatus() public view returns (PricingStatus memory status) {
        if (!poolConfigured) {
            status.failureCode = 1;
            return status;
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            status.failureCode = 1;
            return status;
        }
        status.spotKay9PerEthE18 = _kay9PerEthFromSqrtPrice(sqrtPriceX96);
        status.poolLiquidity = poolManager.getLiquidity(poolId);

        (uint256 twapKay9PerEth, uint32 observationsInWindow, uint64 oldestAge, uint64 largestGap, uint8 twapCode) =
            _twap();
        status.twapKay9PerEthE18 = twapKay9PerEth;
        status.observationsInWindow = observationsInWindow;
        status.oldestObservationAge = oldestAge;
        status.largestGap = largestGap;

        (uint256 ethUsdE8, uint64 updatedAt, uint8 feedCode) = _ethUsd();
        status.ethUsdE8 = ethUsdE8;
        status.feedUpdatedAt = updatedAt;

        if (twapCode != 0) {
            status.failureCode = twapCode;
            return status;
        }
        // A pool sitting so deep in the sqrt-price extremes that a KAY9-per-ETH reading truncates
        // to zero is not a pool anything can be quoted against: every tier would come out free.
        if (status.twapKay9PerEthE18 == 0 || status.spotKay9PerEthE18 == 0) {
            status.failureCode = 1;
            return status;
        }
        if (status.poolLiquidity < minPoolLiquidity) {
            status.failureCode = 4;
            return status;
        }
        if (feedCode != 0) {
            status.failureCode = feedCode;
            return status;
        }

        status.available = true;
    }

    /// @notice The KAY9 price in USD, scaled by 1e8.
    /// @dev Reverts with PricingUnavailable when any safety check fails.
    /// @return The KAY9 USD price scaled by 1e8.
    function getKay9UsdPriceE8() external view returns (uint256) {
        (uint256 kay9PerEth, uint256 ethUsdE8) = _checkedInputs();
        return FullMath.mulDiv(ethUsdE8, 1e18, kay9PerEth);
    }

    /// @notice The KAY9 that is currently worth a tier's USD target.
    /// @dev This is the size of an access lock, not a fee. Nothing is ever charged; the number
    ///      answers "how much KAY9 is worth 100 dollars right now" at the moment a lock opens,
    ///      and is then frozen for that access period by KAY9AccessVault.
    ///
    ///      Computed as `usdTarget * kay9PerEth / ethUsd` in one full-precision step, so it
    ///      does not lose precision through an intermediate 1e8-scaled KAY9 price.
    /// @param tier The tier to quote.
    /// @return The required KAY9 amount, in 18-decimal wei.
    function getPriceInKay9(uint8 tier) public view returns (uint256) {
        uint256 target = usdTarget[tier];
        if (target == 0) revert InactiveTier(tier);
        (uint256 kay9PerEth, uint256 ethUsdE8) = _checkedInputs();
        return FullMath.mulDiv(target, kay9PerEth, ethUsdE8);
    }

    /// @notice The KAY9 a deep access lock currently requires.
    /// @return The required KAY9 amount, in 18-decimal wei.
    function getDeepAccessRequirement() external view returns (uint256) {
        return getPriceInKay9(TIER_DEEP);
    }

    /// @notice The KAY9 a forensic access lock currently requires.
    /// @return The required KAY9 amount, in 18-decimal wei.
    function getForensicAccessRequirement() external view returns (uint256) {
        return getPriceInKay9(TIER_FORENSIC);
    }

    // -------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------

    /// @notice Runs every safety check and returns the inputs the price formulas need.
    /// @return kay9PerEth The conservative KAY9-per-ETH reading, scaled by 1e18.
    /// @return ethUsdE8 The Chainlink ETH/USD answer, scaled by 1e8.
    function _checkedInputs() private view returns (uint256 kay9PerEth, uint256 ethUsdE8) {
        PricingStatus memory status = pricingStatus();
        if (!status.available) revert PricingUnavailable(status.failureCode);

        uint256 twap = status.twapKay9PerEthE18;
        uint256 spot = status.spotKay9PerEthE18;

        // Cap the spot reading so a single-block dump cannot inflate the cost of an audit.
        uint256 cap = FullMath.mulDiv(twap, 10_000 + maxDeviationBps, 10_000);
        if (spot > cap) spot = cap;

        // Take the higher KAY9-per-ETH reading, which is the lower KAY9 USD price.
        kay9PerEth = spot > twap ? spot : twap;
        ethUsdE8 = status.ethUsdE8;
    }

    /// @notice Reads and validates the Chainlink answer.
    /// @return ethUsdE8 The answer scaled by 1e8, or zero on failure.
    /// @return updatedAt The answer timestamp.
    /// @return code Zero when valid, 6 when the answer is malformed, 5 when it is stale.
    function _ethUsd() private view returns (uint256 ethUsdE8, uint64 updatedAt, uint8 code) {
        try feed.latestRoundData() returns (
            uint80 roundId, int256 answer, uint256, uint256 updatedAt_, uint80 answeredInRound
        ) {
            updatedAt = uint64(updatedAt_);
            if (answer <= 0 || updatedAt_ == 0 || answeredInRound < roundId) return (0, updatedAt, 6);
            if (updatedAt_ > block.timestamp || block.timestamp - updatedAt_ > maxFeedAge) {
                return (uint256(answer), updatedAt, 5);
            }
            return (uint256(answer), updatedAt, 0);
        } catch {
            return (0, 0, 6);
        }
    }

    /// @notice Computes the time-weighted average tick over the window and converts it to a price.
    /// @dev The integral treats each sample's tick as constant until the next sample, exactly like
    ///      the v3 tickCumulative accumulator, and the trailing segment runs from the newest sample
    ///      to the current timestamp. The arithmetic mean is floored toward negative infinity.
    /// @return kay9PerEth The averaged KAY9-per-ETH price scaled by 1e18, or zero on failure.
    /// @return observationsInWindow The number of samples inside the window.
    /// @return oldestAge The age of the oldest stored sample, in seconds.
    /// @return largestGap The widest gap between consecutive samples inside the window.
    /// @return code Zero when valid, 2 for too few samples, 3 for too wide a gap, 7 when the window
    ///         is not fully covered by stored samples.
    function _twap()
        private
        view
        returns (uint256 kay9PerEth, uint32 observationsInWindow, uint64 oldestAge, uint64 largestGap, uint8 code)
    {
        uint32 count = _count;
        uint32 window = twapWindow;
        if (count < 2) return (0, count, 0, 0, 2);

        uint64 nowTs = uint64(block.timestamp);
        uint64 windowStart = nowTs > window ? nowTs - window : 0;

        Observation memory oldest = _observations[_ringIndex(count - 1)];
        oldestAge = nowTs - oldest.timestamp;

        // Walk backwards from the newest sample, accumulating tick * duration.
        int256 weighted;
        uint64 segmentEnd = nowTs;
        uint32 inWindow;
        bool covered;

        for (uint32 age = 0; age < count; ++age) {
            Observation memory observation = _observations[_ringIndex(age)];
            uint64 segmentStart = observation.timestamp;
            uint64 gap = segmentEnd - segmentStart;
            if (gap > largestGap) largestGap = gap;

            if (segmentStart <= windowStart) {
                weighted += int256(observation.tick) * int256(uint256(segmentEnd - windowStart));
                covered = true;
                break;
            }

            weighted += int256(observation.tick) * int256(uint256(gap));
            ++inWindow;
            segmentEnd = segmentStart;
        }

        observationsInWindow = inWindow;

        if (!covered) return (0, inWindow, oldestAge, largestGap, 7);
        if (inWindow < minObservations) return (0, inWindow, oldestAge, largestGap, 2);
        if (largestGap > maxObservationGap) return (0, inWindow, oldestAge, largestGap, 3);

        int256 divisor = int256(uint256(nowTs - windowStart));
        int256 meanTick = weighted / divisor;
        if (weighted < 0 && weighted % divisor != 0) --meanTick;

        if (meanTick < TickMath.MIN_TICK) meanTick = TickMath.MIN_TICK;
        if (meanTick > TickMath.MAX_TICK) meanTick = TickMath.MAX_TICK;

        kay9PerEth = _kay9PerEthFromSqrtPrice(TickMath.getSqrtPriceAtTick(int24(meanTick)));
    }

    /// @notice Converts a v4 sqrt price into KAY9 per ETH.
    /// @dev currency0 is native ETH and currency1 is KAY9, so `(sqrtP / 2^96)^2` is already the
    ///      amount of KAY9 one ETH buys.
    /// @param sqrtPriceX96 The pool sqrt price.
    /// @return The KAY9-per-ETH price scaled by 1e18.
    function _kay9PerEthFromSqrtPrice(uint160 sqrtPriceX96) private pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), FixedPoint96.Q96);
        return FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96);
    }

    /// @notice Writes a sample into the ring buffer.
    /// @param tick The pool tick to record.
    function _record(int24 tick) private {
        int24 recorded = tick;
        uint32 count = _count;
        uint16 next = count == 0 ? 0 : uint16((_index + 1) % CARDINALITY);
        uint64 blockNumber = uint64(_getBlockNumberish());
        _observations[next] =
            Observation({blockNumber: blockNumber, timestamp: uint64(block.timestamp), tick: recorded});
        _index = next;
        if (count < CARDINALITY) _count = count + 1;

        emit Observed(blockNumber, uint64(block.timestamp), recorded);
    }

    /// @notice Maps an age in samples to a ring-buffer index.
    /// @param age Zero for the newest sample.
    /// @return The ring-buffer index.
    function _ringIndex(uint256 age) private view returns (uint256) {
        return (uint256(_index) + CARDINALITY - age) % CARDINALITY;
    }
}
