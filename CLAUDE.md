# Merrittocracy Autopilot

## Project Summary
Distribution automation for the Merrittocracy brand. Takes a published Substack
post, drafts an X thread via Claude API, queues it in a Google Sheet for human
approval, and posts approved threads to X as reply chains. One human approval
step between draft and publish — ~30 seconds on a phone per post.

See `README.md` for setup, scheduling, and operator workflow. This file is for
agent/Claude Code context when editing the repo.

## Who You're Working With
Merrittocracy is run by a director-level data scientist with deep R expertise
(tidyverse, httr2, googlesheets4). Day job is healthcare analytics — this
project is fully separate. Preferences:
- Concise, direct responses — no fluff
- Merrittocracy handles voice and judgment calls; you handle pipeline plumbing
- When in doubt on architecture: **ask before proceeding**
- When in doubt on implementation details: **make reasonable assumptions, note
  them, keep moving**
- If you disagree with a locked-in decision below: **flag and pause** — do not
  silently proceed or unilaterally change direction

---

## Architecture Decisions (Locked In)

### Approval-Gated, Not Default-Off
The pipeline's safety model is a **human approval checkpoint before publish**,
not a global posting disable flag.
- **X threads:** Telegram is the approval surface. Drafts are still logged to
  the `queue` tab, but the sheet is the audit trail/fallback queue, not the
  primary action layer.
- **LinkedIn posts:** Telegram is the approval surface. Drafts are still logged
  to the `linkedin` sheet tab, but the sheet is the audit trail/fallback queue,
  not the primary action layer.
Do not propose adding a second global on/off switch on top of this.

### Script Ordering and Naming
Numbered `NN_verb_object.R` pattern. Current pipeline:
```
R/00_config.R              # Constants, packages, paths, API key loading
R/01_feed_check.R          # RSS poll, new-post detection, feed state
R/02_extract_content.R     # HTML → title, hook, images, data points
R/03_draft_thread.R        # Claude API call, voice prompt, thread structure
R/04_queue_write.R         # Google Sheet write (pending status)
R/05_post_to_x.R           # Approved threads → X reply chain via API v2
R/06_log_run.R             # Diagnostics, log reading, history export
run_distribution.R         # Entry point: --check, --post, --status, --backfill
```
Do NOT renumber existing scripts. New scripts get the next available number or
a letter suffix (`02b_...`) if they belong to an existing stage.

### Voice Prompt Lives in Markdown, Not R
`prompts/thread_draft_system.md` is the system prompt for thread generation.
It is version-controlled separately from code so voice iteration doesn't require
R changes and git diffs show voice evolution cleanly. When iterating:
- Edit the markdown file
- Before overwriting, copy the current version to `prompts/archive/YYYY-MM-DD_thread_draft_system.md`
- Commit voice changes as their own commit, not mixed with code changes

### State Files Are Runtime-Managed
`data/feed_state.json` and any `data/processed_posts.json` are written by the
running pipeline. They track which Substack posts have been seen and processed.
**Do NOT modify these files from a Claude Code session, do not regenerate them,
do not "clean them up."** Stomping them causes either reprocessing of old posts
(duplicate threads) or skipping of new posts (missed publications). If state
appears corrupt, surface the issue — don't fix it silently.

### Output Flow
Substack RSS → R pipeline → Google Sheet (review queue) → X API v2 reply chain.
GitHub is version control, not an automation trigger. launchd on Mac Mini is
the scheduler. Do NOT propose GitHub Actions, webhooks, or CI-based triggers
for the posting flow.

