# Handoff for Earnest: X reply overhaul (E, F, G)

Date: 2026-11-04. From: Manfred (Claude Code, laptop). Approved by Steve.
Journal: OpenClaw-Ops `journal/2026-W45.md`, entry "X Reply Overhaul".

## Why

Steve rarely posts the drafted X replies. They read bland, and his own
hand-written replies do better. The autopilot side shipped three fixes in
this pull:

- **A.** New `openclaw-scripts/reply-voice-sample-refresh.R` writes Steve's
  25 best real replies to `data/voice-sample/reply_voice_sample.txt`. The
  prompts now use these as voice examples instead of Substack excerpts.
- **B.** Rewritten `prompts/x_reply_tier_*.md`. They take a side, allow
  sarcasm and hard verdicts, and **return up to three options**, not one
  reply.
- **C.** Options may contain `[STAT: ...]` placeholders that Steve fills
  in. `x-length-check.R` (ceiling now 320) and `x-fact-check.R` (now all
  tiers) understand them.

Also in this pull: four Ohio State accounts added at tier 1B, a seeded
`x-engaged-accounts.md` (it was empty), and a fix for an `x-fact-check.R`
bug. Any check that used web search came back "could not parse" and was
silently suppressed as `failed_skipped`.

Your part is E (model bump), F (multi-option drafting and Telegram), and G
(feedback data). The steps run in order.

## Step 0: pause before pulling

The new prompts change the output format and a placeholder name. If
`x-monitor-fast` or `x-monitor-slow` runs on the new prompts before step 3
is wired, Steve gets a three-option blob as one "draft", and an Approve
could post all of it, placeholders included.

1. Disable the `x-monitor-fast` (9969378d) and `x-monitor-slow` (d842ea43)
   openclaw cron jobs. Leave `rss-check` alone.
2. `cd ~/autopilot && git pull`.

## Step 1: install the launchd jobs

From `~/autopilot`, for each label in `com.merritt.autopilot.reply-voice-sample`
and `com.merritt.autopilot.x-daily-note`:

```bash
L=<label>
sed -e "s|__REPO__|$PWD|g" -e "s|__HOME__|$HOME|g" deploy/launchd/$L.plist > ~/Library/LaunchAgents/$L.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$L.plist
launchctl print gui/$(id -u)/$L
```

Then `launchctl kickstart gui/$(id -u)/com.merritt.autopilot.reply-voice-sample`
once. Confirm `data/voice-sample/reply_voice_sample.txt` exists (~9 KB, 25
"They posted / Steve replied" pairs) and that
`logs/launchd_reply_voice_sample_stderr.log` is clean. Do NOT create
openclaw cron jobs for either one. Script-only jobs are launchd now (W45
journal, repo `CLAUDE.md`).

## Step 2 (E): drafting model to Claude Sonnet 5.5

- Change only the **drafting** call in `x-monitor-fast` and
  `x-monitor-slow` to `anthropic/claude-sonnet-5-5`, effort `medium`, no
  temperature. Leave the scan/orchestration model and `rss-check` as they
  are, unless OpenClaw can't split them. If it can't, tell Steve before
  changing the whole job.
- Fill placeholders exactly:
  - `{reply_voice_sample}`: the file contents verbatim.
  - `{username}`, `{tweet_text}`: for 1A/1B, append the quoted tweet text
    when present, as `Quoted tweet: ...`.
  - `{model_data}`: the candidate's `model_data` string, or an **empty
    string** when absent. Never `null`, `NA`, or `NONE`.
  - `{article_summary}`: the matched article summary, or empty.
- Caching: the old notes were written for gpt-5.4-mini's automatic
  caching. Claude needs an explicit breakpoint. Everything above the
  "Caching note" line in each prompt is byte-identical across all five
  tier files (with the voice sample inserted), so send that block as the
  system prompt with `cache_control: {"type": "ephemeral"}`, and the tier
  section plus inputs after it. After a few calls, check that
  `usage.cache_read_input_tokens` is above 0. If OpenClaw doesn't expose
  cache control, skip it: the cost is tiny at this volume. Just tell Steve.

