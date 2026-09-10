#!/usr/bin/env bash
#
# Writes the ABI of every contract the website and the services need into
# packages/chain/abis, one JSON file per contract, plus an index.json listing them.
#
# Each entry names its source file explicitly rather than relying on the artifact
# layout, because several interface names exist both in this project and in the
# vendored upstream sources and the artifact directory keys on the file basename
# alone. The KAY9 contracts and the KAY9-vendored Uniswap interfaces come from src;
# IPoolManager, IPositionManager and TimelockController come from the upstream
# packages so their shapes are exactly the deployed ones.
#
# Usage:  ./export-abis.sh  [output directory]
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The public protocol repository has no sibling chain workspace.
DEFAULT_OUT_DIR="$HERE/abis"
if [[ -f "$HERE/../chain/package.json" ]]; then
  DEFAULT_OUT_DIR="$HERE/../chain/abis"
fi
OUT_DIR="${1:-$DEFAULT_OUT_DIR}"

export PATH="$PATH:$HOME/.foundry/bin"

cd "$HERE"

echo "building..."
forge build >/dev/null

mkdir -p "$OUT_DIR"

TARGETS=(
  "src/KAY9Token.sol:KAY9Token"
  "src/KAY9TeamVesting.sol:KAY9TeamVesting"
  "src/KAY9Genesis.sol:KAY9Genesis"
  "src/KAY9LiquidityLock.sol:KAY9LiquidityLock"
  "src/KAY9AuditorRegistry.sol:KAY9AuditorRegistry"
  "src/KAY9Pricing.sol:KAY9Pricing"
  "src/KAY9Registry.sol:KAY9Registry"
  "src/KAY9AuditHub.sol:KAY9AuditHub"
  "src/KAY9AccessVault.sol:KAY9AccessVault"
  "src/KAY9ScanRegistry.sol:KAY9ScanRegistry"
  "src/interfaces/uniswap/IContinuousClearingAuction.sol:IContinuousClearingAuction"
  "src/interfaces/uniswap/ILBPStrategy.sol:ILBPStrategy"
  "src/interfaces/uniswap/ILBPInitializer.sol:ILBPInitializer"
  "src/interfaces/uniswap/ILiquidityLauncher.sol:ILiquidityLauncher"
  "src/interfaces/uniswap/IDistributorFactory.sol:IDistributorFactory"
  "src/interfaces/uniswap/IFeeSplitter.sol:IFeeSplitter"
  "src/interfaces/uniswap/IBeneficiaryVault.sol:IBeneficiaryVault"
  "src/interfaces/uniswap/IInitializerHook.sol:IInitializerHook"
  "src/interfaces/uniswap/IStateView.sol:IStateView"
  "src/interfaces/external/AggregatorV3Interface.sol:AggregatorV3Interface"
  "lib/v4-periphery/src/interfaces/IPositionManager.sol:IPositionManager"
  "lib/v4-core/src/interfaces/IPoolManager.sol:IPoolManager"
  "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol:TimelockController"
)

written=0
for target in "${TARGETS[@]}"; do
  name="${target##*:}"
  forge inspect "$target" abi --json > "$OUT_DIR/$name.json"
  written=$((written + 1))
  echo "  $name"
done

python -c "
import json, os, sys
out = sys.argv[1]
names = sorted(f[:-5] for f in os.listdir(out) if f.endswith('.json') and f != 'index.json')
with open(os.path.join(out, 'index.json'), 'w', encoding='utf-8') as f:
    json.dump(names, f, indent=2)
    f.write('\n')
" "$OUT_DIR"

echo "wrote $written ABIs to $OUT_DIR"
