// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9TeamVesting, ILaunchSettlement} from "../../src/KAY9TeamVesting.sol";
import {KAY9AccessVault} from "../../src/KAY9AccessVault.sol";
import {KAY9AuditHub} from "../../src/KAY9AuditHub.sol";
import {KAY9Registry} from "../../src/KAY9Registry.sol";
import {KAY9LiquidityLock} from "../../src/KAY9LiquidityLock.sol";

/// @notice A token that calls back into a target on every transfer, to probe reentrancy.
contract HostileToken is ERC20, ERC20Burnable {
    /// @notice The contract to re-enter.
    address public target;

    /// @notice The calldata to re-enter with.
    bytes public payload;

    /// @notice Whether a re-entrant attempt has already been made.
    bool public fired;

    /// @notice Whether the re-entrant attempt succeeded.
    bool public succeeded;

    /// @notice Mints an initial supply to the deployer.
    constructor() ERC20("Hostile", "HOSTILE") {
        _mint(msg.sender, 1_000_000e18);
    }

    /// @notice Arms the callback.
    /// @param target_ The contract to re-enter.
    /// @param payload_ The calldata to re-enter with.
    function arm(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
        fired = false;
        succeeded = false;
    }

    /// @notice Mints tokens for test setup.
    /// @param to The receiver.
    /// @param amount The amount.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @inheritdoc ERC20
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && !fired) {
            fired = true;
            (bool ok,) = target.call(payload);
            succeeded = ok;
        }
    }
}

/// @notice A depositor that is itself a contract, so a re-entrant request really does arrive at the
///         hub from the account that holds the access period.
/// @dev A callback from inside the token would otherwise arrive as the token's own address, which
///      proves nothing: the interesting attack is the depositor spending quota from a period it is
///      in the middle of dismantling.
contract ReentrantDepositor {
    /// @notice The vault to lock in.
    KAY9AccessVault public immutable vault;

    /// @notice The hub to request audits from.
    KAY9AuditHub public immutable hub;

    /// @notice The token the vault locks.
    IERC20 public immutable lockToken;

    /// @notice The chain key the re-entrant request names.
    bytes32 public immutable chainKey;

    /// @notice Whether the callback should try to re-enter.
    bool public armed;

    /// @notice Whether the callback ran.
    bool public fired;

    /// @notice Whether the re-entrant request succeeded.
    bool public succeeded;

    /// @notice The job id the re-entrant request produced, if any.
    uint256 public reentrantJobId;

    /// @notice Binds the depositor to the deployment under test.
    /// @param vault_ The vault.
    /// @param hub_ The hub.
    /// @param lockToken_ The token the vault locks.
    /// @param chainKey_ The chain key to name in a request.
    constructor(KAY9AccessVault vault_, KAY9AuditHub hub_, IERC20 lockToken_, bytes32 chainKey_) {
        vault = vault_;
        hub = hub_;
        lockToken = lockToken_;
        chainKey = chainKey_;
    }

    /// @notice Opens an access period for this contract.
    /// @param tier The tier to open.
    function openAccess(uint8 tier) external {
        lockToken.approve(address(vault), type(uint256).max);
        vault.lock(tier, type(uint256).max);
    }

    /// @notice Arms the re-entrant attempt.
    function arm() external {
        armed = true;
        fired = false;
        succeeded = false;
    }

    /// @notice Withdraws the principal.
    function withdraw() external {
        vault.unlock();
    }

    /// @notice Requests an audit the ordinary way.
    /// @param tier The tier to request.
    /// @return The new job id.
    function requestAudit(uint8 tier) external returns (uint256) {
        return hub.requestAudit(chainKey, bytes32(uint256(1)), tier, 1);
    }

    /// @notice The callback the hostile token invokes mid-transfer.
    function reenter() external {
        if (!armed || fired) return;
        fired = true;
        try hub.requestAudit(chainKey, bytes32(uint256(7)), 1, 1) returns (uint256 jobId) {
            succeeded = true;
            reentrantJobId = jobId;
        } catch {}
    }
}

