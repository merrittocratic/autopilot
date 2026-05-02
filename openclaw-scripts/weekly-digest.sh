#!/bin/bash
# ============================================================================
# weekly-digest.sh — Shell wrapper for weekly X performance digest
# ============================================================================
# Designed to be called by cron. Loads secrets via autopilot-env.sh.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="$AUTOPILOT_DIR/logs/weekly-digest.log"

mkdir -p "$AUTOPILOT_DIR/logs"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] weekly-digest.sh starting" >> "$LOG_FILE"

exec "$AUTOPILOT_DIR/scripts/autopilot-env.sh" \
  /opt/homebrew/bin/Rscript "$SCRIPT_DIR/weekly-digest.R" "$@" \
  >> "$LOG_FILE" 2>&1
