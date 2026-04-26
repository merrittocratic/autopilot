#!/bin/bash
# X Timeline Monitor — Scan curated follow list for reply opportunities
# Returns JSON array of candidate tweets matched against our content
# Called by Earnest during heartbeat or on-demand

cd ~/autopilot
scripts/autopilot-env.sh /opt/homebrew/bin/Rscript /Users/merrittocracyclaw/.openclaw/workspace/scripts/x-monitor.R "$@"
