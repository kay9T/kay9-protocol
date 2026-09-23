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

# Every dependency file the compiler reads is committed with the repository (gate-6 review,
# Claude Fable 5.1, F-2), so a checkout builds exactly the reviewed code and install() below finds
# each directory present and skips it. The commit each one came from is pinned here for anyone who
# wants the rest of an upstream tree; a fresh install of these refs is not guaranteed to reproduce
# the committed files byte for byte, and the committed files are what counts.
echo "installing dependencies..."
install foundry-rs/forge-std@bf647bd6046f2f7da30d0c2bf435e5c76a780c1b
install OpenZeppelin/openzeppelin-contracts@c64a1edb67b6e3f4a15cca8909c9482ad33a02b0
install Uniswap/v4-core@46c6834698c48bc4a463a86d8420f4eb1d7f3b75
install Uniswap/v4-periphery@9969eec44cfdf07e24b41de47f40276a58401976
install Uniswap/permit2@cc56ad0f3439c502c246fc5cfcc3db92bb8b7219
install Vectorized/solady@acd959aa4bd04720d640bf4e6a5c71037510cc4b
install Uniswap/uerc20-factory@a747318fcce114f56a3a21b8bcec83663a61208b
install uniswap/blocknumberish@38fe20bc0341d5bc2780d41f90dadb70e10f8cea

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
