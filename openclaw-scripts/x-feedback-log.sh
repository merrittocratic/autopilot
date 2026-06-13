#!/bin/bash
# x-feedback-log.sh -- wrapper for x-feedback-log.R
#
# Log-only contract; no secrets required. Earnest pipes feedback JSON
# to this script after parsing a callback_query routed by OpenClaw.

cd ~/autopilot
/opt/homebrew/bin/Rscript openclaw-scripts/x-feedback-log.R "$@"