### Single Source of Truth: openclaw-scripts/
All OpenClaw agent-side scripts live canonically in `~/autopilot/openclaw-scripts/`.
The previous `~/.openclaw/workspace/scripts/` mirror was deprecated in commit
`1b4fff3` (Bundle #1, 2026-06-13). Do NOT propose restoring the mirror, copy-back
sync patterns, or any architecture that creates two source-of-truth copies of
the same script.

### Earnest Owns Telegram Bot I/O
The Telegram bot (`merrittocracybot`) is owned by OpenClaw on the Mac Mini.
Autopilot scripts do NOT call the Telegram bot API with `reply_markup` /
inline_keyboard messages, and do NOT poll `getUpdates`. Earnest handles all
Telegram I/O (sends, callback reception, ACKs) via OpenClaw's routing layer
and pipes JSON to log-only scripts (`x-surfacing-log.sh`, `x-feedback-log.sh`).
The Bundle #3 fix (commit `a0c0bd7`, 2026-06-13) established this contract.
See OpenClaw-Ops `journal/2026-W24.md` for the full architecture.

### Cron-Only on the Mac Mini
All recurring work on the Mac Mini runs via `openclaw cron` jobs. There is no
heartbeat loop or persistent listener. Do NOT propose heartbeat-style checks,
long-poll listeners, or any persistent process for scheduled work. See
"Heartbeat Architecture Deprecated" entry in OpenClaw-Ops `journal/2026-W24.md`.

---

## Credentials and Secrets
- `.env` at repo root, loaded via `00_config.R`. Never hardcode keys.
- `.env` is gitignored. `.env.example` is the tracked template.
- Required keys: Anthropic API, X API (bearer + consumer + access tokens).
- Google Sheets uses OAuth — no API key, token cached in `~/.cache/gargle/`.
- If a key rotation is needed, point the user at the `.env` file — do NOT paste,
  display, or transmit key values in chat.
- Before any `git push`, verify `.env`, `data/`, `staging/`, `logs/` are
  gitignored and no credentials leaked into tracked files.

## Hard Wall — Out of Scope
Nothing related to the user's day job at Florida Blue belongs in this workspace.
No employer data, credentials, networks, or artifacts of any kind. If a task
looks like it might pull in employer context — stop and flag it.

---

## Known Issues / TODOs
1. **Hero graphic attachment via `og:image`.** Current code extracts `<img>`
   tags from RSS body content — this gets in-body data charts, not the cover
   image. The canonical hero source is the `og:image` meta tag on the post page
   (Substack always populates this from the cover image set in the editor UI).
   Phase 3 work: in `02_extract_content.R`, add `fetch_hero_image()` that fetches
   the post URL, parses `<meta property="og:image">`, downloads it, and returns
   it as `image_paths[1]`. Cover image should be set correctly in Substack UI
   before publishing — that's the upstream requirement. Do NOT build until Phase 2
   (thread drafting) is stable.
2. **Phased posting posture.** Current: draft → Sheet → manual review →
   approved → auto-post to X. Future phases expand to inbound reply surfacing
   (draft replies to Sheet for approval) and retweet candidate surfacing
   (surfacing only, never automated retweets). See roadmap discussion in chat
   history when ready to scope.
3. **Launchd frequencies** (`check` every 15m, `post` every 5m) are initial
   guesses. Revisit after a shadow period of real posts. Keep conservative until
   we see how Substack RSS cache timing and X API rate limits actually behave.

---

## Code Style
- tidyverse style: base R `|>` pipe, dplyr verbs, snake_case
- `cli::` for console output (`cli_h1`, `cli_alert_success`, `cli_alert_info`)
- `glue::glue()` for string interpolation, not `paste0()` with `+`
- `here::here()` for paths, never hardcoded absolute paths
- Comments explain *why*, not *what*
- When modifying any script, add a single-line header comment noting the date
  and what changed (most-recent-first).

## Pipe Compatibility — Base R `|>` vs magrittr `%>%`
Codebase uses base R `|>`. Scan for these magrittr-only patterns that silently
fail or error with `|>`:
- **`.` placeholder** — `|> set_names(map_chr(., ...))` → assign first, then call
- **`%>%` with `.` in non-first argument** — e.g., `lm(y ~ x, data = .)`
- Any function where the pipe target needs to appear in a non-first argument

**Fix pattern:** Break the chain, assign the intermediate result, pass explicitly.

## Debugging Approach
When a fix fails twice in a row, stop iterating on the same approach. Step back,
question the assumption, consider whether the parameter causing the error
should be simplified or removed rather than patched. Ask before attempting a
third variation.

---

## Do NOT
- Modify `data/feed_state.json` or other runtime state files from a session
- Hardcode API keys or paste key values into chat
- Add GitHub Actions or webhook triggers for posting
- Renumber existing pipeline scripts
- Mix voice prompt edits with R code edits in the same commit
- Add a second global on/off posting switch — the approval column IS the switch
- Build hero graphic attachment before Phase 2 is stable
- Suggest switching to Python — R is the stack, googlesheets4/httr2/rvest cover
  everything needed
- Call the Telegram bot API directly from autopilot scripts with `reply_markup` /
  inline_keyboard — Earnest (via OpenClaw) owns bot I/O. Scripts persist JSONL
  logs only.
- Propose heartbeat-style listeners or persistent polling on the Mac Mini — all
  recurring work runs via `openclaw cron`.
- Restore the `~/.openclaw/workspace/scripts/` mirror or any copy-back sync
  pattern — single source of truth is `~/autopilot/openclaw-scripts/`.
- Silently change any locked-in decision above

---

