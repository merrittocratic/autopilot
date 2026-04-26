# openclaw-scripts/

OpenClaw agent-side scripts for the Merrittocracy automation pipeline.
These run inside the OpenClaw workspace (`~/.openclaw/workspace/scripts/`) on the Mac Mini.

## Scripts

### `rss-check.sh`
Lightweight RSS poller — no AI cost on quiet runs. Fetches Substack feed, compares against `~/autopilot/data/feed_state.json`. Exits 0 + JSON if new article found, exits 1 if nothing new. Called by the OpenClaw `rss-check` cron job.

### `update-monitor-keywords.sh`
Auto-updates `x-monitor.R` with keywords extracted from a new article. Called automatically by the RSS check cron when a new article is detected. Uses Claude Haiku (~$0.001/call). Idempotent.

### `x-monitor.R`
Scans the curated X follow list for reply opportunities. Scores tweets for relevance against published articles and draft model data. Returns candidates as JSON.

### `x-monitor.sh`
Shell wrapper for `x-monitor.R`. Injects keychain secrets, then calls the R script.

### `check-pending-drafts.sh`
Reads the Google Sheet queue for pending tweet drafts. Called during heartbeat checks.

### `x-monitor-list.md`
Curated list of 38 X accounts to monitor (NFL, Golf, NBA).

## Sync Note
Canonical location on Mac Mini: `~/.openclaw/workspace/scripts/`
This folder is the git-backed mirror. After editing scripts locally, copy back to autopilot/openclaw-scripts/ and commit.
