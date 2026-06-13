#!/bin/bash
# update-monitor-keywords.sh — Auto-update x-monitor.R with keywords from a new article
#
# Usage: bash update-monitor-keywords.sh <article_url> <article_slug>
#
# Fetches article content, uses Claude Haiku to extract keywords and a one-line
# summary, then appends a new ARTICLE_TOPICS entry to x-monitor.R.
# Idempotent — skips if slug already present.

set -e

ARTICLE_URL="$1"
ARTICLE_SLUG="$2"
# 2026-06-13 — single source of truth: edit autopilot canonical directly.
MONITOR_SCRIPT="$HOME/autopilot/openclaw-scripts/x-monitor.R"
TMPDIR_WORK=$(mktemp -d)
trap "rm -rf $TMPDIR_WORK" EXIT

if [ -z "$ARTICLE_URL" ] || [ -z "$ARTICLE_SLUG" ]; then
  echo "Usage: $0 <article_url> <article_slug>" >&2
  exit 1
fi

# Idempotency check
if grep -q "\"$ARTICLE_SLUG\"" "$MONITOR_SCRIPT"; then
  echo "✓ Slug '$ARTICLE_SLUG' already in x-monitor.R — skipping" >&2
  exit 0
fi

# Get Anthropic API key from keychain
ANTHROPIC_API_KEY=$(security find-generic-password -s autopilot -a ANTHROPIC_API_KEY -w 2>/dev/null)
if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "❌ Could not retrieve ANTHROPIC_API_KEY from keychain" >&2
  exit 1
fi

# Fetch and extract article text
echo "Fetching article: $ARTICLE_URL" >&2
curl -s --max-time 30 "$ARTICLE_URL" | python3 -c "
import sys
from html.parser import HTMLParser

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.text = []
        self.current_skip = 0
        self.skip_tags = {'script', 'style', 'nav', 'header', 'footer'}
    def handle_starttag(self, tag, attrs):
        if tag in self.skip_tags: self.current_skip += 1
    def handle_endtag(self, tag):
        if tag in self.skip_tags and self.current_skip > 0: self.current_skip -= 1
    def handle_data(self, data):
        if self.current_skip == 0:
            s = data.strip()
            if s: self.text.append(s)

p = TextExtractor()
p.feed(sys.stdin.read())
print(' '.join(p.text)[:3000])
" > "$TMPDIR_WORK/article.txt" 2>/dev/null

if [ ! -s "$TMPDIR_WORK/article.txt" ]; then
  echo "❌ Could not fetch article content" >&2
  exit 1
fi

# Build Claude API request JSON
python3 - "$TMPDIR_WORK/article.txt" "$ARTICLE_URL" "$ARTICLE_SLUG" > "$TMPDIR_WORK/request.json" <<'PYEOF'
import json, sys

content_file, url, slug = sys.argv[1], sys.argv[2], sys.argv[3]
with open(content_file) as f:
    content = f.read()

prompt = f"""You are helping maintain an X (Twitter) monitoring keyword list for a sports analytics blog called TheMerrittocracy.

Given this article, extract:
1. 10-15 specific keywords/phrases that would appear in tweets ABOUT this topic (player names, team names, specific stats, key concepts from the article)
2. A one-sentence summary of the article's core argument (max 120 chars)

Article URL: {url}
Article content: {content[:2500]}

Respond with ONLY valid JSON, no other text:
{{"keywords": ["keyword1", "keyword2"], "summary": "One sentence summary."}}"""

payload = {
    "model": "claude-haiku-4-5",
    "max_tokens": 400,
    "messages": [{"role": "user", "content": prompt}]
}
print(json.dumps(payload))
PYEOF

# Call Claude API
echo "Extracting keywords via Claude..." >&2
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPDIR_WORK/response.json" \
  --max-time 30 \
  -X POST "https://api.anthropic.com/v1/messages" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d @"$TMPDIR_WORK/request.json")

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ Claude API returned HTTP $HTTP_CODE" >&2
  cat "$TMPDIR_WORK/response.json" >&2
  exit 1
fi

# Extract keywords and summary from response
python3 - "$TMPDIR_WORK/response.json" "$ARTICLE_SLUG" "$MONITOR_SCRIPT" <<'PYEOF'
import json, sys, re

response_file, slug, monitor_script = sys.argv[1], sys.argv[2], sys.argv[3]

with open(response_file) as f:
    resp = json.load(f)

raw = resp["content"][0]["text"].strip()

# Strip markdown code fences if present
raw = re.sub(r'^```json\s*', '', raw)
raw = re.sub(r'\s*```$', '', raw)

data = json.loads(raw)
keywords = [k.lower() for k in data["keywords"]]
summary = data["summary"].replace('"', '\\"')

r_keywords = "c(" + ", ".join(f'"{k}"' for k in keywords) + ")"

new_entry = f'''  list(
    slug = "{slug}",
    keywords = {r_keywords},
    summary = "{summary}"
  )'''

print(f"Keywords: {r_keywords}", file=sys.stderr)
print(f"Summary: {summary}", file=sys.stderr)

with open(monitor_script, "r") as f:
    content = f.read()

marker = ')\n\n# Keywords that trigger HARD SKIP'
if marker not in content:
    print("❌ Could not find insertion point in x-monitor.R", file=sys.stderr)
    sys.exit(1)

updated = content.replace(marker, ',\n' + new_entry + '\n' + marker, 1)

with open(monitor_script, "w") as f:
    f.write(updated)

print(f"✅ Added '{slug}' to x-monitor.R")
PYEOF

# --- Commit and push the keyword update --------------------------------------
# Single-source-of-truth: we edited the autopilot canonical directly above,
# so no cp step needed — just commit and push.
AUTOPILOT_DIR="$HOME/autopilot"
cd "$AUTOPILOT_DIR"
git add openclaw-scripts/x-monitor.R

if ! git diff --cached --quiet; then
  bash scripts/autopilot-env.sh git commit -m "auto: update x-monitor.R keywords for article '$ARTICLE_SLUG'" 2>&1 | grep -E 'main|error' >&2
  bash scripts/autopilot-env.sh git pull --rebase 2>&1 | tail -1 >&2
  bash scripts/autopilot-env.sh git push 2>&1 | grep -E 'To https|error' >&2
  echo "[update-monitor-keywords] pushed to autopilot repo" >&2
else
  echo "[update-monitor-keywords] no diff -- autopilot repo already up to date" >&2
fi
