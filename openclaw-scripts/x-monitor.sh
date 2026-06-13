#!/bin/bash
# X Timeline Monitor — Scan curated follow list for reply opportunities
# Returns JSON array of candidate tweets matched against our content.
# Called by an OpenClaw cron job on the Mac Mini.
#
# 2026-06-13 — Now invokes the autopilot canonical R script directly
# (single source of truth; deprecates ~/.openclaw/workspace/scripts/).

cd ~/autopilot
scripts/autopilot-env.sh /opt/homebrew/bin/Rscript openclaw-scripts/x-monitor.R "$@"
