#!/bin/bash
set -euo pipefail

ROOT="$HOME/autopilot"
cd "$ROOT"

exec "$ROOT/scripts/autopilot-env.sh" \
  /opt/homebrew/bin/Rscript "$ROOT/openclaw-scripts/x-fact-check.R" "$@"
