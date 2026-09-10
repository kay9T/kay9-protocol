# KAY9 contracts
#
# Every target assumes Foundry is on PATH:
#   export PATH="$PATH:$HOME/.foundry/bin"
#
# The fork targets need ROBINHOOD_RPC_URL. Everything else runs offline.

.PHONY: help build test test-fork test-ci coverage snapshot fmt fmt-check lint slither abis clean \
        deploy-dry deploy-testnet launch-preview vesting

RPC_MAINNET ?= https://rpc.mainnet.chain.robinhood.com
RPC_TESTNET ?= https://rpc.testnet.chain.robinhood.com
VERIFIER_URL ?= https://robinhoodchain.blockscout.com/api/

help:
	@echo "build           compile everything"
	@echo "test            run the offline suite (unit, fuzz, invariant)"
	@echo "test-fork       run the Robinhood mainnet fork suite"
	@echo "test-ci         run the suite with the heavier ci fuzz profile"
	@echo "coverage        summary coverage report (currently blocked, see README)"
	@echo "snapshot        write .gas-snapshot"
	@echo "fmt / fmt-check format sources"
	@echo "slither         static analysis"
	@echo "abis            export ABIs into the chain workspace, or ./abis when standalone"
	@echo "deploy-dry      simulate the mainnet deployment without broadcasting"
	@echo "deploy-testnet  broadcast the testnet rehearsal"
	@echo "launch-preview  derive and print the launch parameters"
	@echo "vesting         print the calendar vesting schedule"

build:
	forge build

test:
	forge test -vv

test-fork:
	ROBINHOOD_RPC_URL=$(RPC_MAINNET) forge test --match-path "test/fork/*" -vv

test-ci:
	FOUNDRY_PROFILE=ci forge test -vv

# Coverage does not run on this toolchain: it disables via_ir, which this project needs.
# See the note at the end of README.md.
coverage:
	forge coverage --ir-minimum --report summary

snapshot:
	forge snapshot

fmt:
	forge fmt

fmt-check:
	forge fmt --check

lint:
	forge lint

slither:
	slither . --config-file slither.config.json

abis:
	./export-abis.sh

clean:
	forge clean

# Simulates the mainnet deployment. Requires OWNER_SAFE, TREASURY, TEAM_BENEFICIARY,
# CREATOR_FEE_RECIPIENT, TGE_TIMESTAMP, UNLOCK_6M_TIMESTAMP, UNLOCK_12M_TIMESTAMP,
# AUDITORS, AUDITOR_THRESHOLD and MAINNET_CONFIRM=I_AM_THE_OWNER. Add --broadcast by hand
# when the simulation has been reviewed and the deployment is really going out.
deploy-dry:
	forge script script/Deploy.s.sol:Deploy --rpc-url $(RPC_MAINNET) -vvv

deploy-testnet:
	forge script script/Testnet.s.sol:Testnet --rpc-url $(RPC_TESTNET) --broadcast -vvv

launch-preview:
	forge script script/Launch.s.sol:Launch --rpc-url $(RPC_MAINNET) -vvv

vesting:
	forge script script/ComputeVesting.s.sol:ComputeVesting -vvv
