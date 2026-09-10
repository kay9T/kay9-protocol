# KAY9 protocol

KAY9 is a fixed-supply token, a fair-launch continuous clearing auction with permanently locked
liquidity, and an on-chain audit protocol, on Robinhood Chain (mainnet 4663, testnet 46630). This
repository is the protocol's public surface: the contracts themselves and the specifications that
bind them, kept in sync with what is actually deployed. The website (kay9.io) is a UI over this;
these contracts are the source of truth.

Read [`WHITEPAPER.md`](WHITEPAPER.md) for the public-facing summary — problem, protocol, token,
trust model, current status, roadmap, and known limitations, all in one document.

Nobody pays for an audit. Locking KAY9 unlocks quota in `KAY9AccessVault` and the full amount
returns when the lock ends — no fee, no yield, no escrow of a requester's tokens. See
[`docs/ACCESS_MODEL.md`](docs/ACCESS_MODEL.md) and [`docs/AUDIT_PROTOCOL.md`](docs/AUDIT_PROTOCOL.md).

The binding specification lives in [`ARCHITECTURE.md`](ARCHITECTURE.md) and
[`docs/CONTRACT_INTERFACES.md`](docs/CONTRACT_INTERFACES.md). Per-contract documentation is in
[`docs/CONTRACTS.md`](docs/CONTRACTS.md) and the threat model in [`docs/SECURITY.md`](docs/SECURITY.md).

A handful of docs mentioned by name in these specs — the deployment runbook, launch-readiness
checklist, and internal review/status notes — are operational rather than specificational, and stay
in the main project repository rather than here.

## Layout

```
src/
  KAY9Token.sol              fixed-supply ERC20, no admin
  KAY9TeamVesting.sol        three-tranche calendar vesting, no admin
  KAY9Genesis.sol            launch vault: deploys the token, runs the fair launch, settles
  KAY9LiquidityLock.sol      one-way lock of the LP positions into the Uniswap FeeSplitter
  KAY9AuditorRegistry.sol    operator set and quorum, owned by the timelock
  KAY9Pricing.sol            KAY9/ETH TWAP x Chainlink ETH/USD, owned by the timelock
  KAY9Registry.sol           append-only report log
  KAY9AuditHub.sol           requests, escrow, quorum settlement, refunds
  libraries/                 tick, price, emission-schedule and calendar helpers
  interfaces/uniswap/        vendored Uniswap structs and the calls KAY9 makes
  interfaces/external/       Chainlink AggregatorV3Interface
script/
  Deploy.s.sol               mainnet and generic deployment
  Launch.s.sol               derives LaunchParams and writes the owner Safe calldata
  Testnet.s.sol              testnet rehearsal, deploys the missing launcher stack
  ComputeVesting.s.sol       TGE -> +6 / +12 calendar month timestamps
  config/                    canonical address book per chain
test/
  unit/                      per-contract behaviour and the full launch pipeline
  invariant/                 stateful properties driven by a handler
  fork/                      the same launch against the real mainnet contracts
  utils/                     shared fixture that deploys the real Uniswap stack locally
```

## Requirements

Foundry (this project was built with forge 1.8.1) and Python 3 for the ABI export script. Put
Foundry on the path first, then install the dependencies:

```bash
export PATH="$PATH:$HOME/.foundry/bin"
./setup.sh
```

`setup.sh` installs the third-party libraries, which are not committed because they come to about
260 MB, and relaxes the Permit2 pragma (see the note at the end of this file). The two pinned
Uniswap upstream source trees under `lib/liquidity-launcher` and `lib/continuous-clearing-auction`
**are** committed, because the exact commit matters and `forge install` cannot be relied on to fetch
it.

## Commands

```bash
forge build                                    # compile
forge test -vv                                 # offline suite: unit, fuzz, invariant
FOUNDRY_PROFILE=ci forge test -vv              # heavier fuzz and invariant budgets
forge fmt                                      # format
forge snapshot                                 # write .gas-snapshot
./export-abis.sh ./abis                        # write one JSON per contract (default path assumes the monorepo this was exported from)
slither . --config-file slither.config.json    # static analysis
```

A `Makefile` wraps the same commands (`make test`, `make abis`, `make slither`, and so on) for
anyone who prefers it.

### Fork tests

The fork suite skips itself unless `ROBINHOOD_RPC_URL` is set, so it never blocks a local run.

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path "test/fork/*" -vv
```

The public RPC is rate limited. Pin a block and let Foundry cache it for repeat runs:

```bash
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
ROBINHOOD_FORK_BLOCK=56320000 \
forge test --match-path "test/fork/*" -vv
```

### Scripts

Every script reads its project-specific addresses from the environment. Nothing that identifies the
project is compiled into the contracts or the address book.

```bash
# Calendar unlock timestamps for the deployment report.
TGE_TIMESTAMP=1789000000 forge script script/ComputeVesting.s.sol:ComputeVesting -vvv

# Simulate the mainnet deployment. Add --broadcast to actually send.
OWNER_SAFE=0x... TREASURY=0x... TEAM_BENEFICIARY=0x... CREATOR_FEE_RECIPIENT=0x... \
TGE_TIMESTAMP=... UNLOCK_6M_TIMESTAMP=... UNLOCK_12M_TIMESTAMP=... \
AUDITORS=0xa...,0xb...,0xc... AUDITOR_THRESHOLD=2 \
MAINNET_CONFIRM=I_AM_THE_OWNER \
forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com -vvv

# Derive the launch parameters and write script/output/launch-calldata.json for the Safe.
GENESIS=0x... FLOOR_FDV_USD=1000 GRADUATION_FDV_USD=10000 DURATION_HOURS=4 START_DELAY_MINUTES=30 \
forge script script/Launch.s.sol:Launch --rpc-url https://rpc.mainnet.chain.robinhood.com -vvv

# Testnet rehearsal, which also deploys the launcher stack testnet is missing.
forge script script/Testnet.s.sol:Testnet --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast -vvv
```

## Notes on the dependency set

The tests deploy the genuine Uniswap v4 core and periphery, the genuine liquidity launcher, LBP
strategy and continuous clearing auction, and the genuine Permit2, rather than mocks. The upstream
sources for the launcher and the auction are vendored under `lib/liquidity-launcher` and
`lib/continuous-clearing-auction` from the commits recorded in `docs/RESEARCH.md`, so the salt
derivation, the struct encodings and the migration behaviour under test are the ones that will run
on mainnet. `test/unit/KAY9Launch.t.sol` additionally asserts that the structs KAY9 declares hash
identically to the upstream ones.

Two deliberate deviations from a pristine dependency tree are worth knowing about:

- `lib/permit2/src/*.sol` had its pragma relaxed from `0.8.17` to `^0.8.17` so the whole project can
  compile under the single pinned solc 0.8.26. Permit2 is only compiled from source for the local
  tests; the fork tests and every deployment use the canonical deployed Permit2.
- `via_ir` is enabled. Without it the audit result struct, which carries sixteen members including a
  string, exhausts the stack in the legacy code generator.

`forge coverage` does not run on this toolchain. Coverage turns the optimizer and `via_ir` off,
which reintroduces the stack-too-deep error `via_ir` exists to solve, and `--ir-minimum` trades it
for a Yul stack error inside the vendored upstream sources. Neither is a problem with the KAY9
contracts; both are the well-known Foundry coverage limitation on projects that need `via_ir`. The
test matrix in `docs/SECURITY.md` records what is covered, function by function, in place of a
percentage.
