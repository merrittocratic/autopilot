#!/bin/bash
# Morning Sports Digest — Wrapper script
# Cron: 0 10 * * * (6:00am ET = 10:00am UTC during EDT)
# Fetches previous day's ESPN/FoxSports tweets, synthesizes digest, sends to Telegram

LOG_FILE="$HOME/.openclaw/workspace/logs/morning-sports-digest.log"
mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date '+%Y-%m-%d %H:%M:%S') — Starting morning sports digest" >> "$LOG_FILE"

cd ~/autopilot || exit 1

scripts/autopilot-env.sh /opt/homebrew/bin/Rscript \
  /Users/merrittocracyclaw/autopilot/openclaw-scripts/morning-sports-digest.R \
  "$@" >> "$LOG_FILE" 2>&1

EXIT_CODE=$?
echo "$(date '+%Y-%m-%d %H:%M:%S') — Done (exit $EXIT_CODE)" >> "$LOG_FILE"
exit $EXIT_CODE
