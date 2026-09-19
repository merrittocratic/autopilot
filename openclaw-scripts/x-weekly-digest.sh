#!/bin/bash
# x-weekly-digest.sh -- wrapper for x-weekly-digest.R
#
# Weekly X performance summary, sent to Telegram. Suggested cadence:
# Sunday 8am ET (the digest message itself says "Next digest: next
# Sunday 8am ET") -- register via openclaw cron on the Mac Mini.
#
# 2026-09-19 -- weekly-digest.R/.sh retired (2026-09-19 audit,
# L-1/L-2 consolidation); this is now the single source of truth for
# the weekly digest.

cd ~/autopilot
scripts/autopilot-env.sh /opt/homebrew/bin/Rscript openclaw-scripts/x-weekly-digest.R "$@"
