// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title KAY9AuditorRegistry
/// @notice The set of addresses whose signatures the audit hub accepts, plus the quorum threshold.
///         The owner is the 48-hour TimelockController, so adding an auditor or changing the
///         threshold is always visible on-chain before it takes effect. Removal goes through the
///         same timelock but is expected to be scheduled immediately on a key compromise.
/// @dev The auditor list is kept as an array plus an index map so the whole set can be read in one
///      call by the website without an archive node.
/// @custom:security-contact security@kay9.io
contract KAY9AuditorRegistry is Ownable2Step {
    /// @notice Emitted when an address joins the auditor set.
    /// @param auditor The added auditor.
    event AuditorAdded(address indexed auditor);

    /// @notice Emitted when an address leaves the auditor set.
    /// @param auditor The removed auditor.
    event AuditorRemoved(address indexed auditor);

    /// @notice Emitted when the quorum threshold changes.
    /// @param threshold The new threshold.
    event ThresholdUpdated(uint8 threshold);

    /// @notice Emitted when the last auditor leaves and no quorum can form any more.
    /// @dev The halted state. Nothing can be attested or published until an auditor is added and
    ///      a threshold is set again. See `removeAuditor`.
    event QuorumHalted();

    /// @notice Thrown when an auditor address is the zero address.
    error ZeroAuditor();

    /// @notice Thrown when adding an address that is already an auditor.
    /// @param auditor The duplicate auditor.
    error AlreadyAuditor(address auditor);

    /// @notice Thrown when removing an address that is not an auditor.
    /// @param auditor The unknown auditor.
    error UnknownAuditor(address auditor);

    /// @notice Thrown when a threshold would fall outside [1, auditorCount].
    /// @param threshold The rejected threshold.
    /// @param count The current auditor count.
    error InvalidThreshold(uint8 threshold, uint256 count);

    /// @notice The ordered auditor set.
    address[] private _auditors;

    /// @notice One-based index of each auditor inside _auditors, or 0 when not an auditor.
    mapping(address auditor => uint256 indexPlusOne) private _indexPlusOne;

    /// @notice The number of distinct auditor signatures a result needs.
    uint8 public threshold;

    /// @notice Deploys the registry with an initial auditor set and threshold.
    /// @param owner_ The owner, which in production is the TimelockController.
    /// @param initialAuditors The initial auditor addresses. Must be distinct and non-zero.
    /// @param initialThreshold The initial quorum, in [1, initialAuditors.length].
    constructor(address owner_, address[] memory initialAuditors, uint8 initialThreshold) Ownable(owner_) {
        uint256 length = initialAuditors.length;
        for (uint256 i = 0; i < length; ++i) {
            _addAuditor(initialAuditors[i]);
        }
        if (initialThreshold == 0 || initialThreshold > length) {
            revert InvalidThreshold(initialThreshold, length);
        }
        threshold = initialThreshold;
        emit ThresholdUpdated(initialThreshold);
    }

    /// @notice Whether an address is currently an auditor.
    /// @param account The address to check.
    /// @return True when the address is in the auditor set.
    function isAuditor(address account) external view returns (bool) {
        return _indexPlusOne[account] != 0;
    }

    /// @notice The complete auditor set.
    /// @return The auditor addresses.
    function auditors() external view returns (address[] memory) {
        return _auditors;
    }

    /// @notice The size of the auditor set.
    /// @return The auditor count.
    function auditorCount() external view returns (uint256) {
        return _auditors.length;
    }

    /// @notice Adds an auditor.
    /// @param auditor The address to add.
    function addAuditor(address auditor) external onlyOwner {
        _addAuditor(auditor);
    }

    /// @notice Removes an auditor.
    /// @dev The threshold follows the set down when it would otherwise exceed it, so a removal can
    ///      never leave a quorum larger than the number of auditors able to meet it.
    ///
    ///      Removing the **last** auditor is deliberately still allowed, and lands the registry in
    ///      a halted state: the threshold becomes zero, and `KAY9AuditHub` treats a zero threshold
    ///      as unusable, so no attestation finalises and no watchdog report can be published. That
    ///      is the honest outcome of "every key is compromised, remove them all", and refusing the
    ///      final removal would be worse — it would force the owner to leave one compromised key
    ///      in place, with the threshold dropped to one, which is a key that can sign alone.
    ///
    ///      The state is announced with `QuorumHalted` rather than left to be inferred from a
    ///      `ThresholdUpdated(0)`, and `isHalted` reports it, because `setThreshold` itself refuses
    ///      zero and a reader is entitled to be told that this is a different thing from an
    ///      ordinary threshold change. Recovery is `addAuditor` followed by `setThreshold`; adding
    ///      an auditor deliberately does **not** restore a threshold on its own, since the only
    ///      value it could pick is one, and a single-signature quorum is not something this
    ///      contract should choose on the owner's behalf.
    /// @param auditor The address to remove.
    function removeAuditor(address auditor) external onlyOwner {
        uint256 indexPlusOne = _indexPlusOne[auditor];
        if (indexPlusOne == 0) revert UnknownAuditor(auditor);

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _auditors.length - 1;
        if (index != lastIndex) {
            address moved = _auditors[lastIndex];
            _auditors[index] = moved;
            _indexPlusOne[moved] = index + 1;
        }
        _auditors.pop();
        delete _indexPlusOne[auditor];
        emit AuditorRemoved(auditor);

        uint256 remaining = _auditors.length;
        if (threshold > remaining) {
            threshold = uint8(remaining);
            emit ThresholdUpdated(uint8(remaining));
            // Zero is not an ordinary threshold — `setThreshold` refuses it — so it is announced
            // as what it is rather than left to be read off the line above.
            if (remaining == 0) emit QuorumHalted();
        }
    }

    /// @notice Whether the registry is in the halted state: no auditors, so no quorum can form.
    /// @dev Distinct from "the threshold happens to be low". Nothing can be signed in this state
    ///      and recovery takes `addAuditor` and then `setThreshold`.
    /// @return True when there are no auditors.
    function isHalted() external view returns (bool) {
        return _auditors.length == 0;
    }

    /// @notice Sets the quorum threshold.
    /// @param newThreshold The new threshold, in [1, auditorCount].
    function setThreshold(uint8 newThreshold) external onlyOwner {
        uint256 count = _auditors.length;
        if (newThreshold == 0 || newThreshold > count) revert InvalidThreshold(newThreshold, count);
        threshold = newThreshold;
        emit ThresholdUpdated(newThreshold);
    }

    /// @notice Shared add path used by the constructor and by addAuditor.
    /// @param auditor The address to add.
    function _addAuditor(address auditor) private {
        if (auditor == address(0)) revert ZeroAuditor();
        if (_indexPlusOne[auditor] != 0) revert AlreadyAuditor(auditor);
        _auditors.push(auditor);
        _indexPlusOne[auditor] = _auditors.length;
        emit AuditorAdded(auditor);
    }
}