/// @notice An ERC721 that pretends to be a position manager, to probe the lock's receiver guard.
contract HostileNft {
    /// @notice Sends a fake receiver callback to the lock.
    /// @param lock The lock to probe.
    /// @param tokenId The token id to claim.
    function attack(KAY9LiquidityLock lock, uint256 tokenId) external {
        lock.onERC721Received(address(this), address(this), tokenId, "");
    }
}

/// @title KAY9ReentrancyTest
/// @notice Proves that a hostile locked token cannot make the access vault release a principal
///         twice or hand out quota it did not sell, that vesting cannot be re-entered, and that the
///         liquidity lock only trusts the canonical position manager.
contract KAY9ReentrancyTest is Kay9TestBase {
    /// @notice The hostile token used as a stand-in locked asset.
    HostileToken internal hostile;

    /// @notice A vault that locks the hostile token.
    KAY9AccessVault internal hostileVault;

    /// @notice The hub bound to that vault.
    KAY9AuditHub internal hostileHub;

    /// @notice The registry bound to that hub.
    KAY9Registry internal hostileRegistry;

    /// @inheritdoc Kay9TestBase
    function setUp() public override {
        super.setUp();
        hostile = new HostileToken();
        _deployHostileStack();
    }

    /// @notice A hostile token cannot make the vesting contract release the same tranche twice.
    function test_vestingResistsReentrantToken() public {
        KAY9TeamVesting hostileVesting = new KAY9TeamVesting(
            IERC20(address(hostile)), teamBeneficiary, ILaunchSettlement(address(genesis)), tge, unlock6m, unlock12m
        );
        vm.mockCall(address(genesis), abi.encodeWithSignature("settled()"), abi.encode(true));
        hostile.mint(address(hostileVesting), 90_000_000e18);

        hostile.arm(address(hostileVesting), abi.encodeCall(KAY9TeamVesting.release, ()));
        vm.warp(tge);
        hostileVesting.release();

        assertTrue(hostile.fired(), "the callback ran");
        assertFalse(hostile.succeeded(), "the re-entrant release was rejected");
        assertEq(hostileVesting.released(), 10_000_000e18, "exactly one tranche left the contract");
        assertEq(hostile.balanceOf(teamBeneficiary), 10_000_000e18, "and the beneficiary got exactly that");
    }

    /// @notice A hostile token cannot re-enter a lock to open a second period.
    function test_lockCannotBeReenteredToOpenASecondPeriod() public {
        uint256 required = hostileVault.requirementOf(TIER_DEEP);
        hostile.mint(address(this), required * 4);
        hostile.approve(address(hostileVault), type(uint256).max);

        hostile.arm(address(hostileVault), abi.encodeCall(KAY9AccessVault.lock, (TIER_DEEP, type(uint256).max)));
        hostileVault.lock(TIER_DEEP, type(uint256).max);

        assertTrue(hostile.fired(), "the callback ran");
        assertFalse(hostile.succeeded(), "the re-entrant lock was rejected");
        assertEq(hostile.balanceOf(address(hostileVault)), required, "exactly one principal was taken");
        assertEq(hostileVault.totalLocked(), required, "and exactly one is counted");
    }

    /// @notice A hostile token cannot re-enter an unlock to withdraw the same principal twice.
    function test_unlockCannotBeReenteredToWithdrawTwice() public {
        uint256 required = hostileVault.requirementOf(TIER_DEEP);
        hostile.mint(address(this), required);
        hostile.approve(address(hostileVault), type(uint256).max);
        hostileVault.lock(TIER_DEEP, type(uint256).max);
        uint256 balanceBefore = hostile.balanceOf(address(this));

        vm.warp(hostileVault.accessOf(address(this)).expiresAt);
        hostile.arm(address(hostileVault), abi.encodeCall(KAY9AccessVault.unlock, ()));
        hostileVault.unlock();

        assertTrue(hostile.fired(), "the callback ran");
        assertFalse(hostile.succeeded(), "the re-entrant unlock was rejected");
        assertEq(hostile.balanceOf(address(this)) - balanceBefore, required, "the principal came back exactly once");
        assertEq(hostile.balanceOf(address(hostileVault)), 0, "and the vault kept nothing");
        assertEq(hostileVault.totalLocked(), 0, "and owes nothing");
    }

    /// @notice A depositor cannot spend quota from a period it is in the middle of unlocking.
    function test_quotaCannotBeSpentWhileUnlocking() public {
        ReentrantDepositor depositor = new ReentrantDepositor(
            hostileVault, hostileHub, IERC20(address(hostile)), reportRegistry.CHAIN_ROBINHOOD()
        );
        uint256 required = hostileVault.requirementOf(TIER_DEEP);
        hostile.mint(address(depositor), required);
        depositor.openAccess(TIER_DEEP);

        vm.warp(hostileVault.accessOf(address(depositor)).expiresAt);
        depositor.arm();
        hostile.arm(address(depositor), abi.encodeCall(ReentrantDepositor.reenter, ()));
        depositor.withdraw();

        assertTrue(depositor.fired(), "the depositor's callback ran");
        assertFalse(depositor.succeeded(), "the re-entrant request was refused");
        assertEq(hostileHub.jobCount(), 0, "no job was created");
        assertEq(hostile.balanceOf(address(depositor)), required, "and the principal still came back in full");
    }

    /// @notice Re-entering a lock cannot conjure quota the period did not sell.
    /// @dev The request that arrives mid-lock is legitimate, because the period is already written
    ///      when the transfer happens. What must hold is that it is counted: the depositor still
    ///      gets four deep audits in total and not five.
    function test_reenteringALockCannotCreateExtraQuota() public {
        ReentrantDepositor depositor = new ReentrantDepositor(
            hostileVault, hostileHub, IERC20(address(hostile)), reportRegistry.CHAIN_ROBINHOOD()
        );
        uint256 required = hostileVault.requirementOf(TIER_DEEP);
        hostile.mint(address(depositor), required);

        depositor.arm();
        hostile.arm(address(depositor), abi.encodeCall(ReentrantDepositor.reenter, ()));
        depositor.openAccess(TIER_DEEP);

        assertTrue(depositor.fired(), "the depositor's callback ran");
        assertEq(hostileVault.deepRemaining(address(depositor)), 3, "the re-entrant request was charged for");

        // Three more, and no more.
        for (uint256 i = 0; i < 3; ++i) {
            depositor.requestAudit(TIER_DEEP);
        }
        assertEq(hostileVault.deepRemaining(address(depositor)), 0, "four audits in total, not five");
        vm.expectRevert(abi.encodeWithSelector(KAY9AccessVault.QuotaExhausted.selector, TIER_DEEP));
        depositor.requestAudit(TIER_DEEP);
    }

    /// @notice A fake NFT cannot register itself with the liquidity lock.
    function test_lockRejectsHostileNft() public {
        HostileNft attacker = new HostileNft();
        vm.expectRevert(abi.encodeWithSelector(KAY9LiquidityLock.NotPositionManager.selector, address(attacker)));
        attacker.attack(lock, 1);
        assertEq(lock.lockedCount(), 0, "nothing was registered");
    }

    /// @notice Deploys a vault, hub and registry whose locked asset is the hostile token.
    function _deployHostileStack() internal {
        hostileVault = new KAY9AccessVault(address(this), IERC20(address(hostile)));

        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 1);
        hostileRegistry = new KAY9Registry(predicted);
        hostileHub = new KAY9AuditHub(address(timelock), address(hostileRegistry), auditorRegistry, hostileVault);
        assertEq(address(hostileHub), predicted, "hostile hub address prediction");

        hostileVault.setAuditHub(address(hostileHub));
    }
}
