#!/bin/bash
# ============================================================================
# keychain-refresh.sh — Refresh .autopilot.env from Keychain
# ============================================================================
# Run periodically (every 4h via launchd) to keep the fallback env file
# in sync with the Keychain. Only runs if Keychain is accessible.
# ============================================================================

set -euo pipefail

ENV_FILE="$HOME/.autopilot.env"
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
  OPENCLAW_GATEWAY_TOKEN
  CFBD_API_KEY
  GITHUB_TOKEN
)

# Test keychain is accessible
if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "ANTHROPIC_API_KEY" -w >/dev/null 2>&1; then
  echo "[keychain-refresh] Keychain locked or unavailable — skipping refresh"
  exit 0
fi

TMPFILE=$(mktemp)
chmod 600 "$TMPFILE"

for key in "${SECRETS[@]}"; do
  val=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$key" -w 2>/dev/null || echo "")
  if [ -n "$val" ]; then
    echo "export $key=\"$val\"" >> "$TMPFILE"
  fi
done

mv "$TMPFILE" "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "[keychain-refresh] Refreshed $ENV_FILE at $(date)"
