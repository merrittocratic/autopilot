#!/bin/bash
# ============================================================================
# draft-expiry-nudge.sh — Shell wrapper for draft expiry nudge
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$AUTOPILOT_DIR/logs/draft-expiry-nudge.log"

mkdir -p "$AUTOPILOT_DIR/logs"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] draft-expiry-nudge.sh starting" >> "$LOG_FILE"

exec "$AUTOPILOT_DIR/scripts/autopilot-env.sh" \
  /opt/homebrew/bin/Rscript "$SCRIPT_DIR/draft-expiry-nudge.R" "$@" \
  >> "$LOG_FILE" 2>&1
