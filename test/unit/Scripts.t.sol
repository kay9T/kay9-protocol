// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ComputeVesting} from "../../script/ComputeVesting.s.sol";
import {ChainAddresses, RobinhoodAddresses} from "../../script/config/RobinhoodAddresses.sol";
import {CalendarMonths} from "../../src/libraries/CalendarMonths.sol";

/// @title ScriptsTest
/// @notice Covers the pure parts of the deployment scripts and the address book, so a typo in a
///         canonical address or a mistake in the calendar arithmetic fails the suite rather than
///         the launch.
contract ScriptsTest is Test {
    /// @notice The vesting helper turns a TGE into the two calendar unlocks.
    function test_computeVestingSchedule() public {
        ComputeVesting script = new ComputeVesting();

        // 2026-08-31 12:00:00 UTC, chosen because the six-month target month is too short.
        uint256 tge = CalendarMonths.fromCivil(2026, 8, 31) * 86_400 + 12 hours;
        (uint64 tgeOut, uint64 unlock6m, uint64 unlock12m) = script.compute(tge);

        assertEq(tgeOut, uint64(tge));
        assertLt(tgeOut, unlock6m);
        assertLt(unlock6m, unlock12m);

        (uint256 y, uint256 m, uint256 d) = CalendarMonths.toCivil(uint256(unlock6m) / 86_400);
        assertEq(y, 2027);
        assertEq(m, 2);
        assertEq(d, 28, "clamped to the last day of February");
        assertEq(uint256(unlock6m) % 86_400, 12 hours, "the time of day survives");

        (y, m, d) = CalendarMonths.toCivil(uint256(unlock12m) / 86_400);
        assertEq(y, 2027);
        assertEq(m, 8);
        assertEq(d, 31);
        assertEq(uint256(unlock12m) % 86_400, 12 hours);
    }

    /// @notice The mainnet address book matches the verified canonical addresses.
    function test_mainnetAddressBook() public pure {
        ChainAddresses memory a = RobinhoodAddresses.mainnet();
        assertEq(a.chainId, 4663);
        assertEq(a.poolManager, 0x8366a39CC670B4001A1121B8F6A443A643e40951);
        assertEq(a.positionManager, 0x58daec3116aae6D93017bAAea7749052E8a04fA7);
        assertEq(a.stateView, 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
        assertEq(a.permit2, 0x000000000022D473030F116dDEE9F6B43aC78BA3);
        assertEq(a.liquidityLauncher, 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0);
        assertEq(a.lbpStrategy, 0x05d552391067389EE44fec3924157ed33F976000);
        assertEq(a.initializerHook, 0xD462a559337859369EF271814851A18F496ba000);
        assertEq(a.auctionFactory, 0x000000001F26a0044BaA66024e7b6599c61963F8);
        assertEq(a.feeSplitter, 0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf);
        assertEq(a.beneficiaryVault, 0xd35E9CA72F64C7F93BE30fad67524323396B36D7);
        assertEq(a.compoundingClaimRecipient, 0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a);
        assertEq(a.ethUsdFeed, 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);
        assertEq(a.create2Deployer, 0x4e59b44847b379578588920cA78FbF26c0B4956C);
    }

    /// @notice The testnet book shares the addresses testnet really has and zeroes the rest.
    function test_testnetAddressBook() public pure {
        ChainAddresses memory a = RobinhoodAddresses.testnet();
        ChainAddresses memory m = RobinhoodAddresses.mainnet();
        assertEq(a.chainId, 46_630);
        assertEq(a.poolManager, m.poolManager);
        assertEq(a.positionManager, m.positionManager);
        assertEq(a.permit2, m.permit2);
        assertEq(a.auctionFactory, m.auctionFactory);
        assertEq(a.multicall3, m.multicall3);
        assertEq(a.liquidityLauncher, address(0), "testnet has no launcher");
        assertEq(a.lbpStrategy, address(0), "testnet has no strategy");
        assertEq(a.initializerHook, address(0), "testnet has no initializer hook");
        assertEq(a.feeSplitter, address(0), "testnet has no fee splitter");
        assertEq(a.ethUsdFeed, address(0), "testnet has no Chainlink feed");
    }

    /// @notice An unknown chain has no address book entry.
    function test_unknownChainReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RobinhoodAddresses.UnsupportedChain.selector, uint256(1)));
        this.lookup(1);
    }

    /// @notice External wrapper so the revert can be expected.
    /// @param chainId The chain to look up.
    /// @return The addresses.
    function lookup(uint256 chainId) external pure returns (ChainAddresses memory) {
        return RobinhoodAddresses.forChain(chainId);
    }
}
