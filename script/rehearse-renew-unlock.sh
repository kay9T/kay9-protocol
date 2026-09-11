#!/usr/bin/env bash
# The last two steps of the testnet rehearsal (docs/DEPLOYMENT.md section 3.1, steps 6 and 7),
# which cannot run on the day the period is opened: KAY9AccessVault.MIN_LOCK_DURATION is seven
# days and the rehearsal period was opened with exactly that. Run this at or after the period's
# expiresAt (2026-09-18 for the 2026-09-11 rehearsal; `access()` prints it).
#
# Needs the same environment the other stages used: PRIVATE_KEY (throwaway testnet deployer),
# ROBINHOOD_TESTNET_RPC_URL, PK_USER (throwaway depositor), and the addresses in the rehearsal env
# (GENESIS, PRICING, VAULT, HUB, REGISTRY, TIMELOCK, FEED). Testnet only; nothing here holds value.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PATH:$HOME/.foundry/bin"
RPC="${ROBINHOOD_TESTNET_RPC_URL:?}"
run() { local sig="$1"; shift; echo "=== $(date -u +%FT%TZ) $sig"; env "$@" forge script script/Rehearse.s.sol:Rehearse --sig "$sig" --rpc-url "$RPC" --broadcast 2>&1 | grep -E "^\s+[a-zA-Z/ ()]+ +[0-9a-zA-Z-]|SUCCESSFUL|Error|revert|Revert" | grep -vE "Estimated|Chain 46630|Setting up"; }

run "access()"
# The oracle has been idle for a week, so the window is uncovered: renew must refuse with
# PricingUnavailable until the keeper has refilled it, and that refusal is the correct answer.
echo "=== renew while the oracle is cold (expect PricingUnavailable)"
forge script script/Rehearse.s.sol:Rehearse --sig "renew()" --rpc-url "$RPC" 2>&1 | grep -E "PricingUnavailable|Error|revert" | head -3 || true
# Refill the window: a fresh feed answer and pokes spanning more than thirty minutes.
run "feed()" FEED_ANSWER_E8="${FEED_ANSWER_E8:-250000000000000000}"
for i in $(seq 1 36); do
  forge script script/Rehearse.s.sol:Rehearse --sig "poke()" --rpc-url "$RPC" --broadcast >/dev/null 2>&1 || echo "poke $i failed"
  sleep 55
done
run "poke()"
# Renewal settles the difference against the fresh quote and resets the allowance.
run "renew()"
# Unlock needs a period that has ended, so this is a second period: read expiresAt, then either
# come back after it or, on a fresh rehearsal, set the period to its minimum beforehand.
run "access()"
echo "unlock() runs at or after the expiresAt printed above: forge script script/Rehearse.s.sol:Rehearse --sig 'unlock()' --rpc-url \$RPC --broadcast"
