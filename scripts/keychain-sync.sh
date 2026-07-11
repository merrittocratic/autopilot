#!/bin/bash
# ============================================================================
# keychain-sync.sh — Populate macOS Keychain from manual input
# ============================================================================
# Interactive script to add/update autopilot secrets in macOS Keychain.
# Run this once on setup, or whenever you need to rotate a secret.
#
# Usage:
#   ./scripts/keychain-sync.sh              # Interactive — prompts for each
#   ./scripts/keychain-sync.sh KEY VALUE    # Set a single secret
#   ./scripts/keychain-sync.sh --list       # Show which secrets are set
#   ./scripts/keychain-sync.sh --verify     # Test that all secrets are readable
# ============================================================================

set -euo pipefail

KEYCHAIN_SERVICE="autopilot"

SECRETS=(
  ANTHROPIC_API_KEY
  OPENAI_API_KEY
  GEMINI_API_KEY
  X_API_KEY
  X_API_SECRET
  X_ACCESS_TOKEN
  X_ACCESS_SECRET
  X_BEARER_TOKEN
  TELEGRAM_BOT_TOKEN
  TELEGRAM_CHAT_ID
  OPENCLAW_GATEWAY_TOKEN
  CFBD_API_KEY
  GOLF_API_KEY
  GITHUB_TOKEN
  ZERNIO_API_KEY
  ZERNIO_LINKEDIN_ACCOUNT_ID
)

set_secret() {
  local key="$1"
  local value="$2"
  # -A = allow access from any app (avoids GUI authorization dialogs)
  # -U = update if exists
  security add-generic-password -A -U -s "$KEYCHAIN_SERVICE" -a "$key" -w "$value"
  echo "  ✔ $key"
}

check_secret() {
  local key="$1"
  if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$key" -w >/dev/null 2>&1; then
    echo "  ✔ $key — set"
  else
    echo "  ✘ $key — MISSING"
  fi
}

# --- Single-secret mode ---
if [ $# -eq 2 ] && [ "$1" != "--list" ] && [ "$1" != "--verify" ]; then
  set_secret "$1" "$2"
  exit 0
fi

# --- List mode ---
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "--verify" ]; then
  echo "Keychain secrets for service '$KEYCHAIN_SERVICE':"
  echo ""
  MISSING=0
  for SECRET in "${SECRETS[@]}"; do
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$SECRET" -w >/dev/null 2>&1; then
      echo "  ✔ $SECRET"
    else
      echo "  ✘ $SECRET — MISSING"
      MISSING=$((MISSING + 1))
    fi
  done
  echo ""
  if [ $MISSING -eq 0 ]; then
    echo "All ${#SECRETS[@]} secrets are set. ✅"
  else
    echo "$MISSING of ${#SECRETS[@]} secrets missing. ❌"
  fi
  exit 0
fi

# --- Interactive mode ---
echo "============================================"
echo "  Autopilot Keychain Sync"
echo "============================================"
echo ""
echo "This will set secrets in macOS Keychain under"
echo "service: '$KEYCHAIN_SERVICE'"
echo ""
echo "For each secret, paste the value and press Enter."
echo "Press Enter with no value to skip (keep existing)."
echo ""

for SECRET in "${SECRETS[@]}"; do
  # Check if already set
  EXISTING=""
  if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$SECRET" -w >/dev/null 2>&1; then
    EXISTING="[currently set]"
  else
    EXISTING="[not set]"
  fi

  read -r -s -p "$SECRET $EXISTING: " VALUE
  echo ""

  if [ -n "$VALUE" ]; then
    set_secret "$SECRET" "$VALUE"
  else
    echo "  — skipped"
  fi
done

echo ""
echo "Done! Run './scripts/keychain-sync.sh --verify' to confirm."
