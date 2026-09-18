// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9AccessVault, Access} from "../../src/KAY9AccessVault.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title KAY9AccessVaultTest
/// @notice Covers the access lock: what it takes, when it gives it back, and the fact that nothing
///         and nobody can send a depositor's principal anywhere except back to the depositor.
/// @dev Access is a lock, not a payment, so almost every assertion here is an exact balance. The
///      oracle is only ever read when a period opens, which is why the frozen-requirement and
///      outage tests move the price hard and then check that nothing about a live period changed.
contract KAY9AccessVaultTest is Kay9TestBase {
    /// @notice Expiry of an old job cannot refund quota spent in a renewed access period.
    function test_restoreOldPeriodDoesNotChangeRenewedQuota() public {
        _grantAccess(alice, TIER_DEEP);
        uint64 oldPeriod = accessVault.accessOf(alice).startedAt;
        vm.prank(address(hub));
        accessVault.consume(alice, TIER_DEEP);

        _warpPastExpiry(alice);
        _fundKay9(alice, 1_000_000 ether);
        vm.prank(alice);
        token.approve(address(accessVault), type(uint256).max);
        vm.prank(alice);
        accessVault.renew(TIER_DEEP, type(uint256).max);
        vm.prank(address(hub));
        accessVault.consume(alice, TIER_DEEP);

        Access memory renewed = accessVault.accessOf(alice);
        assertGt(renewed.startedAt, oldPeriod);
        assertEq(renewed.deepUsed, 1);
        vm.prank(address(hub));
        accessVault.restore(alice, TIER_DEEP, oldPeriod);
        assertEq(accessVault.accessOf(alice).deepUsed, 1, "old period does not refund new quota");
        assertEq(accessVault.accessOf(alice).lockedKay9, renewed.lockedKay9, "principal is unchanged");

        vm.prank(address(hub));
        accessVault.restore(alice, TIER_DEEP, renewed.startedAt);
        assertEq(accessVault.accessOf(alice).deepUsed, 0, "current period can restore its own quota");
    }

    /// @notice A depositor.
    address internal alice = makeAddr("alice");

    /// @notice A second depositor, so the accounting is never tested with a single balance.
    address internal bob = makeAddr("bob");

    /// @notice The chain key of the asset the requests in these tests name.
    bytes32 internal chainKey;

    /// @notice The asset identifier the requests in these tests name.
    bytes32 internal assetId = bytes32(uint256(uint160(0xA55E7)));

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();
        chainKey = reportRegistry.CHAIN_ROBINHOOD();
    }

    // -------------------------------------------------------------------------------------------
    // The shape of the deployment
    // -------------------------------------------------------------------------------------------

    /// @notice The constants the tests mirror are the constants the contracts really use, and the
    ///         vault is wired to the token and the hub the deployment script gives it.
    function test_theMirroredConstantsMatchTheContracts() public view {
        assertEq(accessVault.TIER_DEEP(), TIER_DEEP, "the deep tier");
        assertEq(accessVault.TIER_FORENSIC(), TIER_FORENSIC, "the forensic tier");
        assertEq(hub.REQUESTER_UNKNOWN(), KIND_UNKNOWN, "the unknown requester kind");
        assertEq(hub.REQUESTER_INDEPENDENT(), KIND_INDEPENDENT, "the independent requester kind");
        assertEq(hub.REQUESTER_CREATOR(), KIND_CREATOR, "the creator requester kind");
        assertEq(hub.REQUESTER_INTEGRATION(), KIND_INTEGRATION, "the integration requester kind");

        assertEq(accessVault.lockDuration(), 30 days, "a period lasts thirty days");
        assertEq(accessVault.deepQuotaOf(TIER_DEEP), 4, "four deep audits on the deep tier");
        assertEq(accessVault.forensicQuotaOf(TIER_DEEP), 0, "and no forensic ones");
        assertEq(accessVault.deepQuotaOf(TIER_FORENSIC), 4, "four deep audits on the forensic tier");
        assertEq(accessVault.forensicQuotaOf(TIER_FORENSIC), 1, "and one forensic one");

        assertEq(address(accessVault.kay9()), address(token), "the vault locks KAY9");
        assertEq(accessVault.requirementOf(TIER_DEEP), DEEP_REQUIREMENT, "a deep period locks 5,000 KAY9");
        assertEq(accessVault.requirementOf(TIER_FORENSIC), FORENSIC_REQUIREMENT, "a forensic period locks 10,000 KAY9");
        assertEq(accessVault.MIN_REQUIREMENT(), 1e18, "the floor is one KAY9");
        assertEq(accessVault.MAX_REQUIREMENT(), 10_000_000e18, "the ceiling is one percent of the supply");
        assertEq(accessVault.auditHub(), address(hub), "and only the hub may move quota");
        assertEq(address(hub.accessVault()), address(accessVault), "and the hub asks that vault");
        assertEq(accessVault.owner(), address(timelock), "governance is the timelock");
    }

    // -------------------------------------------------------------------------------------------
    // What the lock takes
    // -------------------------------------------------------------------------------------------

    /// @notice The vault takes exactly the tier's requirement, to the wei, and freezes it.
    function test_lockTakesExactlyTheQuotedRequirement() public {
        uint256 quoted = accessVault.requirementOf(TIER_DEEP);
        assertEq(quoted, DEEP_REQUIREMENT, "the requirement is the configured number");

        // A deliberate surplus, so the assertion below proves the vault took the quote and not
        // simply whatever the depositor held.
        _fundKay9(alice, quoted + 1234e18);
        uint256 balanceBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        token.approve(address(accessVault), type(uint256).max);
        accessVault.lock(TIER_DEEP, type(uint256).max);
        vm.stopPrank();

        assertEq(balanceBefore - token.balanceOf(alice), quoted, "the depositor paid exactly the quote");
        assertEq(token.balanceOf(address(accessVault)), quoted, "the vault holds exactly the quote");
        assertEq(accessVault.totalLocked(), quoted, "and counts exactly what it holds");

        Access memory access = accessVault.accessOf(alice);
        assertEq(access.tier, TIER_DEEP, "the deep tier");
        assertEq(access.startedAt, uint64(vm.getBlockTimestamp()), "the period starts now");
        assertEq(access.expiresAt, uint64(vm.getBlockTimestamp()) + accessVault.lockDuration(), "for lockDuration");
        assertEq(access.lockedKay9, quoted, "the principal is the requirement");
        assertEq(access.deepQuota, 4, "four deep audits per deep period");
        assertEq(access.forensicQuota, 0, "and no forensic ones");
        assertEq(access.deepUsed, 0, "nothing used yet");
        assertEq(access.forensicUsed, 0, "nothing used yet");
    }

    /// @notice The forensic lock takes the forensic requirement, which is the larger of the two.
    function test_forensicLockTakesTheForensicRequirement() public {
        uint256 deepRequired = accessVault.requirementOf(TIER_DEEP);
        uint256 locked = _grantAccess(alice, TIER_FORENSIC);

        assertEq(locked, accessVault.requirementOf(TIER_FORENSIC), "the forensic requirement");
        assertGt(locked, deepRequired, "forensic access locks more than deep access");
        assertEq(token.balanceOf(address(accessVault)), locked, "the vault holds exactly it");

        Access memory access = accessVault.accessOf(alice);
        assertEq(access.tier, TIER_FORENSIC, "the forensic tier");
        assertEq(access.deepQuota, 4, "four deep audits");
        assertEq(access.forensicQuota, 1, "and one forensic one");
    }

    /// @notice A requirement above the depositor's stated maximum is refused rather than taken.
    function test_lockRefusesARequirementAboveTheMaximum() public {
        uint256 quoted = accessVault.requirementOf(TIER_DEEP);
        _fundKay9(alice, quoted);

        vm.startPrank(alice);
        token.approve(address(accessVault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.RequirementAboveMax.selector, quoted, quoted - 1));
        accessVault.lock(TIER_DEEP, quoted - 1);
        vm.stopPrank();

        assertEq(token.balanceOf(address(accessVault)), 0, "nothing was taken");
        assertEq(accessVault.totalLocked(), 0, "and nothing was counted");
    }

    /// @notice Only the two paid tiers can be locked.
    function test_lockRejectsAnInvalidTier() public {
        _fundKay9(alice, 1_000_000e18);
        vm.startPrank(alice);
        token.approve(address(accessVault), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.InvalidTier.selector, uint8(0)));
        accessVault.lock(0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.InvalidTier.selector, uint8(3)));
        accessVault.lock(3, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice A second period cannot be opened while one is live.
    function test_lockRefusesASecondLivePeriod() public {
        _grantAccess(alice, TIER_DEEP);
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.AccessLive.selector, expiresAt));
        accessVault.lock(TIER_DEEP, type(uint256).max);
    }

    /// @notice A period that has ended is not overwritten by a fresh lock: the depositor is told to
    ///         renew or unlock instead, so the principal it still has in the vault cannot be
    ///         silently replaced by a second one.
    function test_lockAfterAnEndedPeriodDemandsRenewOrUnlock() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;

        vm.warp(expiresAt);
        _fundKay9(alice, locked);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.AccessRecordExists.selector, expiresAt));
        accessVault.lock(TIER_DEEP, type(uint256).max);

        assertEq(accessVault.totalLocked(), locked, "still exactly one principal");
        assertEq(token.balanceOf(address(accessVault)), locked, "and the vault took nothing new");

        // Unlocking clears the record, after which locking again is the right call.
        vm.prank(alice);
        accessVault.unlock();
        vm.prank(alice);
        accessVault.lock(TIER_DEEP, type(uint256).max);
        assertTrue(accessVault.isActive(alice), "a cleared record can be locked again");
    }

    /// @notice A permit-wrapped lock works, and tolerates a permit that has already been used.
    function test_lockWithPermit() public {
        uint256 depositorKey = 0xDEC0DE;
        address depositor = vm.addr(depositorKey);
        uint256 quoted = accessVault.requirementOf(TIER_DEEP);
        _fundKay9(depositor, quoted);

        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                depositor,
                address(accessVault),
                quoted,
                token.nonces(depositor),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(depositorKey, MessageHashUtils.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash));

        vm.prank(depositor);
        accessVault.lockWithPermit(TIER_DEEP, quoted, deadline, v, r, s);

        assertEq(token.balanceOf(address(accessVault)), quoted, "the permit funded the lock");
        assertEq(token.balanceOf(depositor), 0, "and took exactly the requirement");
        assertTrue(accessVault.isActive(depositor), "the period is live");
    }

    // -------------------------------------------------------------------------------------------
    // Period boundaries
    // -------------------------------------------------------------------------------------------

    /// @notice A period is live at the last second before expiry and dead at expiry itself.
    function test_periodBoundariesAreExact() public {
        _grantAccess(alice, TIER_FORENSIC);
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;

        vm.warp(expiresAt - 1);
        assertTrue(accessVault.isActive(alice), "still live one second before expiry");
        assertTrue(accessVault.canRequest(alice, TIER_DEEP), "and deep is still requestable");
        assertTrue(accessVault.canRequest(alice, TIER_FORENSIC), "and so is forensic");
        assertEq(accessVault.deepRemaining(alice), 4, "the whole deep allowance is still there");
        assertEq(accessVault.forensicRemaining(alice), 1, "and the forensic one");

        vm.warp(expiresAt);
        assertFalse(accessVault.isActive(alice), "not live at expiry");
        assertFalse(accessVault.canRequest(alice, TIER_DEEP), "nothing is requestable");
        assertFalse(accessVault.canRequest(alice, TIER_FORENSIC), "nothing is requestable");
        assertEq(accessVault.deepRemaining(alice), 0, "an expired period grants nothing");
        assertEq(accessVault.forensicRemaining(alice), 0, "an expired period grants nothing");
    }

    /// @notice An expired period is refused by the hub, at the exact second it expires.
    function test_requestAtExpiryIsRefused() public {
        _grantAccess(alice, TIER_DEEP);
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;

        vm.warp(expiresAt - 1);
        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 1);

        vm.warp(expiresAt);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 1);
    }

    // -------------------------------------------------------------------------------------------
    // Unlock
    // -------------------------------------------------------------------------------------------

    /// @notice unlock is refused until expiry and then returns the whole principal.
    function test_unlockRevertsBeforeExpiryAndReturnsEverythingAfter() public {
        _fundKay9(alice, 400_000e18);
        uint256 balanceBefore = token.balanceOf(alice);

        vm.startPrank(alice);
        token.approve(address(accessVault), type(uint256).max);
        accessVault.lock(TIER_DEEP, type(uint256).max);
        vm.stopPrank();

        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;
        uint256 locked = accessVault.accessOf(alice).lockedKay9;
        assertEq(token.balanceOf(alice), balanceBefore - locked, "the principal left the depositor");

        vm.warp(expiresAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        accessVault.unlock();

        vm.warp(expiresAt);
        vm.prank(alice);
        accessVault.unlock();

        assertEq(token.balanceOf(alice), balanceBefore, "the depositor's balance is restored exactly");
        assertEq(token.balanceOf(address(accessVault)), 0, "the vault kept nothing");
        assertEq(accessVault.totalLocked(), 0, "and counts nothing");
        assertEq(accessVault.accessOf(alice).lockedKay9, 0, "the record is cleared");
        assertEq(accessVault.accessOf(alice).startedAt, 0, "including the period identity");
    }

    /// @notice Spending the whole quota does not cost the depositor a single wei of principal.
    function test_usingEveryAuditStillReturnsTheWholePrincipal() public {
        uint256 locked = _grantAccess(alice, TIER_FORENSIC);
        assertEq(token.balanceOf(alice), 0, "the depositor locked everything it held");

        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(alice);
            hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, 1);
        }
        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_FORENSIC, 1);
        assertEq(accessVault.deepRemaining(alice), 0, "the deep allowance is spent");
        assertEq(accessVault.forensicRemaining(alice), 0, "the forensic allowance is spent");

        vm.warp(accessVault.accessOf(alice).expiresAt);
        vm.prank(alice);
        accessVault.unlock();
        assertEq(token.balanceOf(alice), locked, "five audits later, the principal comes back in full");
    }

    /// @notice unlock and renew both need a period to exist.
    function test_unlockAndRenewWithoutAPeriodRevert() public {
        vm.startPrank(alice);
        vm.expectRevert(KAY9AccessVault.NoAccess.selector);
        accessVault.unlock();
        vm.expectRevert(KAY9AccessVault.NoAccess.selector);
        accessVault.renew(TIER_DEEP, type(uint256).max);
        vm.expectRevert(KAY9AccessVault.NoAccess.selector);
        accessVault.upgrade(type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // No yield, ever
    // -------------------------------------------------------------------------------------------

    /// @notice The vault's balance is its accounting, at every step, and nobody ever takes out more
    ///         than they put in.
    function test_vaultBalanceAlwaysEqualsTotalLockedAndNobodyGainsTokens() public {
        _assertVaultHoldsExactlyWhatItOwes();

        uint256 aliceLocked = _grantAccess(alice, TIER_DEEP);
        _assertVaultHoldsExactlyWhatItOwes();
        uint256 bobLocked = _grantAccess(bob, TIER_FORENSIC);
        _assertVaultHoldsExactlyWhatItOwes();
        assertEq(accessVault.totalLocked(), aliceLocked + bobLocked, "both principals are counted");

        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 1);
        _assertVaultHoldsExactlyWhatItOwes();
        assertEq(accessVault.totalLocked(), aliceLocked + bobLocked, "a request moves no principal");

        vm.warp(accessVault.accessOf(alice).expiresAt);
        vm.prank(alice);
        accessVault.unlock();
        _assertVaultHoldsExactlyWhatItOwes();
        assertEq(token.balanceOf(alice), aliceLocked, "alice got back exactly what she put in, no more");

        vm.prank(bob);
        accessVault.unlock();
        _assertVaultHoldsExactlyWhatItOwes();
        assertEq(token.balanceOf(bob), bobLocked, "bob got back exactly what he put in, no more");
        assertEq(accessVault.totalLocked(), 0, "the vault is empty");
        assertEq(token.balanceOf(address(accessVault)), 0, "and holds nothing");
    }

    /// @notice A donation to the vault is not credited to anybody and does not distort accounting.
    /// @dev The invariant is `balance >= totalLocked`: a stranger can always push tokens into any
    ///      ERC20 holder, and what matters is that the surplus is never paid out as a yield.
    function test_aDonationIsNeverPaidOutAsYield() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);

        _fundKay9(address(accessVault), 777e18);
        assertEq(accessVault.totalLocked(), locked, "a donation is not credited to anyone");
        assertEq(accessVault.accessOf(alice).lockedKay9, locked, "least of all to a depositor");

        vm.warp(accessVault.accessOf(alice).expiresAt);
        vm.prank(alice);
        accessVault.unlock();

        assertEq(token.balanceOf(alice), locked, "the depositor is paid its principal and nothing more");
        assertEq(token.balanceOf(address(accessVault)), 777e18, "the donation is stranded, not distributed");
        assertEq(accessVault.totalLocked(), 0, "and is not counted as locked");
    }

    // -------------------------------------------------------------------------------------------
    // Renewal
    // -------------------------------------------------------------------------------------------

    /// @notice Renewal inside a live period is refused, because it would reset the quota.
    function test_renewRevertsBeforeExpiry() public {
        _grantAccess(alice, TIER_DEEP);
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;

        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 1);
        assertEq(accessVault.deepRemaining(alice), 3, "one deep audit is spent");

        vm.warp(expiresAt - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        accessVault.renew(TIER_DEEP, type(uint256).max);
        assertEq(accessVault.deepRemaining(alice), 3, "the spent audit is still spent");
    }

    /// @notice Renewal after expiry re-reads the requirement and takes exactly the shortfall when
    ///         governance raised it in the meantime.
    function test_renewTopsUpWhenTheRequirementRose() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        uint64 firstStart = accessVault.accessOf(alice).startedAt;

        _warpPastExpiry(alice);
        _setRequirement(TIER_DEEP, DEEP_REQUIREMENT * 2);

        uint256 required = accessVault.requirementOf(TIER_DEEP);
        assertGt(required, locked, "the requirement really did rise");
        _fundKay9(alice, required - locked);
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        accessVault.renew(TIER_DEEP, type(uint256).max);

        assertEq(balanceBefore - token.balanceOf(alice), required - locked, "only the shortfall was taken");
        assertEq(token.balanceOf(address(accessVault)), required, "the vault holds the new requirement");
        assertEq(accessVault.totalLocked(), required, "and counts it");

        Access memory access = accessVault.accessOf(alice);
        assertEq(access.lockedKay9, required, "the principal is the new requirement");
        assertGt(access.startedAt, firstStart, "a new period identity");
        assertEq(access.expiresAt, access.startedAt + accessVault.lockDuration(), "extended by a full duration");
    }

    /// @notice Renewal returns the difference when the requirement fell, and never keeps the surplus.
    function test_renewReturnsTheDifferenceWhenTheRequirementFell() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);

        _warpPastExpiry(alice);
        _setRequirement(TIER_DEEP, DEEP_REQUIREMENT / 2);

        uint256 required = accessVault.requirementOf(TIER_DEEP);
        assertLt(required, locked, "the requirement really did fall");
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        accessVault.renew(TIER_DEEP, type(uint256).max);

        assertEq(token.balanceOf(alice) - balanceBefore, locked - required, "the surplus went back to the depositor");
        assertEq(token.balanceOf(address(accessVault)), required, "the vault holds only the new requirement");
        assertEq(accessVault.totalLocked(), required, "and counts only that");
        assertEq(accessVault.accessOf(alice).lockedKay9, required, "the principal shrank to the requirement");
    }

    /// @notice Renewal resets the quota and extends the period, and may change the tier.
    function test_renewResetsQuotaAndExtendsThePeriod() public {
        _grantAccess(alice, TIER_DEEP);
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(alice);
            hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, 1);
        }
        assertEq(accessVault.deepRemaining(alice), 1, "three of four deep audits are spent");
        uint64 oldExpiry = accessVault.accessOf(alice).expiresAt;

        _warpPastExpiry(alice);
        uint256 required = accessVault.requirementOf(TIER_FORENSIC);
        _fundKay9(alice, required);

        vm.prank(alice);
        accessVault.renew(TIER_FORENSIC, type(uint256).max);

        Access memory access = accessVault.accessOf(alice);
        assertEq(access.tier, TIER_FORENSIC, "the new period is forensic");
        assertEq(access.deepUsed, 0, "the quota reset");
        assertEq(access.forensicUsed, 0, "the quota reset");
        assertEq(accessVault.deepRemaining(alice), 4, "a full deep allowance again");
        assertEq(accessVault.forensicRemaining(alice), 1, "and a forensic one");
        assertGt(access.expiresAt, oldExpiry, "the period was extended");
        assertEq(access.expiresAt, uint64(vm.getBlockTimestamp()) + accessVault.lockDuration(), "by a full duration");
    }

    // -------------------------------------------------------------------------------------------
    // The requirement is frozen for the period
    // -------------------------------------------------------------------------------------------

    /// @notice Governance raising the requirement mid-period changes nothing about a live period:
    ///         not the principal, not the quota, not the expiry, and no top-up is demanded.
    function test_theRequirementIsFrozenForThePeriod() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        Access memory before = accessVault.accessOf(alice);

        // The requirement for a new lock doubles. Forensic is raised first so it stays above deep.
        _setRequirement(TIER_FORENSIC, FORENSIC_REQUIREMENT * 2);
        _setRequirement(TIER_DEEP, DEEP_REQUIREMENT * 2);
        uint256 nowRequired = accessVault.requirementOf(TIER_DEEP);
        assertGt(nowRequired, locked, "a fresh lock would now need more");

        Access memory after_ = accessVault.accessOf(alice);
        assertEq(after_.lockedKay9, before.lockedKay9, "the principal did not move");
        assertEq(after_.expiresAt, before.expiresAt, "the period did not shorten");
        assertEq(after_.deepQuota, before.deepQuota, "the allowance did not shrink");
        assertEq(token.balanceOf(address(accessVault)), locked, "the vault demanded nothing extra");
        assertEq(token.balanceOf(alice), 0, "and took nothing extra");
        assertTrue(accessVault.isActive(alice), "the period is still live");

        // The audits the period paid for still work, with no top-up.
        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 1);
        assertEq(accessVault.deepRemaining(alice), 3, "the audit was granted at the frozen requirement");
        assertEq(token.balanceOf(address(accessVault)), locked, "still exactly the original principal");
    }

    /// @notice A change in the depositor's favour does not shrink a live lock either.
    function test_aFallingRequirementDoesNotRefundMidPeriod() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);

        _setRequirement(TIER_DEEP, DEEP_REQUIREMENT / 2);
        uint256 nowRequired = accessVault.requirementOf(TIER_DEEP);
        assertLt(nowRequired, locked, "a fresh lock would now need less");

        assertEq(accessVault.accessOf(alice).lockedKay9, locked, "the live principal is unchanged");
        assertEq(token.balanceOf(alice), 0, "nothing was returned early");

        // The expiry is read before the prank, because an intervening view call would consume it.
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        accessVault.unlock();
    }

    // -------------------------------------------------------------------------------------------
    // The requirement is a number governance sets, within bounds
    // -------------------------------------------------------------------------------------------

    /// @notice Governance may set either tier's requirement, only within the bounds, and forensic
    ///         may never require less than deep.
    function test_setRequirementIsBoundedAndForensicNeverBelowDeep() public {
        // Below the floor and above the ceiling are refused.
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AccessVault.InvalidRequirement.selector);
        accessVault.setRequirement(TIER_DEEP, 1e18 - 1);
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AccessVault.InvalidRequirement.selector);
        accessVault.setRequirement(TIER_FORENSIC, 10_000_000e18 + 1);

        // Deep above forensic, or forensic below deep, is refused either way round.
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AccessVault.InvalidRequirement.selector);
        accessVault.setRequirement(TIER_DEEP, FORENSIC_REQUIREMENT + 1);
        vm.prank(address(timelock));
        vm.expectRevert(KAY9AccessVault.InvalidRequirement.selector);
        accessVault.setRequirement(TIER_FORENSIC, DEEP_REQUIREMENT - 1);

        // An unknown tier is refused.
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.InvalidTier.selector, uint8(3)));
        accessVault.setRequirement(3, DEEP_REQUIREMENT);

        // Equal is allowed, and the bounds themselves are allowed.
        vm.prank(address(timelock));
        vm.expectEmit(true, false, false, true, address(accessVault));
        emit KAY9AccessVault.RequirementConfigured(TIER_DEEP, FORENSIC_REQUIREMENT);
        accessVault.setRequirement(TIER_DEEP, FORENSIC_REQUIREMENT);
        vm.prank(address(timelock));
        accessVault.setRequirement(TIER_FORENSIC, 10_000_000e18);
        vm.prank(address(timelock));
        accessVault.setRequirement(TIER_DEEP, 1e18);
        assertEq(accessVault.requirementOf(TIER_DEEP), 1e18, "the floor is a valid requirement");
        assertEq(accessVault.requirementOf(TIER_FORENSIC), 10_000_000e18, "and so is the ceiling");
    }

    /// @notice Only the owner, which is the timelock, may change a requirement.
    function test_setRequirementIsOwnerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        accessVault.setRequirement(TIER_DEEP, DEEP_REQUIREMENT * 2);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        accessVault.setRequirement(TIER_DEEP, DEEP_REQUIREMENT * 2);
        assertEq(accessVault.requirementOf(TIER_DEEP), DEEP_REQUIREMENT, "unchanged");
    }

    /// @notice A requirement change is the whole story of what governance can do to a period's
    ///         size, and it can do nothing to a live one: the live period keeps its principal,
    ///         its quota and its expiry, and `unlock` returns exactly what was locked, whatever
    ///         the number is by then.
    function test_aRequirementChangeNeverTouchesALivePeriodAndUnlockReturnsExactly() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        uint256 bobRequired = accessVault.requirementOf(TIER_DEEP);
        _fundKay9(bob, bobRequired);
        vm.prank(bob);
        token.approve(address(accessVault), type(uint256).max);

        // Governance moves both numbers, up then far up.
        _setRequirement(TIER_FORENSIC, FORENSIC_REQUIREMENT * 100);
        _setRequirement(TIER_DEEP, DEEP_REQUIREMENT * 100);

        // Bob's lock now needs the new number; his old maximum is refused, his balance untouched.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(KAY9AccessVault.RequirementAboveMax.selector, DEEP_REQUIREMENT * 100, bobRequired)
        );
        accessVault.lock(TIER_DEEP, bobRequired);
        assertEq(token.balanceOf(bob), bobRequired, "nothing was taken from bob");

        // Alice's live period is exactly as it was, and her audits still work.
        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_DEEP, 1);
        assertEq(accessVault.deepRemaining(alice), 3, "audits already locked for still work");
        assertEq(accessVault.accessOf(alice).lockedKay9, locked, "the principal did not move");

        // And the period ends with the whole principal coming home, at the old number.
        vm.warp(accessVault.accessOf(alice).expiresAt);
        vm.prank(alice);
        accessVault.unlock();
        assertEq(token.balanceOf(alice), locked, "the whole principal came back");
        assertEq(token.balanceOf(address(accessVault)), 0, "the vault kept nothing");
        assertEq(accessVault.totalLocked(), 0, "and counts nothing");
    }

    // -------------------------------------------------------------------------------------------
    // Upgrade
    // -------------------------------------------------------------------------------------------

    /// @notice Upgrading preserves deepUsed, tops up to the forensic requirement, and does not move
    ///         the expiry.
    function test_upgradePreservesDeepUsedAndKeepsTheExpiry() public {
        uint256 deepLocked = _grantAccess(alice, TIER_DEEP);
        Access memory before = accessVault.accessOf(alice);

        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(alice);
            hub.requestAudit(chainKey, bytes32(i + 1), TIER_DEEP, 1);
        }
        assertEq(accessVault.accessOf(alice).deepUsed, 2, "two deep audits are spent");

        uint256 forensicRequired = accessVault.requirementOf(TIER_FORENSIC);
        _fundKay9(alice, forensicRequired - deepLocked);
        uint256 balanceBefore = token.balanceOf(alice);

        vm.prank(alice);
        accessVault.upgrade(type(uint256).max);

        assertEq(balanceBefore - token.balanceOf(alice), forensicRequired - deepLocked, "only the top-up was taken");
        assertEq(token.balanceOf(address(accessVault)), forensicRequired, "the vault holds the forensic requirement");
        assertEq(accessVault.totalLocked(), forensicRequired, "and counts it");

        Access memory access = accessVault.accessOf(alice);
        assertEq(access.tier, TIER_FORENSIC, "the tier rose");
        assertEq(access.deepUsed, 2, "deepUsed survived the upgrade");
        assertEq(access.deepQuota, 4, "the deep allowance is unchanged");
        assertEq(access.forensicQuota, 1, "and a forensic slot was bought");
        assertEq(access.expiresAt, before.expiresAt, "the expiry did not move");
        assertEq(access.startedAt, before.startedAt, "and neither did the period identity");
        assertEq(access.lockedKay9, forensicRequired, "the principal is the forensic requirement");

        // What the upgrade bought is exactly one forensic audit and the two deep ones left over.
        assertEq(accessVault.deepRemaining(alice), 2, "two deep audits remain, not four");
        vm.prank(alice);
        hub.requestAudit(chainKey, assetId, TIER_FORENSIC, 1);
        assertEq(accessVault.forensicRemaining(alice), 0, "the forensic slot is spent");
    }

    /// @notice A live upgrade never hands principal back, however far the requirement has fallen.
    /// @dev The sequence that used to refund mid-period: lock at 5,000, governance lowers deep to
    ///      1,000 and forensic to 2,000 (a valid order, forensic stays above deep), then upgrade.
    ///      3,000 KAY9 came back before the period had ended.
    function test_liveUpgradeDoesNotRefundHistoricalPrincipal() public {
        uint256 held = _grantAccess(alice, TIER_DEEP);
        Access memory before = accessVault.accessOf(alice);

        _setRequirement(TIER_DEEP, 1_000e18);
        _setRequirement(TIER_FORENSIC, 2_000e18);
        assertGt(held, accessVault.requirementOf(TIER_FORENSIC), "the period holds more than forensic now asks");

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        accessVault.upgrade(held);

        Access memory access = accessVault.accessOf(alice);
        assertEq(token.balanceOf(alice), balanceBefore, "nothing came back mid-period, and nothing was taken");
        assertEq(access.lockedKay9, held, "the period keeps what it locked with");
        assertEq(accessVault.totalLocked(), held, "and the vault still counts all of it");
        assertEq(token.balanceOf(address(accessVault)), held, "and still holds all of it");
        assertEq(access.tier, TIER_FORENSIC, "the tier still rose");
        assertEq(access.forensicQuota, 1, "and the forensic slot was still granted");
        assertEq(access.expiresAt, before.expiresAt, "the expiry did not move");
        assertEq(access.startedAt, before.startedAt, "and neither did the period identity");

        // The whole recorded principal comes home at the end, exactly as `unlock` promises.
        _warpPastExpiry(alice);
        vm.prank(alice);
        accessVault.unlock();
        assertEq(token.balanceOf(alice), balanceBefore + held, "the entire principal returned at expiry");
        assertEq(accessVault.totalLocked(), 0, "and the vault owes nothing");
    }

    /// @notice The lower requirement is reached at renewal, which is where a requirement change
    ///         is meant to take effect.
    function test_aLoweredRequirementAppliesAtRenewalNotAtUpgrade() public {
        uint256 held = _grantAccess(alice, TIER_DEEP);
        _setRequirement(TIER_DEEP, 1_000e18);
        _setRequirement(TIER_FORENSIC, 2_000e18);

        vm.prank(alice);
        accessVault.upgrade(held);
        _warpPastExpiry(alice);

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        accessVault.renew(TIER_FORENSIC, held);

        assertEq(accessVault.accessOf(alice).lockedKay9, 2_000e18, "the new period is at the new requirement");
        assertEq(token.balanceOf(alice) - balanceBefore, held - 2_000e18, "and the difference came back then");
    }

    /// @notice The caller's maximum is compared with what the upgrade leaves locked.
    function test_upgradeMaximumIsCheckedAgainstWhatStaysLocked() public {
        uint256 held = _grantAccess(alice, TIER_DEEP);
        _setRequirement(TIER_DEEP, 1_000e18);
        _setRequirement(TIER_FORENSIC, 2_000e18);

        // 2,000 is the current requirement, but the call leaves 5,000 locked, and that is the
        // number a caller naming a maximum is asking about.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.RequirementAboveMax.selector, held, 2_000e18));
        accessVault.upgrade(2_000e18);
    }

    /// @notice A quota cut after the period opened cannot take deep audits away through an upgrade.
    function test_upgradeKeepsTheDeepAllowanceThePeriodWasOpenedWith() public {
        uint256 deepLocked = _grantAccess(alice, TIER_DEEP);
        vm.prank(alice);
        hub.requestAudit(chainKey, bytes32(uint256(1)), TIER_DEEP, 1);

        // Forensic periods opened from now on get two deep audits, not four.
        vm.prank(address(timelock));
        accessVault.setQuota(TIER_FORENSIC, 2, 1);

        _fundKay9(alice, accessVault.requirementOf(TIER_FORENSIC) - deepLocked);
        vm.prank(alice);
        accessVault.upgrade(type(uint256).max);

        Access memory access = accessVault.accessOf(alice);
        assertEq(access.deepQuota, 4, "the allowance this period was opened with survives");
        assertEq(access.deepUsed, 1, "and so does what was spent of it");
        assertEq(accessVault.deepRemaining(alice), 3, "three deep audits remain, not one");
    }

    /// @notice A quota raised after the period opened is what an upgrade into that tier receives.
    function test_upgradeTakesALargerForensicDeepAllowance() public {
        uint256 deepLocked = _grantAccess(alice, TIER_DEEP);
        vm.prank(address(timelock));
        accessVault.setQuota(TIER_FORENSIC, 6, 1);

        _fundKay9(alice, accessVault.requirementOf(TIER_FORENSIC) - deepLocked);
        vm.prank(alice);
        accessVault.upgrade(type(uint256).max);

        assertEq(accessVault.accessOf(alice).deepQuota, 6, "a forensic period has six today, and this is one");
    }

    /// @notice Upgrade is refused for anything that is not a live deep period.
    function test_upgradeOnlyAppliesToALiveDeepPeriod() public {
        _grantAccess(alice, TIER_FORENSIC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotAnUpgrade.selector, TIER_FORENSIC));
        accessVault.upgrade(type(uint256).max);

        _grantAccess(bob, TIER_DEEP);
        uint64 expiresAt = accessVault.accessOf(bob).expiresAt;
        vm.warp(expiresAt);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotExpired.selector, expiresAt));
        accessVault.upgrade(type(uint256).max);
    }

    /// @notice Upgrade respects the caller's stated maximum.
    function test_upgradeRespectsTheMaximum() public {
        _grantAccess(alice, TIER_DEEP);
        uint256 forensicRequired = accessVault.requirementOf(TIER_FORENSIC);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(KAY9AccessVault.RequirementAboveMax.selector, forensicRequired, forensicRequired - 1)
        );
        accessVault.upgrade(forensicRequired - 1);
    }

    // -------------------------------------------------------------------------------------------
    // The principal only ever goes home
    // -------------------------------------------------------------------------------------------

    /// @notice There is no function, owner-only or otherwise, that sends a depositor's principal
    ///         anywhere but back to the depositor.
    /// @dev Proved two ways: the vault exposes no such entry point at all, so the obvious selectors
    ///      do not exist, and the owner exercising everything it does have moves nothing.
    function test_noPathSendsAPrincipalAnywhereButHome() public {
        uint256 locked = _grantAccess(alice, TIER_DEEP);
        address attacker = makeAddr("attacker");

        string[9] memory absentFunctions = [
            "withdraw()",
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "sweep(address)",
            "sweep(address,address)",
            "rescue(address,uint256)",
            "recoverERC20(address,uint256)",
            "emergencyWithdraw()",
            "skim(address)"
        ];
        for (uint256 i = 0; i < absentFunctions.length; ++i) {
            bytes memory data = _callDataFor(absentFunctions[i], attacker, locked);
            vm.prank(address(timelock));
            (bool ok,) = address(accessVault).call(data);
            assertFalse(ok, "the vault has no such function");
        }

        // The vault never approves anyone, so nobody can pull the principal out either.
        assertEq(token.allowance(address(accessVault), address(timelock)), 0, "no allowance for the owner");
        assertEq(token.allowance(address(accessVault), address(hub)), 0, "no allowance for the hub");
        assertEq(token.allowance(address(accessVault), attacker), 0, "no allowance for anyone");

        // Everything the owner really can do, done at once. None of it is a transfer.
        vm.startPrank(address(timelock));
        accessVault.setQuota(TIER_DEEP, 1, 0);
        accessVault.setLockDuration(7 days);
        accessVault.setAuditHub(address(timelock));
        vm.stopPrank();

        // Even holding the hub role, the owner can only move quota, never tokens. The period is
        // read before the prank, because an intervening view call would consume it.
        uint64 startedAt = accessVault.accessOf(alice).startedAt;
        vm.prank(address(timelock));
        accessVault.consume(alice, TIER_DEEP);
        vm.prank(address(timelock));
        accessVault.restore(alice, TIER_DEEP, startedAt);

        assertEq(token.balanceOf(address(accessVault)), locked, "the principal never moved");
        assertEq(accessVault.totalLocked(), locked, "and is still counted as alice's");
        assertEq(accessVault.accessOf(alice).lockedKay9, locked, "and is still hers");
        assertEq(token.balanceOf(attacker), 0, "the attacker got nothing");

        // The depositor still gets all of it back afterwards.
        vm.warp(accessVault.accessOf(alice).expiresAt);
        vm.prank(alice);
        accessVault.unlock();
        assertEq(token.balanceOf(alice), locked, "the depositor is made whole");
    }

    /// @notice Quota is the hub's to move and nobody else's.
    function test_onlyTheHubCanMoveQuota() public {
        _grantAccess(alice, TIER_DEEP);
        uint64 startedAt = accessVault.accessOf(alice).startedAt;

        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, address(this)));
        accessVault.consume(alice, TIER_DEEP);

        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, address(timelock)));
        accessVault.consume(alice, TIER_DEEP);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, alice));
        accessVault.restore(alice, TIER_DEEP, startedAt);

        assertEq(accessVault.deepRemaining(alice), 4, "no outsider changed the allowance");
    }

    /// @notice A hub that governance replaces may still give quota back, and nothing else.
    function test_aRetiredHubMayRestoreButNeverConsume() public {
        _grantAccess(alice, TIER_DEEP);
        vm.prank(address(hub));
        uint64 period = accessVault.consume(alice, TIER_DEEP);
        assertEq(accessVault.deepRemaining(alice), 3, "one unit spent through the live hub");

        address hubV2 = makeAddr("hubV2");
        vm.prank(address(timelock));
        vm.expectEmit(true, true, true, true, address(accessVault));
        emit KAY9AccessVault.AuditHubRetired(address(hub));
        accessVault.setAuditHub(hubV2);
        assertEq(accessVault.auditHub(), hubV2, "the new hub is current");
        assertTrue(accessVault.isRetiredHub(address(hub)), "the old one is retired");

        vm.prank(address(hub));
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, address(hub)));
        accessVault.consume(alice, TIER_DEEP);

        vm.prank(address(hub));
        accessVault.restore(alice, TIER_DEEP, period);
        assertEq(accessVault.deepRemaining(alice), 4, "the retired hub returned the unit it took");

        // A stranger is still nobody.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.NotTheAuditHub.selector, alice));
        accessVault.restore(alice, TIER_DEEP, period);

        // Pointing back at a retired hub reinstates it and retires the one it replaces.
        vm.prank(address(timelock));
        accessVault.setAuditHub(address(hub));
        assertFalse(accessVault.isRetiredHub(address(hub)), "reinstated");
        assertTrue(accessVault.isRetiredHub(hubV2), "and the interim hub is retired");
        assertEq(token.balanceOf(address(accessVault)), accessVault.totalLocked(), "no balance moved");
    }

    // -------------------------------------------------------------------------------------------
    // Governance
    // -------------------------------------------------------------------------------------------

    /// @notice Only the timelock configures the vault, and every bound is enforced.
    function test_governanceIsTimelockedAndBounded() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        accessVault.setQuota(TIER_DEEP, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        accessVault.setLockDuration(14 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        accessVault.setAuditHub(address(this));

        // Every bound is read before the cheatcode is armed, because an intervening view call
        // would consume the expectation.
        uint32 aboveMaxQuota = accessVault.MAX_QUOTA() + 1;
        uint64 belowMinDuration = accessVault.MIN_LOCK_DURATION() - 1;
        uint64 aboveMaxDuration = accessVault.MAX_LOCK_DURATION() + 1;

        vm.startPrank(address(timelock));
        vm.expectRevert(KAY9AccessVault.ZeroAddress.selector);
        accessVault.setAuditHub(address(0));
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.InvalidTier.selector, uint8(0)));
        accessVault.setQuota(0, 1, 0);
        vm.expectRevert(KAY9AccessVault.InvalidQuota.selector);
        accessVault.setQuota(TIER_DEEP, 1, 1);
        vm.expectRevert(KAY9AccessVault.InvalidQuota.selector);
        accessVault.setQuota(TIER_FORENSIC, aboveMaxQuota, 1);
        vm.expectRevert(KAY9AccessVault.InvalidLockDuration.selector);
        accessVault.setLockDuration(belowMinDuration);
        vm.expectRevert(KAY9AccessVault.InvalidLockDuration.selector);
        accessVault.setLockDuration(aboveMaxDuration);

        accessVault.setLockDuration(90 days);
        accessVault.setQuota(TIER_FORENSIC, 8, 2);
        vm.stopPrank();

        assertEq(accessVault.lockDuration(), 90 days, "the duration was set");
        assertEq(accessVault.deepQuotaOf(TIER_FORENSIC), 8, "the deep allowance was set");
        assertEq(accessVault.forensicQuotaOf(TIER_FORENSIC), 2, "the forensic allowance was set");
    }

    /// @notice A longer or shorter duration applies to the next period, never to a live one.
    function test_changingTheDurationDoesNotMoveALivePeriod() public {
        _grantAccess(alice, TIER_DEEP);
        uint64 expiresAt = accessVault.accessOf(alice).expiresAt;

        vm.prank(address(timelock));
        accessVault.setLockDuration(365 days);
        assertEq(accessVault.accessOf(alice).expiresAt, expiresAt, "the live expiry did not move");

        vm.warp(expiresAt);
        vm.prank(alice);
        accessVault.unlock();
        assertEq(accessVault.accessOf(alice).lockedKay9, 0, "and the period still ended when it said it would");
    }

    // -------------------------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------------------------

    /// @notice Asserts the vault's KAY9 balance is exactly the sum of the principals it owes.
    /// @dev Exact rather than "at least", because nothing in this test donates to the vault: any
    ///      surplus at all would mean the vault had started accruing something.
    function _assertVaultHoldsExactlyWhatItOwes() internal view {
        assertEq(
            token.balanceOf(address(accessVault)),
            accessVault.totalLocked(),
            "the vault holds exactly the principals it owes"
        );
    }

    /// @notice Warps to an account's expiry.
    /// @param account The account whose period to warp past.
    function _warpPastExpiry(address account) internal {
        vm.warp(accessVault.accessOf(account).expiresAt);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @notice Sets a tier's requirement as governance would, through the timelock's authority.
    /// @param tier The tier.
    /// @param kay9 The new requirement.
    function _setRequirement(uint8 tier, uint256 kay9) internal {
        vm.prank(address(timelock));
        accessVault.setRequirement(tier, kay9);
    }

    /// @notice Builds calldata for a function signature, guessing the argument shape from its name.
    /// @param signature The function signature.
    /// @param who An address argument, when the signature takes one.
    /// @param amount An amount argument, when the signature takes one.
    /// @return The calldata.
    function _callDataFor(string memory signature, address who, uint256 amount) internal view returns (bytes memory) {
        bytes4 selector = bytes4(keccak256(bytes(signature)));
        bytes32 hash = keccak256(bytes(signature));
        if (hash == keccak256("withdraw()") || hash == keccak256("emergencyWithdraw()")) {
            return abi.encodePacked(selector);
        }
        if (hash == keccak256("withdraw(uint256)")) return abi.encodePacked(selector, abi.encode(amount));
        if (hash == keccak256("sweep(address)") || hash == keccak256("skim(address)")) {
            return abi.encodePacked(selector, abi.encode(who));
        }
        if (hash == keccak256("sweep(address,address)")) {
            return abi.encodePacked(selector, abi.encode(address(token), who));
        }
        return abi.encodePacked(selector, abi.encode(who, amount));
    }
}
