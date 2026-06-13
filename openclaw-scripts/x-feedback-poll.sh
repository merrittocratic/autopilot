#!/bin/bash
# x-feedback-poll.sh -- env-injected wrapper for x-feedback-poll.R
#
# Polls Telegram getUpdates for callback_query events from the inline
# feedback buttons. Called by an OpenClaw cron job once per minute
# during waking hours.

cd ~/autopilot
scripts/autopilot-env.sh /opt/homebrew/bin/Rscript openclaw-scripts/x-feedback-poll.R "$@"
