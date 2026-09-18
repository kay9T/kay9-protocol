// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice One account's access period. The whole struct is rewritten by `lock` and `renew` and is
///         otherwise only touched by quota accounting.
/// @dev `startedAt` identifies the period. The audit hub records it on a job so that restoring a
///      quota unit later can never credit a different period.
struct Access {
    uint8 tier;
    uint64 startedAt;
    uint64 expiresAt;
    uint32 deepQuota;
    uint32 forensicQuota;
    uint32 deepUsed;
    uint32 forensicUsed;
    uint256 lockedKay9;
}

/// @title KAY9AccessVault
/// @notice Holds KAY9 for the duration of an access period and tells the audit hub what the
///         depositor is entitled to. The deposit is a lock, not a payment: the vault never pays a
///         yield, never burns, never slashes, and has no path that sends a depositor's KAY9 to
///         anyone except the depositor.
/// @dev The amount required is a fixed number of KAY9 per tier, set by the owner through the
///      timelock and bounded here. It is copied into the record when a period opens and never read
///      again for that period: a later change asks nobody for a top-up, voids nothing, and
///      `unlock` returns exactly what was locked. There is no oracle anywhere in this contract.
/// @custom:security-contact security@kay9.io
contract KAY9AccessVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a new access period opens.
    /// @param account The depositor.
    /// @param tier The access tier.
    /// @param lockedKay9 The principal now held for the account.
    /// @param startedAt The period start, which identifies the period.
    /// @param expiresAt The moment the principal becomes withdrawable.
    /// @param deepQuota Deep audits allowed in this period.
    /// @param forensicQuota Forensic audits allowed in this period.
    event AccessLocked(
        address indexed account,
        uint8 tier,
        uint256 lockedKay9,
        uint64 startedAt,
        uint64 expiresAt,
        uint32 deepQuota,
        uint32 forensicQuota
    );

    /// @notice Emitted when an expired period is replaced by a fresh one.
    /// @param account The depositor.
    /// @param tier The new tier.
    /// @param lockedKay9 The principal after the adjustment.
    /// @param toppedUp KAY9 taken from the depositor because the requirement rose.
    /// @param returned KAY9 given back because the requirement fell.
    /// @param startedAt The new period start.
    /// @param expiresAt The new expiry.
    event AccessRenewed(
        address indexed account,
        uint8 tier,
        uint256 lockedKay9,
        uint256 toppedUp,
        uint256 returned,
        uint64 startedAt,
        uint64 expiresAt
    );

    /// @notice Emitted when a live deep period becomes a forensic one.
    /// @param account The depositor.
    /// @param lockedKay9 The principal after the top-up.
    /// @param toppedUp The KAY9 taken to reach the forensic requirement.
    /// @param forensicQuota Forensic audits now allowed in the remainder of the period.
    event AccessUpgraded(address indexed account, uint256 lockedKay9, uint256 toppedUp, uint32 forensicQuota);

    /// @notice Emitted when a depositor withdraws the whole principal.
    /// @param account The depositor.
    /// @param returnedKay9 The amount returned.
    event AccessUnlocked(address indexed account, uint256 returnedKay9);

    /// @notice Emitted when the hub debits a quota unit.
    /// @param account The depositor.
    /// @param tier The tier debited.
    /// @param deepUsed Deep audits used after the debit.
    /// @param forensicUsed Forensic audits used after the debit.
    event QuotaConsumed(address indexed account, uint8 tier, uint32 deepUsed, uint32 forensicUsed);

    /// @notice Emitted when the hub credits a quota unit back after a job produced no result.
    /// @param account The depositor.
    /// @param tier The tier credited.
    /// @param deepUsed Deep audits used after the credit.
    /// @param forensicUsed Forensic audits used after the credit.
    event QuotaRestored(address indexed account, uint8 tier, uint32 deepUsed, uint32 forensicUsed);

    /// @notice Emitted when governance changes a tier's quota.
    /// @param tier The configured tier.
    /// @param deepQuota The new deep allowance.
    /// @param forensicQuota The new forensic allowance.
    event QuotaConfigured(uint8 indexed tier, uint32 deepQuota, uint32 forensicQuota);

    /// @notice Emitted when governance sets the KAY9 a tier requires. Live periods are unaffected.
    /// @param tier The tier configured.
    /// @param kay9 The requirement, in KAY9 wei.
    event RequirementConfigured(uint8 indexed tier, uint256 kay9);

    /// @notice Emitted when governance changes the period length.
    /// @param newDuration The new period length, in seconds.
    event LockDurationUpdated(uint64 newDuration);

    /// @notice Emitted when governance points the vault at an audit hub.
    /// @param auditHub The hub allowed to move quota.
    event AuditHubUpdated(address auditHub);

    /// @notice Emitted when a hub is replaced and keeps only the right to give quota back.
    /// @param auditHub The retired hub.
    event AuditHubRetired(address auditHub);

    /// @notice Thrown when a constructor or setter argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when a tier outside {deep, forensic} is used.
    /// @param tier The rejected tier.
    error InvalidTier(uint8 tier);

    /// @notice Thrown when opening a period while one is still live.
    /// @param expiresAt When the live period ends.
    error AccessLive(uint64 expiresAt);

    /// @notice Thrown when `lock` is called by an account that already holds a record.
    /// @dev A live record means wait; an ended one means `renew` to open a fresh period at the
    ///      current requirement, or `unlock` to take the principal back. Either way `lock` is the
    ///      wrong call, and saying so is more useful than reporting the period as unexpired.
    /// @param expiresAt When the existing period ends or ended.
    error AccessRecordExists(uint64 expiresAt);

    /// @notice Thrown when an account has never held a period, or its record has been cleared.
    error NoAccess();

    /// @notice Thrown when a withdrawal or renewal is attempted before the period ends.
    /// @param expiresAt When the period ends.
    error NotExpired(uint64 expiresAt);

    /// @notice Thrown when a caller other than the audit hub touches quota.
    /// @param caller The rejected caller.
    error NotTheAuditHub(address caller);

    /// @notice Thrown when the quoted requirement exceeds the caller's stated maximum.
    /// @param required The quoted requirement.
    /// @param maxKay9 The caller's maximum.
    error RequirementAboveMax(uint256 required, uint256 maxKay9);

    /// @notice Thrown when a tier's quota for the period is already spent.
    /// @param tier The exhausted tier.
    error QuotaExhausted(uint8 tier);

    /// @notice Thrown when the held tier does not cover the requested one.
    /// @param have The tier the account holds.
    /// @param want The tier the account asked for.
    error TierNotPermitted(uint8 have, uint8 want);

    /// @notice Thrown when upgrade is called on a period that is not deep.
    /// @param tier The current tier.
    error NotAnUpgrade(uint8 tier);

    /// @notice Thrown when a period length outside the allowed range is configured.
    error InvalidLockDuration();

    /// @notice Thrown when a quota outside the allowed range is configured.
    error InvalidQuota();

    /// @notice Thrown when governance proposes a requirement outside the bounds, or a forensic
    ///         requirement below the deep one.
    /// @dev A record with `lockedKay9 == 0` is how the vault spells "no record", so the floor is
    ///      what keeps a period from ever opening on nothing; the ceiling keeps a typo from asking
    ///      for a meaningful share of the supply.
    error InvalidRequirement();

    /// @notice The deep access tier.
    uint8 public constant TIER_DEEP = 1;

    /// @notice The forensic access tier.
    uint8 public constant TIER_FORENSIC = 2;

    /// @notice The shortest period governance may configure.
    uint64 public constant MIN_LOCK_DURATION = 7 days;

    /// @notice The longest period governance may configure.
    uint64 public constant MAX_LOCK_DURATION = 365 days;

    /// @notice The largest per-period allowance governance may configure for either tier.
    uint32 public constant MAX_QUOTA = 1000;

    /// @notice The smallest requirement governance may configure: one KAY9.
    uint256 public constant MIN_REQUIREMENT = 1e18;

    /// @notice The largest requirement governance may configure: one percent of the supply.
    uint256 public constant MAX_REQUIREMENT = 10_000_000e18;

    /// @notice The token that is locked.
    IERC20 public immutable kay9;

    /// @notice The KAY9 a tier requires, in wei. Copied into a record when its period opens.
    mapping(uint8 tier => uint256) public requirementOf;

    /// @notice The only address allowed to debit quota.
    address public auditHub;

    /// @notice Hubs that `setAuditHub` has replaced. They may still credit quota back, never debit.
    /// @dev A job pending on the old hub when governance moves to a new one still has to expire or
    ///      dispute, and both of those hand the unit back through `restore`. Without this, the old
    ///      hub's terminal transitions would revert `NotTheAuditHub` forever and the jobs would stay
    ///      open with their units stranded. Nothing here can take a unit or touch a balance.
    mapping(address hub => bool) public isRetiredHub;

    /// @notice How long a period lasts, in seconds.
    uint64 public lockDuration;

    /// @notice Deep audits allowed per period, by tier.
    mapping(uint8 tier => uint32) public deepQuotaOf;

    /// @notice Forensic audits allowed per period, by tier.
    mapping(uint8 tier => uint32) public forensicQuotaOf;

    /// @notice The sum of every principal the vault holds. Never includes anything else.
    uint256 public totalLocked;

    /// @notice Every account's access record.
    mapping(address account => Access) private _access;

    /// @notice Deploys the vault.
    /// @dev The hub is set afterwards with setAuditHub, because the hub needs this address in its
    ///      own constructor and the two cannot both be immutable.
    /// @param owner_ The owner, which in production is the TimelockController.
    /// @param kay9_ The KAY9 token.
    constructor(address owner_, IERC20 kay9_) Ownable(owner_) {
        if (address(kay9_) == address(0)) revert ZeroAddress();
        kay9 = kay9_;
        lockDuration = 30 days;

        requirementOf[TIER_DEEP] = 5_000e18;
        requirementOf[TIER_FORENSIC] = 10_000e18;

        deepQuotaOf[TIER_DEEP] = 4;
        forensicQuotaOf[TIER_DEEP] = 0;
        deepQuotaOf[TIER_FORENSIC] = 4;
        forensicQuotaOf[TIER_FORENSIC] = 1;

        emit LockDurationUpdated(30 days);
        emit QuotaConfigured(TIER_DEEP, 4, 0);
        emit QuotaConfigured(TIER_FORENSIC, 4, 1);
        emit RequirementConfigured(TIER_DEEP, 5_000e18);
        emit RequirementConfigured(TIER_FORENSIC, 10_000e18);
    }

    // -------------------------------------------------------------------------------------------
    // Locking
    // -------------------------------------------------------------------------------------------

    /// @notice Opens an access period, taking the required KAY9 from the caller.
    /// @param tier The tier to open.
    /// @param maxKay9 The most the caller is willing to lock.
    function lock(uint8 tier, uint256 maxKay9) public nonReentrant {
        Access storage a = _access[msg.sender];
        if (a.lockedKay9 != 0) {
            if (block.timestamp < a.expiresAt) revert AccessLive(a.expiresAt);
            revert AccessRecordExists(a.expiresAt);
        }

        _requireValidTier(tier);
        uint256 required = requirementOf[tier];
        if (required > maxKay9) revert RequirementAboveMax(required, maxKay9);

        uint64 startedAt = uint64(block.timestamp);
        uint64 expiresAt = startedAt + lockDuration;
        uint32 deepQuota = deepQuotaOf[tier];
        uint32 forensicQuota = forensicQuotaOf[tier];

        _access[msg.sender] = Access({
            tier: tier,
            startedAt: startedAt,
            expiresAt: expiresAt,
            deepQuota: deepQuota,
            forensicQuota: forensicQuota,
            deepUsed: 0,
            forensicUsed: 0,
            lockedKay9: required
        });
        totalLocked += required;

        emit AccessLocked(msg.sender, tier, required, startedAt, expiresAt, deepQuota, forensicQuota);

        kay9.safeTransferFrom(msg.sender, address(this), required);
    }

    /// @notice Opens an access period, taking the allowance from an ERC-2612 permit first.
    /// @dev A failing permit is tolerated when the allowance is already in place, so a griefer
    ///      cannot brick the call by front-running the permit.
    /// @param tier The tier to open.
    /// @param maxKay9 The most the caller is willing to lock, and the permitted allowance.
    /// @param deadline The permit deadline.
    /// @param v The permit signature v value.
    /// @param r The permit signature r value.
    /// @param s The permit signature s value.
    function lockWithPermit(uint8 tier, uint256 maxKay9, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        try IERC20Permit(address(kay9)).permit(msg.sender, address(this), maxKay9, deadline, v, r, s) {} catch {}
        lock(tier, maxKay9);
    }

    /// @notice Replaces an expired period with a fresh one at the current requirement.
    /// @dev Refused before expiry. Allowing an early renewal would reset the quota inside a period
    ///      that has already been paid for once, which is the one way a depositor could get more
    ///      audits than the tier allows without locking more.
    /// @param tier The tier for the new period, which may differ from the old one.
    /// @param maxKay9 The most the caller is willing to have locked in total.
    function renew(uint8 tier, uint256 maxKay9) external nonReentrant {
        Access storage a = _access[msg.sender];
        if (a.lockedKay9 == 0) revert NoAccess();
        if (block.timestamp < a.expiresAt) revert NotExpired(a.expiresAt);

        _requireValidTier(tier);
        uint256 required = requirementOf[tier];
        if (required > maxKay9) revert RequirementAboveMax(required, maxKay9);

        uint256 held = a.lockedKay9;
        uint256 toppedUp = required > held ? required - held : 0;
        uint256 returned = held > required ? held - required : 0;

        uint64 startedAt = uint64(block.timestamp);
        uint64 expiresAt = startedAt + lockDuration;

        a.tier = tier;
        a.startedAt = startedAt;
        a.expiresAt = expiresAt;
        a.deepQuota = deepQuotaOf[tier];
        a.forensicQuota = forensicQuotaOf[tier];
        a.deepUsed = 0;
        a.forensicUsed = 0;
        a.lockedKay9 = required;
        totalLocked = totalLocked - held + required;

        emit AccessRenewed(msg.sender, tier, required, toppedUp, returned, startedAt, expiresAt);

        if (toppedUp != 0) kay9.safeTransferFrom(msg.sender, address(this), toppedUp);
        if (returned != 0) kay9.safeTransfer(msg.sender, returned);
    }

    /// @notice Raises a live deep period to forensic, topping up to the forensic requirement.
    /// @dev The expiry does not move and `deepUsed` is preserved, so the only thing gained is the
    ///      forensic allowance the larger lock pays for.
    ///
    ///      An upgrade only ever adds. A live period keeps what it locked with, so when governance
    ///      has since lowered the forensic requirement below what this period already holds, the
    ///      principal stays where it is and nothing is taken: the lower requirement applies from
    ///      the next `renew`, or after `unlock`. Settling downwards here would hand principal back
    ///      in the middle of a period, which is the one thing a lock promises not to do, and would
    ///      make a requirement change reach back into periods opened before it. The deep allowance
    ///      follows the same rule and keeps the larger of what the period was opened with and what
    ///      a forensic period is given today, so a later `setQuota` cannot shrink it either.
    /// @param maxKay9 The most the caller is willing to have locked in total.
    function upgrade(uint256 maxKay9) external nonReentrant {
        Access storage a = _access[msg.sender];
        if (a.lockedKay9 == 0) revert NoAccess();
        if (block.timestamp >= a.expiresAt) revert NotExpired(a.expiresAt);
        if (a.tier != TIER_DEEP) revert NotAnUpgrade(a.tier);

        uint256 required = requirementOf[TIER_FORENSIC];
        uint256 held = a.lockedKay9;
        uint256 locked = required > held ? required : held;
        // Checked against what the call leaves locked, which is what the caller is agreeing to.
        if (locked > maxKay9) revert RequirementAboveMax(locked, maxKay9);

        uint256 toppedUp = locked - held;
        uint32 forensicQuota = forensicQuotaOf[TIER_FORENSIC];
        uint32 deepQuota = deepQuotaOf[TIER_FORENSIC];

        a.tier = TIER_FORENSIC;
        if (deepQuota > a.deepQuota) a.deepQuota = deepQuota;
        a.forensicQuota = forensicQuota;
        a.lockedKay9 = locked;
        totalLocked += toppedUp;

        emit AccessUpgraded(msg.sender, locked, toppedUp, forensicQuota);

        if (toppedUp != 0) kay9.safeTransferFrom(msg.sender, address(this), toppedUp);
    }

    /// @notice Returns the whole principal once the period has ended.
    /// @dev Reads nothing but the record, so no configuration change can ever trap a depositor's
    ///      tokens.
    function unlock() external nonReentrant {
        Access storage a = _access[msg.sender];
        uint256 amount = a.lockedKay9;
        if (amount == 0) revert NoAccess();
        if (block.timestamp < a.expiresAt) revert NotExpired(a.expiresAt);

        delete _access[msg.sender];
        totalLocked -= amount;

        emit AccessUnlocked(msg.sender, amount);
        kay9.safeTransfer(msg.sender, amount);
    }

    // -------------------------------------------------------------------------------------------
    // Quota, moved only by the audit hub
    // -------------------------------------------------------------------------------------------

    /// @notice Debits one quota unit of a tier. Callable only by the audit hub.
    /// @param account The requester.
    /// @param tier The tier being requested.
    /// @return periodStartedAt The period the unit came from, recorded on the job.
    function consume(address account, uint8 tier) external returns (uint64 periodStartedAt) {
        if (msg.sender != auditHub) revert NotTheAuditHub(msg.sender);
        _requireValidTier(tier);

        Access storage a = _access[account];
        if (a.lockedKay9 == 0) revert NoAccess();
        if (block.timestamp >= a.expiresAt) revert NotExpired(a.expiresAt);
        if (a.tier < tier) revert TierNotPermitted(a.tier, tier);

        if (tier == TIER_DEEP) {
            if (a.deepUsed >= a.deepQuota) revert QuotaExhausted(tier);
            unchecked {
                a.deepUsed += 1;
            }
        } else {
            if (a.forensicUsed >= a.forensicQuota) revert QuotaExhausted(tier);
            unchecked {
                a.forensicUsed += 1;
            }
        }

        emit QuotaConsumed(account, tier, a.deepUsed, a.forensicUsed);
        return a.startedAt;
    }

    /// @notice Credits one quota unit back after a job produced no result.
    /// @dev Silently does nothing when the period has since been replaced, so a credit can never
    ///      leak into a period that did not pay for it. Accepted from the current hub and from any
    ///      hub it has replaced, so a job that was pending across a hub migration can still hand
    ///      its unit back; a retired hub cannot debit anything.
    /// @param account The requester.
    /// @param tier The tier to credit.
    /// @param periodStartedAt The period the unit was taken from.
    function restore(address account, uint8 tier, uint64 periodStartedAt) external {
        if (msg.sender != auditHub && !isRetiredHub[msg.sender]) revert NotTheAuditHub(msg.sender);

        Access storage a = _access[account];
        if (a.startedAt != periodStartedAt || a.lockedKay9 == 0) return;

        if (tier == TIER_DEEP) {
            if (a.deepUsed == 0) return;
            unchecked {
                a.deepUsed -= 1;
            }
        } else if (tier == TIER_FORENSIC) {
            if (a.forensicUsed == 0) return;
            unchecked {
                a.forensicUsed -= 1;
            }
        } else {
            return;
        }

        emit QuotaRestored(account, tier, a.deepUsed, a.forensicUsed);
    }

    // -------------------------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------------------------

    /// @notice An account's access record.
    /// @param account The account.
    /// @return The record, zeroed if the account holds no period.
    function accessOf(address account) external view returns (Access memory) {
        return _access[account];
    }

    /// @notice Whether an account holds a period that has not ended.
    /// @param account The account.
    /// @return True while the period is live.
    function isActive(address account) public view returns (bool) {
        Access storage a = _access[account];
        return a.lockedKay9 != 0 && block.timestamp < a.expiresAt;
    }

    /// @notice Deep audits left in an account's live period.
    /// @param account The account.
    /// @return The remaining deep allowance, zero when no period is live.
    function deepRemaining(address account) external view returns (uint32) {
        if (!isActive(account)) return 0;
        Access storage a = _access[account];
        return a.deepUsed >= a.deepQuota ? 0 : a.deepQuota - a.deepUsed;
    }

    /// @notice Forensic audits left in an account's live period.
    /// @param account The account.
    /// @return The remaining forensic allowance, zero when no period is live.
    function forensicRemaining(address account) external view returns (uint32) {
        if (!isActive(account)) return 0;
        Access storage a = _access[account];
        return a.forensicUsed >= a.forensicQuota ? 0 : a.forensicQuota - a.forensicUsed;
    }

    /// @notice Whether an account could request a tier right now.
    /// @dev Mirrors consume exactly, so a false here means the hub would revert.
    /// @param account The account.
    /// @param tier The tier.
    /// @return True when the request would be accepted.
    function canRequest(address account, uint8 tier) external view returns (bool) {
        if (!isActive(account)) return false;
        Access storage a = _access[account];
        if (a.tier < tier) return false;
        if (tier == TIER_DEEP) return a.deepUsed < a.deepQuota;
        if (tier == TIER_FORENSIC) return a.forensicUsed < a.forensicQuota;
        return false;
    }

    // -------------------------------------------------------------------------------------------
    // Governance. None of these can move a depositor's principal.
    // -------------------------------------------------------------------------------------------

    /// @notice Points the vault at the audit hub allowed to debit quota.
    /// @dev The hub being replaced keeps the right to `restore`, and nothing else, so its pending
    ///      jobs can still expire or dispute cleanly. Re-pointing at a retired hub reinstates it.
    /// @param auditHub_ The hub.
    function setAuditHub(address auditHub_) external onlyOwner {
        if (auditHub_ == address(0)) revert ZeroAddress();
        address previous = auditHub;
        if (previous != address(0) && previous != auditHub_) {
            isRetiredHub[previous] = true;
            emit AuditHubRetired(previous);
        }
        if (isRetiredHub[auditHub_]) delete isRetiredHub[auditHub_];
        auditHub = auditHub_;
        emit AuditHubUpdated(auditHub_);
    }

    /// @notice Sets a tier's per-period allowances. Live periods keep the allowances they opened
    ///         with, because those are copied into the record at lock time.
    /// @param tier The tier to configure.
    /// @param deepQuota Deep audits per period.
    /// @param forensicQuota Forensic audits per period.
    function setQuota(uint8 tier, uint32 deepQuota, uint32 forensicQuota) external onlyOwner {
        _requireValidTier(tier);
        if (deepQuota > MAX_QUOTA || forensicQuota > MAX_QUOTA) revert InvalidQuota();
        if (tier == TIER_DEEP && forensicQuota != 0) revert InvalidQuota();
        deepQuotaOf[tier] = deepQuota;
        forensicQuotaOf[tier] = forensicQuota;
        emit QuotaConfigured(tier, deepQuota, forensicQuota);
    }

    /// @notice Sets the KAY9 a tier requires for periods opened or renewed from now on. Live
    ///         periods keep what they locked with, and `unlock` returns exactly that.
    /// @dev Bounded so a typo can neither open periods on nothing nor ask for a meaningful share
    ///      of the supply, and forensic can never require less than deep, which would make
    ///      `upgrade` a way to get KAY9 back mid-period.
    /// @param tier The tier to configure.
    /// @param amount The requirement, in KAY9 wei, within [MIN_REQUIREMENT, MAX_REQUIREMENT].
    function setRequirement(uint8 tier, uint256 amount) external onlyOwner {
        _requireValidTier(tier);
        if (amount < MIN_REQUIREMENT || amount > MAX_REQUIREMENT) revert InvalidRequirement();
        uint256 deep = tier == TIER_DEEP ? amount : requirementOf[TIER_DEEP];
        uint256 forensic = tier == TIER_FORENSIC ? amount : requirementOf[TIER_FORENSIC];
        if (forensic < deep) revert InvalidRequirement();
        requirementOf[tier] = amount;
        emit RequirementConfigured(tier, amount);
    }

    /// @notice Sets the length of future periods. Live periods keep the expiry they opened with.
    /// @param newDuration The new length, within [MIN_LOCK_DURATION, MAX_LOCK_DURATION].
    function setLockDuration(uint64 newDuration) external onlyOwner {
        if (newDuration < MIN_LOCK_DURATION || newDuration > MAX_LOCK_DURATION) revert InvalidLockDuration();
        lockDuration = newDuration;
        emit LockDurationUpdated(newDuration);
    }

    // -------------------------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------------------------

    /// @notice Rejects any tier that is not deep or forensic.
    /// @param tier The tier to check.
    function _requireValidTier(uint8 tier) private pure {
        if (tier != TIER_DEEP && tier != TIER_FORENSIC) revert InvalidTier(tier);
    }
}
