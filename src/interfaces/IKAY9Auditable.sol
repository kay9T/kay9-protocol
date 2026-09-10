// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IKAY9Auditable
/// @notice An optional interface a token may implement so that an automated audit can read what
///         its bytecode alone cannot tell anyone.
///
/// @dev **Implementing this proves nothing and buys nothing.** It is not a certification, it does
///      not improve a score, and KAY9 will not treat a token that implements it more favourably
///      than one that does not. Anybody can deploy a contract that returns whatever they like from
///      these functions, so nothing here is trusted: every value is checked against the chain, and
///      a claim that disagrees with what the chain shows is worse for the token than silence would
///      have been. That is the whole point — the interface gives an honest project a way to be
///      *checked*, not a way to be believed.
///
///      What it is genuinely useful for is the gap between "this contract can do X" and "this
///      contract will do X". An audit can see that a token is upgradeable; it cannot see that the
///      proxy admin is a 48-hour timelock behind a 3-of-5 Safe, because that is two contracts away
///      and looks like an ordinary address. It can see that a wallet holds 40 per cent of supply;
///      it cannot see that the wallet is a vesting contract. Answering those questions turns an
///      unmeasured signal into a measured one, which usually means a *lower* uncertainty rather
///      than a lower risk score.
///
///      Every function is `view` and every one must be safe to call from a static context. A
///      reverting or gas-hungry implementation is treated as no implementation at all.
/// @custom:security-contact security@kay9.io
interface IKAY9Auditable {
    /// @notice The address that controls this token today, or the zero address for none.
    /// @dev The audit reads `owner()`, `admin()` and the EIP-1967 slots itself. This exists for the
    ///      case those disagree or none of them applies: a token governed by a contract that is not
    ///      the ERC-173 owner, for instance. If this disagrees with what the chain shows, the chain
    ///      wins and the disagreement is itself reported.
    /// @return controller The controlling address, or address(0) if the token is ungoverned.
    function kay9Controller() external view returns (address controller);

    /// @notice Addresses that hold supply for a stated reason, so they are not read as whales.
    /// @dev A vesting contract, a treasury, a locked LP position or a bridge escrow all look
    ///      identical to a large holder from outside. Each entry is verified — the audit checks
    ///      that the address holds what it claims and, where it can, that the contract at that
    ///      address does what the label says — and an entry that does not check out is reported as
    ///      a false claim rather than quietly dropped.
    ///
    ///      Labels are free text and deliberately not an enum: a new kind of holder should not need
    ///      a new version of this interface. Keep them short and literal — "team vesting",
    ///      "locked liquidity", "bridge escrow".
    /// @return holders The addresses.
    /// @return labels What each one is, in the same order.
    function kay9ExcludedHolders() external view returns (address[] memory holders, string[] memory labels);

    /// @notice Where the token's own documentation lives.
    /// @dev Content-addressed is strongly preferred — `ipfs://` or `ar://` — because a URL whose
    ///      contents can change after an audit is a claim that can be edited after it is checked.
    ///      An `https://` URI is accepted and recorded as mutable.
    /// @return uri The document location, or an empty string.
    function kay9DocumentURI() external view returns (string memory uri);

    /// @notice The timelock delay, in seconds, that governs privileged calls on this token.
    /// @dev Zero means either no delay or no such mechanism, and the two are not distinguished
    ///      here: a claim of zero is treated the same as not implementing the function. A non-zero
    ///      value is checked against the controller contract where that contract is recognisable,
    ///      and a delay this function claims but the controller does not enforce is reported.
    /// @return seconds_ The delay in seconds.
    function kay9TimelockDelay() external view returns (uint64 seconds_);
}
