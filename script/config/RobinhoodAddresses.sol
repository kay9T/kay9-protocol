// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Every canonical address KAY9 depends on, for one chain.
struct ChainAddresses {
    uint256 chainId;
    address poolManager;
    address positionManager;
    address stateView;
    address quoter;
    address universalRouter;
    address permit2;
    address liquidityLauncher;
    address lbpStrategy;
    address initializerHook;
    address auctionFactory;
    address ccaLens;
    address feeSplitter;
    address beneficiaryVault;
    address compoundingClaimRecipient;
    address ethUsdFeed;
    address weth;
    address multicall3;
    address create2Deployer;
}

/// @title RobinhoodAddresses
/// @notice The verified on-chain addresses of everything KAY9 integrates with, per network.
/// @dev Verified 2026-09-07 against live RPC reads; see docs/RESEARCH.md for the commands. Nothing
///      that identifies the project itself lives here: the owner Safe, the treasury, the team
///      beneficiary and the creator-fee recipient are read from the environment by the scripts and
///      are never hard-coded.
library RobinhoodAddresses {
    /// @notice Robinhood Chain mainnet.
    uint256 internal constant MAINNET_CHAIN_ID = 4663;

    /// @notice Robinhood Chain testnet.
    uint256 internal constant TESTNET_CHAIN_ID = 46_630;

    /// @notice Thrown when the script runs on a chain that has no address book entry.
    /// @param chainId The unsupported chain.
    error UnsupportedChain(uint256 chainId);

    /// @notice The mainnet address book.
    /// @return a The addresses.
    function mainnet() internal pure returns (ChainAddresses memory a) {
        a = ChainAddresses({
            chainId: MAINNET_CHAIN_ID,
            poolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951,
            positionManager: 0x58daec3116aae6D93017bAAea7749052E8a04fA7,
            stateView: 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b,
            quoter: 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94,
            universalRouter: 0x8876789976dEcBfCbBbe364623C63652db8C0904,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            liquidityLauncher: 0x0000FffFBE8efE702c8703aE3477FF5dE3d319C0,
            lbpStrategy: 0x05d552391067389EE44fec3924157ed33F976000,
            initializerHook: 0xD462a559337859369EF271814851A18F496ba000,
            auctionFactory: 0x000000001F26a0044BaA66024e7b6599c61963F8,
            ccaLens: 0xc3C65F5453A3674aDb693cbdA3C842545cD30f53,
            feeSplitter: 0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf,
            beneficiaryVault: 0xd35E9CA72F64C7F93BE30fad67524323396B36D7,
            compoundingClaimRecipient: 0xf9526Dd3361fe0ba6b7a99533ed471D3E808E99a,
            ethUsdFeed: 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9,
            weth: 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73,
            multicall3: 0xcA11bde05977b3631167028862bE2a173976CA11,
            create2Deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }

    /// @notice The testnet address book.
    /// @dev The liquidity launcher, the LBP strategy, the initializer hook, the fee splitter, the
    ///      beneficiary vault and the Chainlink feed do not exist on testnet; the rehearsal script
    ///      deploys stand-ins and fills these in at runtime.
    /// @return a The addresses.
    function testnet() internal pure returns (ChainAddresses memory a) {
        a = ChainAddresses({
            chainId: TESTNET_CHAIN_ID,
            poolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951,
            positionManager: 0x58daec3116aae6D93017bAAea7749052E8a04fA7,
            stateView: address(0),
            quoter: address(0),
            universalRouter: address(0),
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            liquidityLauncher: address(0),
            lbpStrategy: address(0),
            initializerHook: address(0),
            auctionFactory: 0x000000001F26a0044BaA66024e7b6599c61963F8,
            ccaLens: address(0),
            feeSplitter: address(0),
            beneficiaryVault: address(0),
            compoundingClaimRecipient: address(0),
            ethUsdFeed: address(0),
            weth: address(0),
            multicall3: 0xcA11bde05977b3631167028862bE2a173976CA11,
            create2Deployer: 0x4e59b44847b379578588920cA78FbF26c0B4956C
        });
    }

    /// @notice The address book for a chain id.
    /// @param chainId The chain to look up.
    /// @return The addresses.
    function forChain(uint256 chainId) internal pure returns (ChainAddresses memory) {
        if (chainId == MAINNET_CHAIN_ID) return mainnet();
        if (chainId == TESTNET_CHAIN_ID) return testnet();
        revert UnsupportedChain(chainId);
    }
}
