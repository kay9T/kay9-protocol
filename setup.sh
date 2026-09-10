#!/usr/bin/env bash
#
# Installs the third-party dependencies this project builds against. The two vendored
# upstream source trees, lib/liquidity-launcher and lib/continuous-clearing-auction, are
# committed with the repository and are not touched here.
#
# Run this once after cloning, then `forge build`.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

export PATH="$PATH:$HOME/.foundry/bin"

install() {
  local repo="$1"
  # "OpenZeppelin/openzeppelin-contracts@v5.4.0" installs into lib/openzeppelin-contracts,
  # so the version suffix is stripped from the directory name.
  local spec="${repo##*/}"
  local dir="lib/${spec%%@*}"
  if [[ -d "$dir" && -n "$(ls -A "$dir" 2>/dev/null)" ]]; then
    echo "  $dir already present"
    return
  fi
  echo "  installing $repo"
  # forge fetches the dependency and then deletes its .git directory. That delete fails on
  # some CI runners ("Directory not empty"), after the content has already landed, so the
  # error is tolerated, the metadata is removed here, and the result is verified instead.
  forge install --no-git "$repo" >/dev/null 2>&1 || true
  rm -rf "$dir/.git" >/dev/null 2>&1 || true
  if [[ ! -d "$dir" || -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
    echo "  failed to install $repo into $dir" >&2
    exit 1
  fi
}

echo "installing dependencies..."
install foundry-rs/forge-std
install OpenZeppelin/openzeppelin-contracts@v5.4.0
install Uniswap/v4-core
install Uniswap/v4-periphery
install Uniswap/permit2
install Vectorized/solady
install Uniswap/uerc20-factory
install uniswap/blocknumberish

# Permit2 pins solc 0.8.17 while this project pins 0.8.26. Relaxing the pragma lets the
# whole tree compile under one compiler. Only the local test build compiles Permit2 from
# source; the fork tests and every deployment use the canonical deployed Permit2 at
# 0x000000000022D473030F116dDEE9F6B43aC78BA3.
echo "relaxing the Permit2 pragma..."
for f in lib/permit2/src/AllowanceTransfer.sol \
         lib/permit2/src/EIP712.sol \
         lib/permit2/src/Permit2.sol \
         lib/permit2/src/PermitErrors.sol \
         lib/permit2/src/SignatureTransfer.sol; do
  [[ -f "$f" ]] && sed -i 's|^pragma solidity 0.8.17;$|pragma solidity ^0.8.17;|' "$f"
done

if [[ ! -d lib/liquidity-launcher/src || ! -d lib/continuous-clearing-auction/src ]]; then
  cat >&2 <<'MISSING'

lib/liquidity-launcher/src and lib/continuous-clearing-auction/src are missing.

Those two trees are the pinned Uniswap upstream sources this project compiles against and
they are committed with the repository. If they are absent, restore them from the commits
recorded in docs/RESEARCH.md:

  git clone https://github.com/Uniswap/liquidity-launcher            /tmp/ll
  git clone https://github.com/Uniswap/continuous-clearing-auction   /tmp/cca
  cp -r /tmp/ll/src  lib/liquidity-launcher/
  cp -r /tmp/cca/src lib/continuous-clearing-auction/

MISSING
  exit 1
fi

echo "building..."
forge build >/dev/null
echo "done. run 'forge test -vv'."
