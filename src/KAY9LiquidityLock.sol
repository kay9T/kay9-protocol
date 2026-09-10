// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IBeneficiaryVault} from "./interfaces/uniswap/IBeneficiaryVault.sol";

/// @title KAY9LiquidityLock
/// @notice The one-way door the KAY9 liquidity positions pass through. The lock receives the LP
///         NFTs minted at migration and at settlement, registers the project creator-fee address as
///         the beneficiary of each position while it still owns it, and then hands the NFT to the
///         Uniswap FeeSplitter, where nothing can ever withdraw it again.
/// @dev The contract has no owner and exposes no transfer path other than lock, whose destination
///      is the immutable FeeSplitter address. Registering the beneficiary has to happen before the
///      transfer because UERC20BeneficiaryVault only accepts a registration from the position's
///      current PositionManager owner.
/// @custom:security-contact security@kay9.io
contract KAY9LiquidityLock is IERC721Receiver {
    /// @notice Emitted once per position, when it has been registered and handed to the splitter.
    /// @param tokenId The position that was locked.
    /// @param beneficiary The creator-fee recipient registered against it.
    /// @param feeSplitter The terminal custodian the position was transferred to.
    event PositionLocked(uint256 indexed tokenId, address indexed beneficiary, address feeSplitter);

    /// @notice Emitted when the lock takes custody of a position.
    /// @param tokenId The received position.
    event PositionReceived(uint256 indexed tokenId);

    /// @notice Thrown when a constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the creator-fee recipient is an address the vault refuses to register.
    error InvalidCreatorFeeRecipient();

    /// @notice Thrown when an ERC721 other than a canonical v4 position is sent to the lock.
    /// @param sender The rejected caller of onERC721Received.
    error NotPositionManager(address sender);

    /// @notice Thrown when lock is called for a position the lock does not own.
    /// @param tokenId The position in question.
    error NotOwned(uint256 tokenId);

    /// @notice Thrown when lock is called twice for the same position.
    /// @param tokenId The position in question.
    error AlreadyLocked(uint256 tokenId);

    /// @notice The canonical Uniswap v4 PositionManager that mints the LP NFTs.
    IPositionManager public immutable positionManager;

    /// @notice The terminal fee custodian. Positions transferred here can never be withdrawn.
    address public immutable feeSplitter;

    /// @notice The vault that mints the transferable beneficiary NFT for each position.
    IBeneficiaryVault public immutable beneficiaryVault;

    /// @notice The address that receives the beneficiary NFT, and therefore the creator fee share.
    address public immutable creatorFeeRecipient;

    /// @notice Every position id the lock has ever taken custody of, in arrival order.
    uint256[] public lockedTokenIds;

    /// @notice Whether a position has already been handed to the fee splitter.
    mapping(uint256 tokenId => bool) private _locked;

    /// @notice Whether a position id is already present in lockedTokenIds.
    mapping(uint256 tokenId => bool) private _tracked;

    /// @notice Deploys the lock.
    /// @param positionManager_ The canonical v4 PositionManager.
    /// @param feeSplitter_ The FeeSplitter that permanently custodies the positions.
    /// @param beneficiaryVault_ The vault that mints beneficiary NFTs.
    /// @param creatorFeeRecipient_ The address that receives the beneficiary NFTs.
    constructor(
        IPositionManager positionManager_,
        address feeSplitter_,
        IBeneficiaryVault beneficiaryVault_,
        address creatorFeeRecipient_
    ) {
        if (
            address(positionManager_) == address(0) || feeSplitter_ == address(0)
                || address(beneficiaryVault_) == address(0) || creatorFeeRecipient_ == address(0)
        ) revert ZeroAddress();
        // The vault rejects itself as a beneficiary. A lock deployed with that recipient would
        // revert inside every lock() call, which would in turn brick settle() and recover().
        if (creatorFeeRecipient_ == address(beneficiaryVault_)) revert InvalidCreatorFeeRecipient();
        positionManager = positionManager_;
        feeSplitter = feeSplitter_;
        beneficiaryVault = beneficiaryVault_;
        creatorFeeRecipient = creatorFeeRecipient_;
    }

    /// @notice Accepts a Uniswap v4 position and records its id.
    /// @dev Only the canonical PositionManager may send NFTs here. The canonical PositionManager
    ///      mints with a plain _mint and therefore does not call this hook at mint time, so
    ///      positions minted straight to the lock are picked up by the sweep in lockAll instead.
    /// @param tokenId The received position.
    /// @return The ERC721 receiver magic value.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(positionManager)) revert NotPositionManager(msg.sender);
        _track(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice The number of position ids the lock knows about.
    /// @return The tracked position count.
    function lockedCount() external view returns (uint256) {
        return lockedTokenIds.length;
    }

    /// @notice Whether a position has already been handed to the fee splitter.
    /// @param tokenId The position to check.
    /// @return True once the position has left for the splitter.
    function isLocked(uint256 tokenId) external view returns (bool) {
        return _locked[tokenId];
    }

    /// @notice Registers the creator-fee recipient as beneficiary and hands the position to the
    ///         fee splitter. Permissionless: the destination is fixed at deployment.
    /// @dev Registration is skipped when the vault has already minted a beneficiary NFT for this
    ///      position, which can only happen if someone front-ran the registration; the fee stream
    ///      is then already attributed and the transfer proceeds regardless. The registration is
    ///      not wrapped in a try/catch for any other failure, because a vault that refuses the
    ///      registration must stop the lock rather than silently forfeit the fee stream to the
    ///      vault's fallback address.
    /// @param tokenId The position to lock.
    function lock(uint256 tokenId) public {
        if (_locked[tokenId]) revert AlreadyLocked(tokenId);
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);

        _track(tokenId);
        _locked[tokenId] = true;

        if (_beneficiaryOf(tokenId) == address(0)) {
            beneficiaryVault.registerBeneficiary(tokenId, creatorFeeRecipient);
        }

        emit PositionLocked(tokenId, creatorFeeRecipient, feeSplitter);

        IERC721(address(positionManager)).safeTransferFrom(address(this), feeSplitter, tokenId);
    }

    /// @notice Locks every tracked position the lock currently owns.
    /// @dev Tracked ids the lock no longer owns, and ids already locked, are skipped so a single
    ///      stuck position cannot block the rest.
    function lockAll() external {
        uint256 length = lockedTokenIds.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 tokenId = lockedTokenIds[i];
            if (_locked[tokenId]) continue;
            if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) continue;
            lock(tokenId);
        }
    }

    /// @notice Records a position id the lock owns but has not seen through onERC721Received.
    /// @dev The canonical PositionManager mints without a receiver callback, so a position minted
    ///      directly to the lock has to be announced before lockAll can pick it up. Anyone may
    ///      call this; it only ever adds ids the lock genuinely owns.
    /// @param tokenId The position to start tracking.
    function track(uint256 tokenId) external {
        if (IERC721(address(positionManager)).ownerOf(tokenId) != address(this)) revert NotOwned(tokenId);
        _track(tokenId);
    }

    /// @notice The beneficiary NFT holder for a position, or the zero address if unregistered.
    /// @param tokenId The position to look up.
    /// @return The beneficiary, or the zero address.
    function _beneficiaryOf(uint256 tokenId) private view returns (address) {
        try beneficiaryVault.ownerOf(tokenId) returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    /// @notice Adds a position id to the tracked list exactly once.
    /// @param tokenId The position to track.
    function _track(uint256 tokenId) private {
        if (_tracked[tokenId]) return;
        _tracked[tokenId] = true;
        lockedTokenIds.push(tokenId);
        emit PositionReceived(tokenId);
    }
}
