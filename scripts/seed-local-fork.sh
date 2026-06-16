#!/usr/bin/env bash
# Seeds a local Anvil-forked HyperEVM with HYPE + USDC for a chosen test
# wallet, then sanity-checks that the seeded LT addresses are on the Bounce
# factory's allowlist.
#
# Prereqs:
#   1. anvil is running, forking HyperEVM, on chain-id 999.
#      Example:
#        anvil \
#          --fork-url https://rpc.hyperliquid.xyz/evm \
#          --chain-id 999 \
#          --port 8545 \
#          --gas-limit 30000000
#
# Usage:
#   ./contracts/scripts/seed-local-fork.sh                     # uses defaults
#   WALLET=0x... USDC_AMOUNT=50000 ./contracts/scripts/seed-local-fork.sh
#
# Env vars (all optional):
#   ANVIL_RPC      RPC URL of the local fork.    Default: http://127.0.0.1:8545
#   WALLET         Address to fund.              Default: anvil account #0
#   USDC_AMOUNT    USDC to mint (whole dollars). Default: 10000
#   HYPE_AMOUNT    HYPE to set (whole HYPE).     Default: 100

set -euo pipefail

ANVIL_RPC="${ANVIL_RPC:-http://127.0.0.1:8545}"
# anvil's account #0 — public key 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# private key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
WALLET="${WALLET:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"
USDC_AMOUNT="${USDC_AMOUNT:-10000}"
HYPE_AMOUNT="${HYPE_AMOUNT:-100}"

USDC="0xb88339CB7199b77E23DB6E890353E22632Ba630f"
BOUNCE_FACTORY="0x65a379FE76C7AdC8037b3522De62B27c0D4e9259"

# ─── Sanity: anvil is up ────────────────────────────────────────────────────
echo "==> Checking anvil at $ANVIL_RPC..."
CHAIN_HEX=$(cast rpc --rpc-url "$ANVIL_RPC" eth_chainId | tr -d '"')
CHAIN_DEC=$((CHAIN_HEX))
if [ "$CHAIN_DEC" -ne 999 ]; then
  echo "✗ anvil's chainId is $CHAIN_DEC, expected 999. Start anvil with --chain-id 999."
  exit 1
fi
echo "    ok, chainId=$CHAIN_DEC"

# ─── HYPE: set native balance ───────────────────────────────────────────────
echo "==> Setting $WALLET HYPE balance to $HYPE_AMOUNT..."
HYPE_BASE=$(cast --to-wei "$HYPE_AMOUNT" ether)
HYPE_HEX=$(cast --to-hex "$HYPE_BASE")
cast rpc --rpc-url "$ANVIL_RPC" anvil_setBalance "$WALLET" "$HYPE_HEX" > /dev/null
BAL_NATIVE=$(cast balance --rpc-url "$ANVIL_RPC" "$WALLET")
echo "    new HYPE balance (wei): $BAL_NATIVE"

# ─── USDC: probe balance storage slot, then write to it ─────────────────────
# Different ERC20 impls put _balances at different storage slots. We try
# 0..15: at each, we tentatively write a marker value to keccak(wallet,
# slot), call balanceOf, and reset. The slot where balanceOf returns the
# marker is the right one.
echo "==> Probing USDC balance storage slot..."
MARKER_HEX="0x0000000000000000000000000000000000000000000000000000000000bc614e"  # 12345678
ZERO_HEX="0x0000000000000000000000000000000000000000000000000000000000000000"
FOUND_SLOT=""
for slot in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  KEY=$(cast keccak \
    "$(cast abi-encode 'f(address,uint256)' "$WALLET" "$slot")")
  cast rpc --rpc-url "$ANVIL_RPC" anvil_setStorageAt "$USDC" "$KEY" "$MARKER_HEX" > /dev/null
  BAL=$(cast call --rpc-url "$ANVIL_RPC" "$USDC" "balanceOf(address)(uint256)" "$WALLET" | awk '{print $1}')
  cast rpc --rpc-url "$ANVIL_RPC" anvil_setStorageAt "$USDC" "$KEY" "$ZERO_HEX" > /dev/null
  if [ "$BAL" = "12345678" ]; then
    FOUND_SLOT="$slot"
    break
  fi
done

if [ -z "$FOUND_SLOT" ]; then
  echo "✗ couldn't find USDC balance slot in 0..15. The contract may use a"
  echo "  non-standard layout (proxy with assembly storage, ERC-7201, etc.)."
  echo "  Inspect with cast storage <addr> <slot> manually."
  exit 1
fi
echo "    found at slot $FOUND_SLOT"

# Write the real balance at the discovered slot.
KEY=$(cast keccak \
  "$(cast abi-encode 'f(address,uint256)' "$WALLET" "$FOUND_SLOT")")
USDC_BASE=$((USDC_AMOUNT * 1000000))
USDC_HEX=$(cast --to-uint256 "$USDC_BASE")
cast rpc --rpc-url "$ANVIL_RPC" anvil_setStorageAt "$USDC" "$KEY" "$USDC_HEX" > /dev/null
BAL=$(cast call --rpc-url "$ANVIL_RPC" "$USDC" "balanceOf(address)(uint256)" "$WALLET")
echo "    new USDC balance: $BAL"

# ─── Sanity: Bounce factory recognises our seeded LTs ───────────────────────
echo "==> Checking Bounce factory allowlist (factory=$BOUNCE_FACTORY)..."
LTS_OUT=$(cast call --rpc-url "$ANVIL_RPC" "$BOUNCE_FACTORY" "lts()(address[])" || echo "")
if [ -z "$LTS_OUT" ]; then
  echo "    ✗ couldn't call lts() — check the factory address and RPC."
else
  LTS_COUNT=$(echo "$LTS_OUT" | tr ',' '\n' | wc -l | tr -d ' ')
  echo "    factory reports $LTS_COUNT registered LT addresses"
  for seeded in \
    "0x18b8539261cF9e760E7fEc4a8a73c50F0AE7baBE" \
    "0x9A51b0DC3545cb8e9b0382b42c91F9e39a92eFD6" \
    "0xBe4e97a8FceeB1b82D64349FbA6Ff29B65Ad3B7d" \
    "0x7B430c5842ce7dBa29b910c018369FA2Fa0ac2e3" \
    "0x6ce8B325252805d2b4b5A6d03eA197d95E0dd582" \
    "0x6019caD7d5A8D4d90eCed36576d23F6198aed156"; do
    LO=$(echo "$seeded" | tr 'A-Z' 'a-z')
    if echo "$LTS_OUT" | tr 'A-Z' 'a-z' | grep -q "$LO"; then
      echo "    ✓ $seeded on allowlist"
    else
      echo "    ✗ $seeded NOT on allowlist — Treasury constructor would revert with NotBounceLT"
    fi
  done
fi

echo
echo "==> Done. Test wallet ready:"
echo "    address     $WALLET"
echo "    private key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
echo "    HYPE        $HYPE_AMOUNT"
echo "    USDC        $USDC_AMOUNT"
