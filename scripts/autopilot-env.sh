#!/bin/bash
# ============================================================================
# autopilot-env.sh — Keychain-based secret injection for launchd
# ============================================================================
# Reads secrets from the macOS Keychain (service: "autopilot") and exports
# them as environment variables, then exec's the given command.
#
# Usage (from launchd plist):
#   /Users/merrittocracyclaw/autopilot/scripts/autopilot-env.sh \
#       /opt/homebrew/bin/Rscript run_distribution.R --check
#
# Each secret is stored in Keychain as:
#   service = "autopilot"
#   account = <ENV_VAR_NAME>   (e.g. ANTHROPIC_API_KEY)
#
# To add/update a secret:
#   security add-generic-password -U -s autopilot -a ANTHROPIC_API_KEY -w "sk-..."
#
# To read a secret (test):
#   security find-generic-password -s autopilot -a ANTHROPIC_API_KEY -w
# ============================================================================

set -euo pipefail

KEYCHAIN_SERVICE="autopilot"

# List of environment variables to load from Keychain
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

# Non-secret env vars (not in Keychain)
export REVIEW_SHEET_ID="1-AP273mLlwwmf2sWSE32a7D6ZQzT2J2zwjPdVTnCjSw"
export R_LIBS_USER="/opt/homebrew/lib/R/4.5/site-library"

# Read each secret from Keychain and export
FAILED=()
for SECRET in "${SECRETS[@]}"; do
  VALUE=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$SECRET" -w 2>/dev/null) || true
  if [ -z "$VALUE" ]; then
    FAILED+=("$SECRET")
  else
    export "$SECRET"="$VALUE"
  fi
done

# Report any missing secrets to stderr (shows up in launchd logs)
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[autopilot-env] WARNING: Missing Keychain secrets: ${FAILED[*]}" >&2
fi

# Hand off to the actual command
exec "$@"
