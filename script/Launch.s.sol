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
     * @notice The cadence, in milliseconds, of the block number a contract actually sees.
     *
     * @dev This is 12 seconds, not Robinhood Chain's 0.1 seconds, and the difference is the whole
     *      point of this comment.
     *
     *      Robinhood Chain is an Arbitrum Orbit chain, and on an Orbit chain the EVM's
     *      `block.number` is the **Ethereum** block number, not the chain's own. Its own height is
     *      what `eth_blockNumber` returns and what a block explorer shows. Measured on testnet on
     *      2026-09-07: the chain's own height advanced every 0.124 s while `block.number` advanced
     *      every 13.3 s, and `eth_getBlockByNumber` reports both, as `number` and `l1BlockNumber`.
     *
     *      Every block figure in a launch — the start, the end, the claim and the migration — is
     *      compared by the auction and by KAY9Genesis against `block.number`. Deriving them from
     *      the 0.1 s cadence made every window about 130 times too long: a one hour auction
     *      requested on testnet came out as 36,000 blocks, which is five and a half days, and the
     *      four hour mainnet auction this project has documented throughout would have run for
     *      about three weeks. The owner would have signed a launch believing it lasted an
     *      afternoon.
     *
     *      12 seconds rather than the measured 13.3 because 12 is Ethereum's slot time and
     *      therefore the floor: the real cadence is 12 seconds plus whatever slots are missed. A
     *      floor makes the derived window slightly **longer** in wall-clock terms than requested,
     *      never shorter, and for a fair launch an auction that closes early is the worse failure.
     *
     *      Nothing in a unit test or a mainnet fork can catch this, because both run on a local
     *      EVM where `block.number` advances however the test asks it to. It took a real
     *      deployment on the real chain.
     */
    uint256 internal constant BLOCK_TIME_MS = 12_000;

    /// @notice The divisor that turns a floor price into the auction's price-tick granularity.
    uint256 internal constant AUCTION_TICK_DIVISOR = 100;

    /// @notice Thrown when the Chainlink answer cannot be trusted.
    error BadFeed();

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
        uint256 ethUsdE8 = _ethUsd(feedAddress);

        p = derive(genesis, floorFdvUsd, graduationFdvUsd, durationHours, startDelayMinutes, salt, ethUsdE8);

        (address predicted, uint256 impliedFloorFdvWei, uint256 impliedRaiseWei) = genesis.previewLaunch(p);

        _print(p, predicted, impliedFloorFdvWei, impliedRaiseWei, ethUsdE8, durationHours);
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

        uint64 blocksPerHour = uint64((3600 * 1000) / BLOCK_TIME_MS);
        uint64 startBlock = uint64(block.number + (startDelayMinutes * 60 * 1000) / BLOCK_TIME_MS);
        uint64 endBlock = startBlock + uint64(durationHours) * blocksPerHour;

        // FDV in wei = fdvUsd x 1e18 x 1e8 / ethUsdE8.
        uint256 floorFdvWei = (floorFdvUsd * 1e18 * 1e8) / ethUsdE8;
        uint256 graduationFdvWei = (graduationFdvUsd * 1e18 * 1e8) / ethUsdE8;

        uint256 rawFloor = AuctionPriceLib.fdvWeiToPriceQ96(floorFdvWei, genesis.token().TOTAL_SUPPLY());
        uint256 tickSpacing = rawFloor / AUCTION_TICK_DIVISOR;
        if (tickSpacing < 2) revert BadParameters("floor price too small for a tick grid");
        uint256 floorPrice = rawFloor - (rawFloor % tickSpacing);

        // The graduation threshold is the ETH needed to clear the whole auction supply at the
        // graduation valuation, which is what the site displays as the raise target.
        uint256 graduationPrice = AuctionPriceLib.fdvWeiToPriceQ96(graduationFdvWei, genesis.token().TOTAL_SUPPLY());
        uint256 required = (graduationPrice * genesis.AUCTION_ALLOCATION()) >> 96;
        if (required == 0 || required > type(uint128).max) revert BadParameters("graduation raise out of range");

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

    /// @notice Reads and validates the Chainlink answer.
    /// @param feedAddress The aggregator.
    /// @return The answer scaled by 1e8.
    function _ethUsd(address feedAddress) internal view returns (uint256) {
        if (feedAddress == address(0)) revert BadFeed();
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(feedAddress).latestRoundData();
        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) revert BadFeed();
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
        console2.log("current block            ", block.number);
        console2.log("current unix time        ", block.timestamp);
        console2.log("startBlock               ", p.startBlock);
        console2.log("endBlock                 ", p.endBlock);
        console2.log("claimBlock               ", p.claimBlock);
        console2.log("migrationBlock           ", p.migrationBlock);
        console2.log("duration hours           ", durationHours);
        console2.log("duration blocks          ", p.endBlock - p.startBlock);
        console2.log(
            "approx start unix        ", block.timestamp + ((p.startBlock - block.number) * BLOCK_TIME_MS) / 1000
        );
        console2.log(
            "approx end unix          ", block.timestamp + ((p.endBlock - block.number) * BLOCK_TIME_MS) / 1000
        );
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
