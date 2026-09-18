#!/bin/bash
# feature-store-refresh.sh -- wrapper for feature-store-refresh.R
#
# Daily content-feature pull (NFL/CFB/golf), decoupled from x-monitor.R's
# 15-minute check cadence. Needs CFBD_API_KEY and GOLF_API_KEY on top of
# whatever x-monitor.sh already requires -- both come from the macOS
# Keychain via autopilot-env.sh, same as every other openclaw-scripts/*.sh.
# Called by an OpenClaw cron job on the Mac Mini, once/day.

cd ~/autopilot
scripts/autopilot-env.sh /opt/homebrew/bin/Rscript openclaw-scripts/feature-store-refresh.R "$@"
