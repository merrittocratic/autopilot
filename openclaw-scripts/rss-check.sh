#!/bin/bash
# rss-check.sh — Lightweight RSS check, zero AI cost when nothing is new
#
# Logic:
#   1. Fetch Substack RSS feed (curl)
#   2. Extract article URLs
#   3. Compare against feed_state.json processed_ids
#   4. If new article found: print its URL and title to stdout, exit 0
#   5. If nothing new: print nothing, exit 1
#
# Caller (cron job) checks exit code:
#   exit 0 → new article found, trigger AI drafting session
#   exit 1 → nothing new, NO_REPLY, zero AI cost

FEED_URL="https://themerrittocracy.substack.com/feed"
STATE_FILE="$HOME/autopilot/data/feed_state.json"

# Fetch feed and extract items (url + title pairs, newline separated)
FEED=$(curl -s --max-time 15 "$FEED_URL") || exit 1

# Parse feed with python3 — extract title, link, pubDate for each item
NEW_ARTICLES=$(python3 - <<'EOF'
import sys, json, xml.etree.ElementTree as ET

feed = sys.stdin.read()
try:
    root = ET.fromstring(feed)
except ET.ParseError:
    sys.exit(1)

ns = {'content': 'http://purl.org/rss/1.0/modules/content/'}
channel = root.find('channel')
items = channel.findall('item') if channel else []

# Load processed IDs
import os
state_file = os.path.expanduser('~/autopilot/data/feed_state.json')
try:
    with open(state_file) as f:
        state = json.load(f)
    processed = set(state.get('processed_ids', []))
except:
    processed = set()

new_items = []
for item in items:
    link = item.findtext('link', '').strip()
    title = item.findtext('title', '').strip()
    slug = link.rstrip('/').split('/')[-1]
    
    if link not in processed and slug not in processed:
        new_items.append({'url': link, 'title': title, 'slug': slug})

if new_items:
    print(json.dumps(new_items))
    sys.exit(0)
else:
    sys.exit(1)
EOF
<<< "$FEED"
)

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ] && [ -n "$NEW_ARTICLES" ]; then
    echo "$NEW_ARTICLES"
    exit 0
else
    exit 1
fi
