#!/bin/bash
# x-surfacing-log.sh -- wrapper for x-surfacing-log.R
#
# Log-only contract; no secrets required (no Telegram I/O). Earnest
# pipes surfacing JSON to this script after a successful candidate
# send via OpenClaw.

cd ~/autopilot
/opt/homebrew/bin/Rscript openclaw-scripts/x-surfacing-log.R "$@"
