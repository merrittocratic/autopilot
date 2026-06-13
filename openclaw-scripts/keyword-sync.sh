#!/bin/bash
# ============================================================================
# keyword-sync.sh — Ensure all processed articles have x-monitor.R keywords
# ============================================================================
# Runs daily via launchd. Compares processed slugs in feed_state.json against
# keyword entries already in x-monitor.R. For each gap, calls
# update-monitor-keywords.sh to extract and add keywords.
#
# Idempotent — safe to run repeatedly. Zero cost on days with no gaps.
# Does NOT go through OpenClaw; calls Anthropic API directly (Haiku).
#
# Usage:
#   bash keyword-sync.sh
# ============================================================================

set -euo pipefail

AUTOPILOT_DIR="$HOME/autopilot"
FEED_STATE="$AUTOPILOT_DIR/data/feed_state.json"
# 2026-06-13 — single source of truth: autopilot/openclaw-scripts/x-monitor.R
MONITOR_SCRIPT="$AUTOPILOT_DIR/openclaw-scripts/x-monitor.R"
UPDATE_SCRIPT="$AUTOPILOT_DIR/openclaw-scripts/update-monitor-keywords.sh"
LOG_DIR="$AUTOPILOT_DIR/logs"
LOG_FILE="$LOG_DIR/$(date +%Y-%m-%d)_autopilot.log"
SUBSTACK_BASE="https://themerrittocracy.substack.com/p"

log_json() {
  local event_type="$1"
  local message="$2"
  local details="${3:-{}}"
  local ts
  ts=$(date +"%Y-%m-%dT%H:%M:%S%z")
  echo "{\"timestamp\":\"$ts\",\"event_type\":\"$event_type\",\"message\":\"$message\",\"details\":$details}" \
    >> "$LOG_FILE"
}

mkdir -p "$LOG_DIR"

# ── Sanity checks ────────────────────────────────────────────────────────────

if [ ! -f "$FEED_STATE" ]; then
  echo "[keyword-sync] feed_state.json not found: $FEED_STATE" >&2
  log_json "keyword_sync_error" "feed_state.json not found" "{}"
  exit 1
fi

if [ ! -f "$UPDATE_SCRIPT" ]; then
  echo "[keyword-sync] update-monitor-keywords.sh not found: $UPDATE_SCRIPT" >&2
  log_json "keyword_sync_error" "update-monitor-keywords.sh not found" "{}"
  exit 1
fi

# ── Extract processed slugs from feed_state.json ─────────────────────────────
# IDs come in two formats: full URL or bare slug. Normalise to slug only.

PROCESSED_SLUGS=$(python3 - "$FEED_STATE" <<'PYEOF'
import json, sys, re

with open(sys.argv[1]) as f:
    state = json.load(f)

ids = state.get("processed_ids", [])
slugs = set()
for id_ in ids:
    # Strip trailing slash, then grab everything after last /
    slug = re.sub(r'/$', '', id_).split('/')[-1]
    if slug:
        slugs.add(slug)

for s in sorted(slugs):
    print(s)
PYEOF
)

if [ -z "$PROCESSED_SLUGS" ]; then
  echo "[keyword-sync] No processed slugs found — nothing to do" >&2
  log_json "keyword_sync" "No processed slugs found" "{}"
  exit 0
fi

# ── Extract slugs already in x-monitor.R ─────────────────────────────────────

MONITOR_SLUGS=$(grep 'slug = "' "$MONITOR_SCRIPT" \
  | grep -v 'matched_article_slug' \
  | sed 's/.*slug = "//; s/".*//' \
  | sort)

# ── Find gaps ────────────────────────────────────────────────────────────────

MISSING=$(comm -23 \
  <(echo "$PROCESSED_SLUGS") \
  <(echo "$MONITOR_SLUGS"))

MISSING_COUNT=$(echo "$MISSING" | grep -c . 2>/dev/null || echo 0)

if [ -z "$MISSING" ] || [ "$MISSING_COUNT" -eq 0 ]; then
  echo "[keyword-sync] All $( echo "$PROCESSED_SLUGS" | wc -l | tr -d ' ') articles have keywords — nothing to do" >&2
  log_json "keyword_sync" "All articles have keywords — no gaps" \
    "{\"processed_count\":$(echo "$PROCESSED_SLUGS" | wc -l | tr -d ' ')}"
  exit 0
fi

echo "[keyword-sync] Found $MISSING_COUNT article(s) missing keywords:" >&2
echo "$MISSING" | sed 's/^/  /' >&2

log_json "keyword_sync_start" "Found $MISSING_COUNT articles missing keywords" \
  "{\"missing_count\":$MISSING_COUNT,\"slugs\":$(echo "$MISSING" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip().split("\n")))')}"

# ── Fill gaps ────────────────────────────────────────────────────────────────

SUCCESS=0
FAILED=0
FAILED_SLUGS=()

while IFS= read -r slug; do
  [ -z "$slug" ] && continue

  article_url="$SUBSTACK_BASE/$slug"
  echo "[keyword-sync] Processing: $slug" >&2

  if bash "$UPDATE_SCRIPT" "$article_url" "$slug" >/dev/null 2>&1; then
    echo "[keyword-sync] ✓ $slug" >&2
    log_json "keyword_sync_added" "Keywords added for $slug" \
      "{\"slug\":\"$slug\",\"url\":\"$article_url\"}"
    SUCCESS=$((SUCCESS + 1))
  else
    echo "[keyword-sync] ✗ $slug (failed)" >&2
    log_json "keyword_sync_error" "Keyword extraction failed for $slug" \
      "{\"slug\":\"$slug\",\"url\":\"$article_url\"}"
    FAILED=$((FAILED + 1))
    FAILED_SLUGS+=("$slug")
  fi

  # Small pause between API calls
  [ "$MISSING_COUNT" -gt 1 ] && sleep 2

done <<< "$MISSING"

# ── Summary ──────────────────────────────────────────────────────────────────

FAILED_JSON="[]"
if [ ${#FAILED_SLUGS[@]} -gt 0 ]; then
  FAILED_JSON=$(printf '%s\n' "${FAILED_SLUGS[@]}" \
    | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip().split("\n")))')
fi

log_json "keyword_sync_complete" "Keyword sync done: $SUCCESS added, $FAILED failed" \
  "{\"success\":$SUCCESS,\"failed\":$FAILED,\"failed_slugs\":$FAILED_JSON}"

echo "[keyword-sync] Done — $SUCCESS added, $FAILED failed" >&2

# Exit non-zero if any failed so launchd can log it
[ "$FAILED" -eq 0 ]
