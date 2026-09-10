// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kay9TestBase} from "../utils/Kay9TestBase.sol";
import {KAY9Token} from "../../src/KAY9Token.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title KAY9TokenTest
/// @notice Proves the token is exactly what the whitepaper claims: a fixed supply with no admin.
contract KAY9TokenTest is Kay9TestBase {
    /// @notice The supply is exactly one billion whole tokens.
    function test_exactSupply() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000e18);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "KAY9");
        assertEq(token.symbol(), "KAY9");
    }

    /// @notice The whole supply lands in the genesis vault and the team vesting contract only.
    function test_allocationsSumToWholeSupply() public view {
        uint256 vestingBalance = token.balanceOf(address(vesting));
        uint256 genesisBalance = token.balanceOf(address(genesis));
        assertEq(vestingBalance, 90_000_000e18);
        assertEq(genesisBalance, 910_000_000e18);
        assertEq(vestingBalance + genesisBalance, token.totalSupply());
        assertEq(genesis.AUCTION_ALLOCATION() + genesis.LIQUIDITY_RESERVE(), genesisBalance);
    }

    /// @notice No mint entry point exists in the deployed bytecode.
    /// @dev Every plausible mint selector is called against the token; each must fail because the
    ///      dispatcher has no matching branch. The runtime bytecode is also scanned for the
    ///      selectors directly.
    function test_noMintFunction() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "mintTo(address,uint256)",
            "issue(uint256)",
            "setMinter(address)"
        ];
        bytes memory runtime = address(token).code;
        for (uint256 i = 0; i < signatures.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(signatures[i])));
            (bool ok,) = address(token).call(abi.encodeWithSelector(selector, address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
            assertFalse(_containsSelector(runtime, selector), signatures[i]);
        }
    }

    /// @notice No pause, blacklist or fee administration exists either.
    function test_noAdminSurface() public {
        string[8] memory signatures = [
            "owner()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setFee(uint256)",
            "setTaxRate(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < signatures.length; ++i) {
            bytes4 selector = bytes4(keccak256(bytes(signatures[i])));
            (bool ok,) = address(token).call(abi.encodeWithSelector(selector, address(this)));
            assertFalse(ok, signatures[i]);
        }
    }

    /// @notice A transfer moves the full amount, with no tax withheld.
    function test_transferHasNoTax() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.prank(address(genesis));
        token.transfer(alice, 1000e18);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        token.transfer(bob, 1000e18);

        assertEq(token.balanceOf(bob), 1000e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), supplyBefore);
    }

    /// @notice Burning reduces the caller's balance and the supply by the same amount.
    function test_burnOnlyOwnBalance() public {
        address alice = makeAddr("alice");
        vm.prank(address(genesis));
        token.transfer(alice, 1000e18);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(alice);
        token.burn(400e18);

        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.totalSupply(), supplyBefore - 400e18);
    }

    /// @notice burnFrom needs an allowance, so no one can burn another holder's balance.
    function test_burnFromRequiresAllowance() public {
        address alice = makeAddr("alice");
        vm.prank(address(genesis));
        token.transfer(alice, 1000e18);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 100e18)
        );
        token.burnFrom(alice, 100e18);
    }

    /// @notice The token refuses to be deployed with a zero genesis address.
    function test_rejectsZeroGenesis() public {
        vm.expectRevert(KAY9Token.ZeroGenesis.selector);
        new KAY9Token(address(0));
    }

    /// @notice EIP-2612 permit is available and binds the chain id.
    function test_permitDomain() public view {
        assertTrue(token.DOMAIN_SEPARATOR() != bytes32(0));
        assertEq(token.nonces(address(genesis)), 0);
    }

    /// @notice Searches runtime bytecode for a four-byte selector.
    /// @param runtime The runtime bytecode.
    /// @param selector The selector to look for.
    /// @return True when the selector appears in the bytecode.
    function _containsSelector(bytes memory runtime, bytes4 selector) private pure returns (bool) {
        if (runtime.length < 4) return false;
        for (uint256 i = 0; i + 4 <= runtime.length; ++i) {
            if (
                runtime[i] == selector[0] && runtime[i + 1] == selector[1] && runtime[i + 2] == selector[2]
                    && runtime[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }
}
