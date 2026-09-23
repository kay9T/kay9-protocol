// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9LiquidityLock} from "../../src/KAY9LiquidityLock.sol";
import {KAY9Genesis, LaunchParams} from "../../src/KAY9Genesis.sol";
import {IBeneficiaryVault} from "../../src/interfaces/uniswap/IBeneficiaryVault.sol";
import {IContinuousClearingAuction} from "../../src/interfaces/uniswap/IContinuousClearingAuction.sol";
import {ILBPInitializer} from "liquidity-launcher/src/interfaces/ILBPInitializer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @title KAY9LiquidityLockTest
/// @notice Proves the lock is a one-way door with no path back to the owner.
contract KAY9LiquidityLockTest is Kay9TestBase {
    /// @notice A four-hour auction on the auction's own clock: 14,400 s at the chain's 0.1 s cadence.
    /// @dev The auction reads `ArbSys.arbBlockNumber()` through Uniswap's `BlockNumberish`, and so
    ///      does `KAY9Genesis`; neither reads `block.number`, which on this Orbit chain is the
    ///      parent chain's height. See the note on `KAY9Genesis.MIN_DURATION_BLOCKS`.
    uint64 internal constant FOUR_HOURS_BLOCKS = 144_000;

    /// @notice A one-thousand-dollar floor valuation, expressed in wei at 2500 dollars per ETH.
    uint256 internal constant FLOOR_FDV_WEI = 0.4e18;

    /// @notice The lock is wired to the canonical addresses and has no owner.
    function test_immutableWiring() public {
        assertEq(address(lock.positionManager()), address(uni.positionManager));
        assertEq(lock.feeSplitter(), address(uni.feeSplitter));
        assertEq(address(lock.beneficiaryVault()), address(uni.beneficiaryVault));
        assertEq(lock.creatorFeeRecipient(), creatorFeeRecipient);

        string[5] memory signatures =
            ["owner()", "withdraw(uint256)", "rescue(address,uint256)", "setFeeSplitter(address)", "transfer(uint256)"];
        for (uint256 i = 0; i < signatures.length; ++i) {
            (bool ok,) = address(lock).call(abi.encodeWithSelector(bytes4(keccak256(bytes(signatures[i])))));
            assertFalse(ok, signatures[i]);
        }
    }

    /// @notice The lock refuses NFTs from anything but the canonical position manager.
    function test_rejectsForeignNfts() public {
        vm.expectRevert(abi.encodeWithSelector(KAY9LiquidityLock.NotPositionManager.selector, address(this)));
        lock.onERC721Received(address(this), address(this), 1, "");
    }

    /// @notice The lock refuses to lock a position it does not own.
    function test_rejectsUnownedPosition() public {
        vm.expectRevert();
        lock.lock(1);
        vm.expectRevert();
        lock.track(1);
    }

    /// @notice Locking registers the creator fee beneficiary and then hands the NFT away for good.
    function test_lockIsOneWay() public {
        uint256 tokenId = _migrateAndGetPosition();

        assertEq(IERC721(address(uni.positionManager)).ownerOf(tokenId), address(lock));
        lock.lock(tokenId);

        assertEq(uni.beneficiaryVault.ownerOf(tokenId), creatorFeeRecipient, "beneficiary minted");
        assertEq(IERC721(address(uni.positionManager)).ownerOf(tokenId), address(uni.feeSplitter));
        assertTrue(lock.isLocked(tokenId));
        assertEq(lock.lockedCount(), 1);
        assertEq(lock.lockedTokenIds(0), tokenId);

        // Nothing, not even the owner Safe, can pull the position back.
        vm.prank(owner);
        vm.expectRevert();
        IERC721(address(uni.positionManager)).transferFrom(address(uni.feeSplitter), owner, tokenId);
    }

    /// @notice Locking is permissionless.
    function test_lockIsPermissionless() public {
        uint256 tokenId = _migrateAndGetPosition();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        lock.lock(tokenId);
        assertTrue(lock.isLocked(tokenId));
    }

    /// @notice A position whose beneficiary was already registered is still locked.
    /// @dev The vault only accepts a registration from the current position owner, so the only way
    ///      this happens is a registration the lock itself performed earlier in the same flow.
    function test_lockSkipsExistingBeneficiary() public {
        uint256 tokenId = _migrateAndGetPosition();

        // Simulate the registration already existing by having the lock do it out of band.
        vm.prank(address(lock));
        uni.beneficiaryVault.registerBeneficiary(tokenId, creatorFeeRecipient);
        assertEq(uni.beneficiaryVault.ownerOf(tokenId), creatorFeeRecipient);

        lock.lock(tokenId);
        assertEq(IERC721(address(uni.positionManager)).ownerOf(tokenId), address(uni.feeSplitter));
    }

    /// @notice lockAll skips ids the lock no longer owns and ids already locked.
    function test_lockAllIsResilient() public {
        uint256 tokenId = _migrateAndGetPosition();
        lock.track(tokenId);
        lock.lockAll();
        assertTrue(lock.isLocked(tokenId));
        // A second sweep is a no-op rather than a revert.
        lock.lockAll();
    }

    /// @notice Runs a launch to migration and returns the minted position id.
    /// @return The position id the strategy minted to the lock.
    function _migrateAndGetPosition() internal returns (uint256) {
        LaunchParams memory p = _launchParams(FLOOR_FDV_WEI, FOUR_HOURS_BLOCKS);
        vm.prank(owner);
        genesis.launch(p);

        IContinuousClearingAuction auction = IContinuousClearingAuction(genesis.auction());
        uint128 amount = uint128(uint256(p.requiredCurrencyRaised) * 3);
        uint256 price = p.floorPriceQ96 * 8;
        price -= price % p.auctionTickSpacingQ96;

        vm.roll(p.startBlock + FOUR_HOURS_BLOCKS / 2);
        address bidder = makeAddr("bidder");
        vm.deal(bidder, amount);
        vm.prank(bidder);
        auction.submitBid{value: amount}(price, amount, bidder, "");

        vm.roll(p.endBlock);
        auction.checkpoint();
        vm.roll(p.migrationBlock);
        uni.lbpStrategy.migrate(ILBPInitializer(address(auction)));

        return uni.positionManager.nextTokenId() - 1;
    }

    /// @notice A splitter that does not pay the beneficiary vault, or answers to another
    ///         PositionManager, is refused at construction (F-5).
    function test_refusesAMisWiredFeeSplitter() public {
        vm.expectRevert(KAY9LiquidityLock.FeeSplitterMisWired.selector);
        new KAY9LiquidityLock(
            uni.positionManager, address(uni.feeSplitter), IBeneficiaryVault(address(0xBEEF)), creatorFeeRecipient
        );

        vm.mockCall(address(uni.feeSplitter), abi.encodeWithSignature("positionManager()"), abi.encode(address(0xCAFE)));
        vm.expectRevert(KAY9LiquidityLock.FeeSplitterMisWired.selector);
        new KAY9LiquidityLock(
            uni.positionManager,
            address(uni.feeSplitter),
            IBeneficiaryVault(address(uni.beneficiaryVault)),
            creatorFeeRecipient
        );
    }
}
