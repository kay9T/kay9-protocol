// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The one thing this contract needs to know about the launch.
interface ILaunchSettlement {
    /// @notice True once the launch has placed its liquidity and can never be relaunched.
    /// @return Whether the launch is settled.
    function settled() external view returns (bool);
}

/// @title KAY9TeamVesting
/// @notice Holds the 90,000,000 KAY9 team allocation and releases it in three tranches at
///         timestamps fixed at deployment. Nobody, including the beneficiary, can unlock a tranche
///         early, change a timestamp, change an amount, or withdraw anything else. The only mutable
///         state besides the released counter is the beneficiary address, which the current
///         beneficiary may hand to someone else.
/// @dev The unlock timestamps are exact UTC calendar dates computed off-chain by
///      script/ComputeVesting.s.sol, not 180-day approximations.
///
///      The dates are fixed when the contracts are deployed, which is days before the launch is
///      signed, and a launch can slip or fail and be run again. The calendar alone would then hand
///      the team liquid KAY9 before the public had been able to buy any. So nothing is released
///      until the launch has settled, which is the point at which its liquidity is placed and
///      locked for good. That can only ever delay the team, never bring a tranche forward: once
///      the launch is settled the schedule is the calendar and nothing else.
/// @custom:security-contact security@kay9.io
contract KAY9TeamVesting {
    using SafeERC20 for IERC20;

    /// @notice Emitted whenever unlocked tokens are sent to the beneficiary.
    /// @param beneficiary The receiver of the released tokens.
    /// @param amount The amount released by this call.
    /// @param totalReleased The cumulative amount released after this call.
    event Released(address indexed beneficiary, uint256 amount, uint256 totalReleased);

    /// @notice Emitted when the beneficiary role moves to a new address.
    /// @param previousBeneficiary The outgoing beneficiary.
    /// @param newBeneficiary The incoming beneficiary.
    event BeneficiaryTransferred(address indexed previousBeneficiary, address indexed newBeneficiary);

    /// @notice Emitted when the beneficiary names a successor, or withdraws one by naming zero.
    /// @param beneficiary The current beneficiary.
    /// @param proposed The address that may now accept the role, or zero.
    event BeneficiaryTransferProposed(address indexed beneficiary, address indexed proposed);

    /// @notice Thrown when a constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the unlock timestamps are not strictly increasing.
    error UnlockOrder();

    /// @notice Thrown when a caller other than the beneficiary calls a beneficiary-only function.
    error NotBeneficiary();

    /// @notice Thrown when release is called with nothing unlocked left to send.
    error NothingToRelease();

    /// @notice Thrown when release is called before the launch has settled.
    error LaunchNotSettled();

    /// @notice Thrown when somebody other than the proposed successor tries to accept the role.
    error NotPendingBeneficiary();

    /// @notice The launch whose settlement opens the schedule.
    ILaunchSettlement public immutable launch;

    /// @notice The KAY9 token this contract vests.
    IERC20 public immutable token;

    /// @notice The full team allocation held by this contract.
    uint256 public constant TOTAL_ALLOCATION = 90_000_000e18;

    /// @notice The tranche unlocked at the token generation event.
    uint256 public constant TRANCHE_1 = 10_000_000e18;

    /// @notice The tranche unlocked six calendar months after the token generation event.
    uint256 public constant TRANCHE_2 = 40_000_000e18;

    /// @notice The tranche unlocked twelve calendar months after the token generation event.
    uint256 public constant TRANCHE_3 = 40_000_000e18;

    /// @notice The token generation event timestamp. Tranche 1 unlocks here.
    uint64 public immutable tgeTimestamp;

    /// @notice The timestamp tranche 2 unlocks at.
    uint64 public immutable unlock6mTimestamp;

    /// @notice The timestamp tranche 3 unlocks at.
    uint64 public immutable unlock12mTimestamp;

    /// @notice The address that receives released tokens.
    address public beneficiary;

    /// @notice The address the beneficiary has named as its successor, or zero.
    address public pendingBeneficiary;

    /// @notice The cumulative amount already released.
    uint256 public released;

    /// @notice Deploys the vesting contract with an immutable schedule.
    /// @param token_ The KAY9 token.
    /// @param beneficiary_ The initial beneficiary.
    /// @param launch_ The launch whose settlement opens the schedule.
    /// @param tge The token generation event timestamp.
    /// @param unlock6m The tranche 2 unlock timestamp. Must be after tge.
    /// @param unlock12m The tranche 3 unlock timestamp. Must be after unlock6m.
    constructor(
        IERC20 token_,
        address beneficiary_,
        ILaunchSettlement launch_,
        uint64 tge,
        uint64 unlock6m,
        uint64 unlock12m
    ) {
        if (address(token_) == address(0) || beneficiary_ == address(0) || address(launch_) == address(0)) {
            revert ZeroAddress();
        }
        if (!(tge < unlock6m && unlock6m < unlock12m)) revert UnlockOrder();
        token = token_;
        launch = launch_;
        beneficiary = beneficiary_;
        tgeTimestamp = tge;
        unlock6mTimestamp = unlock6m;
        unlock12mTimestamp = unlock12m;
        emit BeneficiaryTransferred(address(0), beneficiary_);
    }

    /// @notice The cumulative amount the calendar has unlocked at the current block timestamp.
    /// @dev A tranche counts as unlocked the moment block.timestamp reaches its timestamp, so the
    ///      boundary second is inclusive. This is the schedule and nothing else; whether any of it
    ///      can be taken yet is `releasable`, which also asks whether the launch has settled.
    /// @return amount The cumulative unlocked amount.
    function unlocked() public view returns (uint256 amount) {
        uint256 nowTs = block.timestamp;
        if (nowTs >= tgeTimestamp) amount += TRANCHE_1;
        if (nowTs >= unlock6mTimestamp) amount += TRANCHE_2;
        if (nowTs >= unlock12mTimestamp) amount += TRANCHE_3;
    }

    /// @notice The amount that release would send right now.
    /// @return The unlocked amount that has not yet been released, or zero before the launch settles.
    function releasable() public view returns (uint256) {
        if (!launch.settled()) return 0;
        return unlocked() - released;
    }

    /// @notice Sends everything currently unlocked to the beneficiary. Permissionless.
    /// @dev State is written before the transfer so a hostile token cannot re-enter for a second
    ///      release.
    function release() external {
        if (!launch.settled()) revert LaunchNotSettled();
        uint256 amount = releasable();
        if (amount == 0) revert NothingToRelease();
        uint256 totalReleased = released + amount;
        released = totalReleased;
        address to = beneficiary;
        emit Released(to, amount, totalReleased);
        token.safeTransfer(to, amount);
    }

    /// @notice Names the address that may take over the beneficiary role.
    /// @dev Two steps, because the role is worth the whole allocation and an address is forty
    ///      characters somebody typed. Nothing changes until the named address accepts, which
    ///      proves it exists and somebody holds its key; until then the current beneficiary can
    ///      name a different one, or name zero to withdraw the proposal.
    /// @param newBeneficiary The proposed beneficiary, or zero to withdraw a proposal.
    function transferBeneficiary(address newBeneficiary) external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        pendingBeneficiary = newBeneficiary;
        emit BeneficiaryTransferProposed(msg.sender, newBeneficiary);
    }

    /// @notice Takes over the beneficiary role. Only the proposed address can call this.
    function acceptBeneficiary() external {
        if (msg.sender != pendingBeneficiary) revert NotPendingBeneficiary();
        address previous = beneficiary;
        beneficiary = msg.sender;
        pendingBeneficiary = address(0);
        emit BeneficiaryTransferred(previous, msg.sender);
    }

    /// @notice The complete immutable schedule.
    /// @return timestamps The three unlock timestamps in ascending order.
    /// @return amounts The three tranche amounts, aligned with timestamps.
    function schedule() external view returns (uint64[3] memory timestamps, uint256[3] memory amounts) {
        timestamps = [tgeTimestamp, unlock6mTimestamp, unlock12mTimestamp];
        amounts = [TRANCHE_1, TRANCHE_2, TRANCHE_3];
    }
}