## Step 3 (F): three options per candidate

1. **Parse** the model output:
   - The literal `SKIP` means surface nothing.
   - Otherwise split on lines that start with
     `OPTION <n> (<style>):`, where style is `data`, `needle` or `verdict`.
     An option's text runs until the next `OPTION` line or the end. Trim it.
   - Fewer than three options is normal. Ignore any text outside the
     options.
2. **Gate each option** (all tiers now):
   - `x-length-check.R`, stdin `{"draft": text}`. If `length_ok` is false,
     drop that option.
   - `x-fact-check.sh`, stdin `{"candidate", "tweet_text", "draft": text}`:
     - `failed_skipped`: drop the option.
     - `failed_stripped`: use the returned stripped draft.
     - `passed` / `skipped_no_claims`: keep it as-is.
   - If no options survive, surface nothing.
3. **Telegram message** (your normal send path):
   - The tweet (handle, text, link), then each surviving option numbered
     with its style: `1 (data): ...`.
   - Show `[STAT: ...]` placeholders as-is.
   - Buttons: `Post 1` / `Post 2` / `Post 3` (one per surviving option),
     `Edit`, `Skip`. Keep the existing `fb:{tweet_id}:{bucket}` feedback
     semantics:
     - Post unchanged = `c` (posted_clean)
     - Edit then post = `e` (posted_edited)
     - Skip = `s`
4. **Placeholder guard (hard rule):** the posting path must refuse any
   text that still contains `[STAT:`. On `Post n` for an option with a
   placeholder, reply "Fill the [STAT] first" and wait for Steve's edited
   text. Never post a placeholder to X.
5. **Logging:**
   - `x-surfacing-log.sh` now accepts
     `"options": [{"style", "text", "fact_check"}, ...]`. Send all surviving
     options, and keep `draft` set to option 1's text for older readers.
   - `x-feedback-log.sh` now accepts `option_index` and `option_style`.
     Send them on every Post/Edit.
6. Re-enable `x-monitor-fast` and `x-monitor-slow`. Watch the first
   surfaced candidate end to end and send Steve a note when it lands.

## Step 4 (G): feedback data for Manfred

1. Send Steve, via Telegram as documents, the current
   `~/autopilot/data/x-monitor-surfacings.jsonl` and
   `~/autopilot/data/x-monitor-feedback.jsonl`, both from before today's
   change. Manfred will analyze them on the laptop.
2. Also send a short summary:
   - surfacings by tier and by username
   - feedback counts by bucket (s/c/e)
   - how many surfacings never got any feedback
   - `fact_check` value counts
3. Count how often "could not parse fact-check response" appears in the
   OpenClaw logs since 2026-09-02 (the start of the parse bug), or how
   many tier-2 drafts ended `failed_skipped`. That's how many replies the
   bug suppressed.
4. Housekeeping checks:
   - Does `X_BEARER_TOKEN` in the Mini's Keychain work? The laptop copy
     returns 401. Test with a GET to `/2/users/by/username/Merrittocratic`;
     don't print the token.
   - Have API replies (`can_reply_via_api`) ever posted successfully? The
     engaged list was empty until today, so every candidate was "cold".
   - If the old `~/.openclaw/workspace/x-engaged-accounts.md` still exists,
     send its handles to Steve so Manfred can merge them.

## Step 5: journal

Append the outcome to OpenClaw-Ops `journal/2026-W45.md` under the "X
Reply Overhaul" entry's Verification section, as a new dated note. Don't
edit the entry above it. Include the cache-read check result and anything
you couldn't do.

## Rollback

- **Prompts:** the previous versions are in
  `prompts/archive/2026-11-04_x_reply_tier_*.md`. Copy them back, and
  restore the single-draft parsing and `{voice_sample}` placeholder.
- **Model:** set the drafting model back to `openai/gpt-5.4-mini`.
- **Voice job:** `launchctl bootout gui/$(id -u)/com.merritt.autopilot.reply-voice-sample`.
