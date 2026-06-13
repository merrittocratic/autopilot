# openclaw-scripts/

OpenClaw agent-side scripts for the Merrittocracy automation pipeline.

## Source-of-truth model (as of 2026-06-13)

This directory is the **canonical source** for all X-monitoring and
sports-digest scripts. The Mac Mini runs them directly from
`$HOME/autopilot/openclaw-scripts/` via `openclaw cron` and launchd.

The previous mirror at `~/.openclaw/workspace/scripts/` is **deprecated**.
Earnest should update any `openclaw cron` job that still points at the
workspace path to call the autopilot version instead. After that, the
workspace copies can be deleted.

## Scripts

### `rss-check.sh`
Lightweight RSS poller — no AI cost on quiet runs. Fetches Substack feed, compares against `~/autopilot/data/feed_state.json`. Exits 0 + JSON if new article found, exits 1 if nothing new. Called by the OpenClaw `rss-check` cron job.

### `update-monitor-keywords.sh`
Auto-updates `x-monitor.R` with keywords extracted from a new article. Edits the autopilot canonical directly, commits, and pushes. Called automatically by the RSS check cron when a new article is detected. Uses Claude Haiku (~$0.001/call). Idempotent.

### `keyword-sync.sh`
Daily reconciliation pass — for every article in `feed_state.json` missing
a keyword entry in `x-monitor.R`, calls `update-monitor-keywords.sh` to
fill the gap. Safe to run repeatedly; zero cost on days with no gaps.

### `x-monitor.R`
Scans the curated X follow list for reply opportunities. Tier-aware
scoring (1A / 1B / 1C / 2), substantiveness heuristic, engagement-velocity
override, freshness gating. Outputs candidate JSON including `tier`,
`draft_style`, and `draft_prompt_path` so the cron-driven drafting
step can pick the right reply prompt template from `~/autopilot/prompts/`.

Flags:
- `--hours N` — lookback window (default 3)
- `--draft-night` — 1-hour lookback for high-frequency draft mode
- `--tier 1A` — restrict scan to a single tier (used by the fast-lane cron)

### `x-monitor.sh`
Shell wrapper for `x-monitor.R`. Injects keychain secrets via
`scripts/autopilot-env.sh`, then calls the R script. Forwards all
arguments through, so `x-monitor.sh --tier 1A` works as expected.

### `x-surfacing-log.R` / `x-surfacing-log.sh`
Appends a single surfacing record to `data/x-monitor-surfacings.jsonl`.
Reads `{"candidate": {...}, "draft": "...", "message_id": N}` from
stdin. **Does NOT call Telegram.**

Telegram I/O is owned by Earnest via OpenClaw's routing layer. After
Earnest successfully sends a candidate-with-buttons message via
OpenClaw, he pipes the surfacing event here for logging. Splitting
the responsibility this way avoids a two-poller conflict with
OpenClaw on `getUpdates` and respects OpenClaw's outbound-send
ownership.

### `x-feedback-log.R` / `x-feedback-log.sh`
Appends a single feedback bucket record to
`data/x-monitor-feedback.jsonl`. Reads `{"tweet_id": "...",
"bucket_code": "s|c|e", ...}` from stdin. **Does NOT call Telegram.**

OpenClaw routes Telegram `callback_query` events to Earnest. Earnest
parses the `callback_data` (formatted `fb:{tweet_id}:{bucket_code}`),
ACKs via OpenClaw, then pipes the parsed event here for logging.
Join `x-monitor-surfacings.jsonl` and `x-monitor-feedback.jsonl` on
`tweet_id` for per-account, per-tier, time-of-day hit-rate analysis.

### `morning-sports-digest.R` / `morning-sports-digest.sh`
6:00am ET digest — fetches previous day's ESPN/Fox Sports tweets,
filters for NBA/NFL/Golf, identifies Star of the Night, sends to
Telegram. After the digest send, runs a second Claude call against
the same tweet bundle to produce 3-5 **Today's Takes** (original-post
candidates with hooks) and sends them as a separate Telegram message.
If yesterday's news was thin, the takes call returns the
`NO_TAKES_TODAY` sentinel and no second message is sent.

### `weekly-digest.R` / `weekly-digest.sh`
Weekly summary digest.

### `draft-expiry-nudge.R` / `draft-expiry-nudge.sh`
Reminds Steve about pending drafts in the Google Sheet that are aging out.

### `check-pending-drafts.sh`
Reads the Google Sheet queue for pending tweet drafts. Called by an
OpenClaw cron job on the Mac Mini.

### `x-monitor-list.md`
Curated list of X accounts to monitor. Each line may carry an optional
`[tier:1A]` / `[tier:1B]` / `[tier:1C]` annotation; unannotated handles
default to tier 2. See file header for tier semantics.

### `x-engaged-accounts.md`
Accounts where @Merrittocratic has prior engagement history. The X API
blocks API replies/quote tweets to "cold" accounts, so this list gates
which candidates are flagged `can_reply_via_api = true`.

## Runtime state (NOT in this directory)

State files are runtime-managed and live outside the repo (gitignored):
- `~/.openclaw/workspace/memory/x-monitor-state.json` — seen tweets,
  user-ID cache, daily counters.
- `~/autopilot/data/feed_state.json` — RSS feed state.
- `~/autopilot/data/x-monitor-surfacings.jsonl` — append log of each
  candidate sent to Telegram with feedback buttons (written by
  `x-surfacing-log.R`).
- `~/autopilot/data/x-monitor-feedback.jsonl` — append log of each
  feedback bucket received (written by `x-feedback-log.R`).

Do not modify these from a Claude Code session.
