#!/bin/bash
# voice-sample-refresh.sh -- wrapper for voice-sample-refresh.R
#
# No secrets needed (pure filesystem read of ~/content/published) -- no
# autopilot-env.sh required. Safe to run often; it's a no-op unless the
# most-recent-5-articles set has actually changed. Called by an OpenClaw
# cron job on the Mac Mini.

cd ~/autopilot
/opt/homebrew/bin/Rscript openclaw-scripts/voice-sample-refresh.R "$@"
