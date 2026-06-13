#!/bin/bash
# x-feedback-ack.sh — Send a quick visual ACK for an inline button tap.
#
# The Telegram answerCallbackQuery ACK (spinner clear) requires responding
# within 30 seconds, which OpenClaw misses due to agent turn latency. This
# script fires a short confirmation message instead, giving Steve visible
# feedback without needing the native ACK mechanism.
#
# Usage:
#   bash x-feedback-ack.sh <bucket_code> [tweet_id]
#   bucket_code: s | c | e
#
# Called by Earnest immediately on receiving fb:{tweet_id}:{bucket_code}.

set -euo pipefail

BUCKET_CODE="${1:-}"
TWEET_ID="${2:-unknown}"

case "$BUCKET_CODE" in
  s) LABEL="Skip" ;;
  c) LABEL="As-is" ;;
  e) LABEL="Edited" ;;
  *) LABEL="$BUCKET_CODE" ;;
esac

BOT_TOKEN=$(security find-generic-password -s autopilot -a TELEGRAM_BOT_TOKEN -w 2>/dev/null || echo "")
if [ -z "$BOT_TOKEN" ]; then
  BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
fi
CHAT_ID="8676616323"

if [ -z "$BOT_TOKEN" ]; then
  echo "[x-feedback-ack] TELEGRAM_BOT_TOKEN not set" >&2
  exit 1
fi

curl -s "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d text="✓ Logged: ${LABEL}" \
  > /dev/null

echo "[x-feedback-ack] sent: $LABEL"
