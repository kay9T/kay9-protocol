#!/usr/bin/env bash
# The last two steps of the testnet rehearsal (docs/DEPLOYMENT.md section 3.1, steps 6 and 7),
# which cannot run on the day the period is opened: KAY9AccessVault.MIN_LOCK_DURATION is seven
# days and the rehearsal period was opened with exactly that. Run this at or after the period's
# expiresAt (`access()` prints it).
#
# Needs the same environment the other stages used: PRIVATE_KEY (throwaway testnet deployer),
# ROBINHOOD_TESTNET_RPC_URL, PK_USER (throwaway depositor), and the addresses in the rehearsal env
# (GENESIS, VAULT, HUB, REGISTRY, TIMELOCK). Testnet only; nothing here holds value.
#
# This script used to warm an oracle between the two steps: it expected `renew` to revert with
# `PricingUnavailable` while the price window was cold, then called `feed()` and thirty-six
# `poke()`s to refill it. KAY9Pricing and the keeper were deleted on 2026-09-11 — a lock is a
# fixed amount of KAY9 per tier, set through the timelock, and nothing in the access path reads a
# price — so those three entry points no longer exist in Rehearse.s.sol and the script could not
# have completed a rehearsal. What is left is what the contracts actually do.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"
RPC="${ROBINHOOD_TESTNET_RPC_URL:?}"
run() { local sig="$1"; shift; echo "=== $(date -u +%FT%TZ) $sig"; env "$@" forge script script/Rehearse.s.sol:Rehearse --sig "$sig" --rpc-url "$RPC" --broadcast 2>&1 | grep -E "^\s+[a-zA-Z/ ()]+ +[0-9a-zA-Z-]|SUCCESSFUL|Error|revert|Revert" | grep -vE "Estimated|Chain 46630|Setting up"; }

run "access()"
# Renewal reopens the period at the tier's current requirement. A requirement changed by the owner
# in the meantime applies from here on; what the live period locked with is untouched until then,
# and `balance delta (signed)` is the difference being settled either way.
run "renew()"
# Unlock needs a period that has ended, so this is a second period: read expiresAt, then either
# come back after it or, on a fresh rehearsal, set the period to its minimum beforehand.
run "access()"
echo "unlock() runs at or after the expiresAt printed above: forge script script/Rehearse.s.sol:Rehearse --sig 'unlock()' --rpc-url \$RPC --broadcast"
echo "it must return exactly what the period locked with — the whole principal, reading no oracle."
