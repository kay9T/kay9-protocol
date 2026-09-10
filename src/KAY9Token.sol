// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title KAY9Token
/// @notice The KAY9 ERC20. The entire supply is minted once, in the constructor, to the genesis
///         vault that deploys it. There is no minter, no owner, no pause switch, no blacklist, no
///         transfer fee and no upgrade path; the only way the supply can ever change after
///         deployment is a holder burning their own balance.
/// @dev Deployed by KAY9Genesis so that the genesis vault is guaranteed to be the sole initial
///      holder. The contract deliberately adds nothing to the OpenZeppelin ERC20, ERC20Permit and
///      ERC20Burnable behaviour it inherits.
/// @custom:security-contact security@kay9.io
contract KAY9Token is ERC20, ERC20Permit, ERC20Burnable {
    /// @notice The complete supply of KAY9, minted in full at construction.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// @notice Thrown when the genesis vault address is the zero address.
    error ZeroGenesis();

    /// @notice Deploys the token and mints the whole supply to the genesis vault.
    /// @param genesis The genesis vault that receives all 1,000,000,000 KAY9.
    constructor(address genesis) ERC20("KAY9", "KAY9") ERC20Permit("KAY9") {
        if (genesis == address(0)) revert ZeroGenesis();
        _mint(genesis, TOTAL_SUPPLY);
    }
}
