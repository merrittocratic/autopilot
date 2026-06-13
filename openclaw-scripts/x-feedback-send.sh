#!/bin/bash
# x-feedback-send.sh -- env-injected wrapper for x-feedback-send.R
#
# Reads JSON {"candidate": {...}, "draft": "..."} from stdin and forwards
# to x-feedback-send.R, which sends the candidate to Telegram with feedback
# buttons and logs the surfacing.

cd ~/autopilot
scripts/autopilot-env.sh /opt/homebrew/bin/Rscript openclaw-scripts/x-feedback-send.R "$@"
