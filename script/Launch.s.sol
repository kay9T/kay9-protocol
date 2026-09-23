// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {KAY9Genesis, LaunchParams} from "../src/KAY9Genesis.sol";
import {AuctionSteps} from "../src/libraries/AuctionSteps.sol";
import {AuctionPriceLib} from "../src/libraries/AuctionPriceLib.sol";
import {AggregatorV3Interface} from "../src/interfaces/external/AggregatorV3Interface.sol";
import {ChainAddresses, RobinhoodAddresses} from "./config/RobinhoodAddresses.sol";

/// @title Launch
/// @notice Turns human launch inputs, a floor valuation in dollars, a graduation valuation in
///         dollars and a duration in hours, into the exact `LaunchParams` the genesis vault expects,
///         prints everything a reviewer needs to sanity-check them, and writes the owner Safe's
///         calldata to disk.
/// @dev The script never broadcasts. On Robinhood Chain mainnet the launch transaction is meant to
///      be executed by the owner Safe from the JSON this script produces, not by a script key.
contract Launch is Script {
    /**
     * @notice The cadence, in milliseconds, of the clock the auction reads.
     *
     * @dev 100 ms, the chain's own block cadence, and not 12 s, and the difference is the whole
     *      point of this comment.
     *
     *      Robinhood Chain is an Arbitrum Orbit chain, so a contract sees two block numbers:
     *      `block.number`, the parent chain's height (about every 12 s), and
     *      `ArbSys.arbBlockNumber()`, the chain's own (about every 0.1 s, measured 0.1012 s; what
     *      `eth_blockNumber` and the explorer show). The Continuous Clearing Auction and the LBP
     *      strategy read the second through Uniswap's `BlockNumberish`, and since 2026-09-11 so
     *      does `KAY9Genesis`, for its own validation and for `launchState`.
     *
     *      An earlier revision of this script derived windows at 12 s per block after measuring
     *      `Multicall3.getBlockNumber()`, which returns `block.number`. That measurement was real
     *      and irrelevant: the auction never reads that number. A launch derived that way was
     *      broadcast on testnet on 2026-09-11 and was over before its first bid, because its
     *      1,200-block window ended 105 million blocks in the auction's past. Only the rehearsal
     *      caught it; unit tests and a mainnet fork both run on an EVM where the two clocks are
     *      whatever the test makes them.
     *
     *      100 rather than the measured 101.2 because the floor is the safe side: a window derived
     *      from a slightly-too-fast cadence runs slightly **longer** in wall-clock terms than
     *      requested, never shorter, and for a fair launch an auction that closes early is the
     *      worse failure.
     */
    uint256 internal constant BLOCK_TIME_MS = 100;

    /// @notice The divisor that turns a floor price into the auction's price-tick granularity.
    uint256 internal constant AUCTION_TICK_DIVISOR = 100;

    /// @notice The decimals the derived arithmetic below assumes the ETH/USD answer carries.
    uint8 internal constant FEED_DECIMALS = 8;

    /// @notice The oldest ETH/USD answer the launch parameters may be derived from, in seconds.
    /// @dev The same bound the website applies to the same feed, so the two cannot disagree about
    ///      whether one reading is usable.
    uint256 internal constant MAX_FEED_AGE_SECONDS = 90_000;

    /// @notice The smallest graduation threshold the script will produce: 0.001 ETH.
    /// @dev Far above any migration's rounding dust, far below any real launch (the testnet rehearsal
    ///      raises about 0.0018 ETH; the reference mainnet parameters about 1.8 ETH).
    uint256 internal constant MIN_REQUIRED_RAISE_WEI = 1e15;

    /// @notice Thrown when the Chainlink answer cannot be trusted.
    error BadFeed();

    /// @notice Thrown when the feed does not report its answers with `FEED_DECIMALS` decimals.
    error BadFeedDecimals();

    /// @notice Thrown when the answer is older than `MAX_FEED_AGE_SECONDS`, or is in the future.
    /// @param updatedAt When the feed says the answer was written.
    /// @param nowTimestamp The block timestamp it was compared against.
    error BadFeedAge(uint256 updatedAt, uint256 nowTimestamp);

    /// @notice Thrown when the derived parameters fall outside what the vault accepts.
    /// @param reason A short description.
    error BadParameters(string reason);

    /// @notice Builds and prints the launch parameters.
    /// @return p The derived launch parameters.
    function run() external returns (LaunchParams memory p) {
        ChainAddresses memory book = RobinhoodAddresses.forChain(block.chainid);
        KAY9Genesis genesis = KAY9Genesis(payable(vm.envAddress("GENESIS")));

        uint256 floorFdvUsd = vm.envUint("FLOOR_FDV_USD");
        uint256 graduationFdvUsd = vm.envUint("GRADUATION_FDV_USD");
        uint256 durationHours = vm.envUint("DURATION_HOURS");
        uint256 startDelayMinutes = vm.envUint("START_DELAY_MINUTES");
        bytes32 salt = bytes32(vm.envOr("LAUNCH_SALT", uint256(1)));

        address feedAddress = vm.envOr("ETH_USD_FEED", book.ethUsdFeed);
        // On mainnet the address book is the only source. The checks in `_ethUsd` prove a feed is
        // fresh and scaled right, not that it prices ETH: any other 8-decimal feed passes them, and
        // the floor and the graduation threshold it produces are permanent once signed (gate-6
        // review, Claude Fable 5.1, F-11; the V6 item of the September review).
        if (block.chainid == RobinhoodAddresses.MAINNET_CHAIN_ID && feedAddress != book.ethUsdFeed) {
            revert BadParameters("ETH_USD_FEED must be the canonical feed on mainnet");
        }
        uint256 ethUsdE8 = _ethUsd(feedAddress);

        p = derive(genesis, floorFdvUsd, graduationFdvUsd, durationHours, startDelayMinutes, salt, ethUsdE8);

        (address predicted, uint256 impliedFloorFdvWei, uint256 impliedRaiseWei) = genesis.previewLaunch(p);

        _print(genesis, p, predicted, impliedFloorFdvWei, impliedRaiseWei, ethUsdE8, durationHours);
        console2.log("pool fee                 ", uint256(genesis.POOL_FEE()));
        console2.log("pool tickSpacing         ", uint256(uint24(genesis.POOL_TICK_SPACING())));
        console2.log("pool initializer hook    ", genesis.poolHook());
        _write(genesis, p, predicted);
    }

    /// @notice Derives the parameters from the human inputs. Public so it can be unit tested.
    /// @param genesis The genesis vault.
    /// @param floorFdvUsd The floor valuation in whole US dollars.
    /// @param graduationFdvUsd The graduation valuation in whole US dollars.
    /// @param durationHours The auction duration in hours.
    /// @param startDelayMinutes How long from now the auction starts.
    /// @param salt The launch salt.
    /// @param ethUsdE8 The ETH price in US dollars, scaled by 1e8.
    /// @return p The launch parameters.
    function derive(
        KAY9Genesis genesis,
        uint256 floorFdvUsd,
        uint256 graduationFdvUsd,
        uint256 durationHours,
        uint256 startDelayMinutes,
        bytes32 salt,
        uint256 ethUsdE8
    ) public view returns (LaunchParams memory p) {
        if (graduationFdvUsd < floorFdvUsd) revert BadParameters("graduation below floor");

        // The narrowing casts below would truncate an oversized environment value in silence, and a
        // truncated duration can come out as a perfectly valid window. The inputs are bounded first:
        // the vault allows at most a 24-hour window, and a start more than 30 days out is a typo.
        if (durationHours == 0 || durationHours > 24) revert BadParameters("duration hours out of range");
        if (startDelayMinutes > 30 days / 1 minutes) revert BadParameters("start delay out of range");

        uint64 blocksPerHour = uint64((3600 * 1000) / BLOCK_TIME_MS);
        // The vault validates `startBlock` on the auction's clock, so it is derived from the same.
        uint64 startBlock = uint64(genesis.chainBlockNumber() + (startDelayMinutes * 60 * 1000) / BLOCK_TIME_MS);
        uint64 endBlock = startBlock + uint64(durationHours) * blocksPerHour;

        // FDV in wei = fdvUsd x 1e18 x 1e8 / ethUsdE8.
        uint256 floorFdvWei = (floorFdvUsd * 1e18 * 1e8) / ethUsdE8;
        uint256 graduationFdvWei = (graduationFdvUsd * 1e18 * 1e8) / ethUsdE8;

        uint256 rawFloor = AuctionPriceLib.fdvWeiToPriceQ96(floorFdvWei, genesis.token().TOTAL_SUPPLY());
        uint256 tickSpacing = rawFloor / AUCTION_TICK_DIVISOR;
        if (tickSpacing < 2) revert BadParameters("floor price too small for a tick grid");
        uint256 floorPrice = rawFloor - (rawFloor % tickSpacing);

        // The graduation threshold is the ETH the auction must credit to clear the whole auction
        // supply at the graduation valuation. Credited, not committed: the auction credits a bid
        // through the clearing price and rounds down, so gross bids adding up to exactly this figure
        // can land a wei short, which the 2026-09-21 rehearsal did. The site shows it as the total
        // the auction must reach, never as a bid size that guarantees graduation.
        uint256 graduationPrice = AuctionPriceLib.fdvWeiToPriceQ96(graduationFdvWei, genesis.token().TOTAL_SUPPLY());
        uint256 required = (graduationPrice * genesis.AUCTION_ALLOCATION()) >> 96;
        if (required > type(uint128).max) revert BadParameters("graduation raise out of range");
        // KAY9Genesis tells a failed migration from a successful one by whether it holds half the raise
        // or more, and a successful migration returns rounding dust of a few wei. That test needs a
        // raise many orders of magnitude above the dust; at 1 wei, `raised / 2` is zero and a good
        // migration reads as failed. The contract accepts any non-zero threshold, so the launch
        // parameters are held to this floor here (gate-6 review, 2026-09-23, M-02).
        if (required < MIN_REQUIRED_RAISE_WEI) revert BadParameters("graduation raise below the minimum");

        p = LaunchParams({
            startBlock: startBlock,
            endBlock: endBlock,
            claimBlock: endBlock,
            migrationBlock: endBlock + 1,
            floorPriceQ96: floorPrice,
            auctionTickSpacingQ96: tickSpacing,
            requiredCurrencyRaised: uint128(required),
            auctionStepsData: AuctionSteps.convexSchedule(startBlock, endBlock),
            salt: salt
        });

        (uint256 totalMps, uint64 totalBlocks,) = AuctionSteps.totals(p.auctionStepsData);
        if (totalMps != 1e7) revert BadParameters("emission schedule does not sum to 100 %");
        if (totalBlocks != endBlock - startBlock) revert BadParameters("emission schedule does not span the window");
    }

    /**
     * @notice Reads and validates the Chainlink answer.
     *
     * @dev Every check here is load bearing, and the ones added last are the ones the printed
     *      output cannot compensate for.
     *
     *      **The scale is not assumed.** `latestRoundData` returns an answer scaled by the feed's
     *      own `decimals()`, and everything downstream treats it as 1e8. Pointed at an otherwise
     *      valid 18-decimal aggregator, the derived floor and graduation raise come out 1e10 wrong
     *      — and the script's own "implied floor FDV usd" and "implied raise usd" lines divide by
     *      the same answer they were multiplied by, so they round-trip back to the operator's own
     *      inputs whatever the scale was. The human review this script is built around therefore
     *      cannot see that particular mistake at all. The only defence is to refuse the feed.
     *
     *      **The answer is not allowed to be stale.** `updatedAt != 0` says a round exists, not
     *      that it is recent. The launch economics are permanent once signed, so an answer from
     *      before a large move would set a floor and a graduation threshold nobody agreed to. The
     *      bound matches what the website already enforces on the same feed
     *      (`MAX_ORACLE_AGE_SECONDS` in `apps/web/src/hooks/useLaunch.ts`), so the two cannot
     *      disagree about whether the same reading is usable.
     *
     * @param feedAddress The aggregator.
     * @return The answer scaled by 1e8.
     */
    function _ethUsd(address feedAddress) internal view returns (uint256) {
        if (feedAddress == address(0)) revert BadFeed();
        if (AggregatorV3Interface(feedAddress).decimals() != FEED_DECIMALS) revert BadFeedDecimals();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feedAddress).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) revert BadFeed();
        if (updatedAt > block.timestamp) revert BadFeedAge(updatedAt, block.timestamp);
        if (block.timestamp - updatedAt > MAX_FEED_AGE_SECONDS) revert BadFeedAge(updatedAt, block.timestamp);
        return uint256(answer);
    }

    /// @notice Prints the derived configuration in human terms.
    /// @param p The launch parameters.
    /// @param predicted The predicted auction address.
    /// @param impliedFloorFdvWei The floor valuation in wei.
    /// @param impliedRaiseWei The graduation raise in wei.
    /// @param ethUsdE8 The ETH price used, scaled by 1e8.
    /// @param durationHours The auction duration in hours.
    function _print(
        KAY9Genesis genesis,
        LaunchParams memory p,
        address predicted,
        uint256 impliedFloorFdvWei,
        uint256 impliedRaiseWei,
        uint256 ethUsdE8,
        uint256 durationHours
    ) internal view {
        console2.log("=== KAY9 launch configuration ===");
        console2.log("chainId                  ", block.chainid);
        console2.log("ETH/USD (1e8)            ", ethUsdE8);
        console2.log("current block (auction)  ", genesis.chainBlockNumber());
        console2.log("current block.number     ", block.number);
        console2.log("current unix time        ", block.timestamp);
        console2.log("startBlock               ", p.startBlock);
        console2.log("endBlock                 ", p.endBlock);
        console2.log("claimBlock               ", p.claimBlock);
        console2.log("migrationBlock           ", p.migrationBlock);
        console2.log("duration hours           ", durationHours);
        console2.log("duration blocks          ", p.endBlock - p.startBlock);
        uint256 nowBlock = genesis.chainBlockNumber();
        console2.log("approx start unix        ", block.timestamp + ((p.startBlock - nowBlock) * BLOCK_TIME_MS) / 1000);
        console2.log("approx end unix          ", block.timestamp + ((p.endBlock - nowBlock) * BLOCK_TIME_MS) / 1000);
        console2.log("floorPriceQ96            ", p.floorPriceQ96);
        console2.log("auctionTickSpacingQ96    ", p.auctionTickSpacingQ96);
        console2.log("requiredCurrencyRaised   ", p.requiredCurrencyRaised);
        console2.log("implied floor FDV wei    ", impliedFloorFdvWei);
        console2.log("implied floor FDV usd    ", (impliedFloorFdvWei * ethUsdE8) / 1e18 / 1e8);
        console2.log("implied raise wei        ", impliedRaiseWei);
        console2.log("implied raise usd        ", (impliedRaiseWei * ethUsdE8) / 1e18 / 1e8);
        console2.log("emission steps           ", p.auctionStepsData.length / 8);
        console2.log("predicted auction        ", predicted);
    }

    /// @notice Writes the owner Safe calldata to script/output/launch-calldata.json.
    /// @param genesis The genesis vault.
    /// @param p The launch parameters.
    /// @param predicted The predicted auction address.
    function _write(KAY9Genesis genesis, LaunchParams memory p, address predicted) internal {
        bytes memory calldataBytes = abi.encodeCall(KAY9Genesis.launch, (p));

        string memory json = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(block.chainid),
            ",\n",
            '  "to": "',
            vm.toString(address(genesis)),
            '",\n',
            '  "value": "0",\n',
            '  "data": "',
            vm.toString(calldataBytes),
            '",\n',
            '  "predictedAuction": "',
            vm.toString(predicted),
            '",\n',
            '  "startBlock": ',
            vm.toString(uint256(p.startBlock)),
            ",\n",
            '  "endBlock": ',
            vm.toString(uint256(p.endBlock)),
            ",\n",
            '  "claimBlock": ',
            vm.toString(uint256(p.claimBlock)),
            ",\n",
            '  "migrationBlock": ',
            vm.toString(uint256(p.migrationBlock)),
            ",\n",
            '  "floorPriceQ96": "',
            vm.toString(p.floorPriceQ96),
            '",\n',
            '  "auctionTickSpacingQ96": "',
            vm.toString(p.auctionTickSpacingQ96),
            '",\n',
            '  "requiredCurrencyRaised": "',
            vm.toString(uint256(p.requiredCurrencyRaised)),
            '",\n',
            '  "auctionStepsData": "',
            vm.toString(p.auctionStepsData),
            '",\n',
            '  "salt": "',
            vm.toString(p.salt),
            '"\n',
            "}\n"
        );

        vm.writeFile("script/output/launch-calldata.json", json);
        console2.log("wrote script/output/launch-calldata.json");
    }
}
