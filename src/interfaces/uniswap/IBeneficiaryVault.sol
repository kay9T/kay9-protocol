// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IBeneficiaryVault
/// @notice A transferable ERC721 claim on a Uniswap v4 position's attributed LP fees.
/// @dev Mirrors `Uniswap/liquidity-launcher` IBeneficiaryVault as implemented by the
///      UERC20BeneficiaryVault at 0xd35E9CA72F64C7F93BE30fad67524323396B36D7.
interface IBeneficiaryVault {
    /// @notice Assigns `beneficiary` the fee stream of `tokenId` and mints the beneficiary NFT.
    /// @dev The caller must own the position in the PositionManager, so registration has to happen
    ///      before the position is handed to a terminal custodian such as the FeeSplitter.
    /// @param tokenId The position whose fee stream is assigned.
    /// @param beneficiary The receiver of the beneficiary NFT.
    function registerBeneficiary(uint256 tokenId, address beneficiary) external;

    /// @notice The receiver of unregistered positions' native fee shares.
    /// @return The native fallback address.
    function nativeFallback() external view returns (address);

    /// @notice The receiver of unregistered positions' token fee shares.
    /// @return The token fallback address.
    function tokenFallback() external view returns (address);

    /// @notice The owner of the beneficiary NFT of `tokenId`.
    /// @param tokenId The position id, which is also the beneficiary NFT id.
    /// @return The beneficiary NFT owner.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Pulls the caller's accrued fee shares for a position.
    /// @param tokenId The position to claim for.
    function claim(uint256 tokenId) external;
}
