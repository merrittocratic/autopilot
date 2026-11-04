# Handoff for Earnest: reply drafts get positions + web search

Date: 2026-11-04 (second pass, same day). From: Manfred. Approved by Steve.
Journal: OpenClaw-Ops `journal/2026-W45.md`, entry "X Reply Drafting:
Steve's Positions + Web Search". Builds on
`HANDOFF-2026-11-04-reply-overhaul.md`; do that one first if it isn't done.

## Why

Steve's verdict on the first live draft (the @TheHerd Stroud / Bryce Young
clip): not an improvement. It argued *against* Stroud, which Steve would
never do, echoed Colin's line back as a sneer, and used a `[STAT]` whose
value would decide which side the reply was on. Root cause: the voice
sample teaches the model how Steve sounds, not what he thinks, and with no
facts allowed it filled the gap with sarcasm and placeholders.

This pull:
- `prompts/steve_positions.md` (new): Steve's standing takes. He edits it.
- `prompts/x_reply_tier_*.md`: take Steve's side when a position applies;
  options differ by angle, and style labels may repeat; banned echoes and
  stock frames; a placeholder may only fill a number whose direction is
  already known; search before writing a data option. Previous versions
  are in `prompts/archive/2026-11-04b_*`.
- `x-length-check.R`: rejects banned stock phrases (`banned_phrase` is
  set and `length_ok` is false). You already drop on `length_ok`, so no
  change is needed.

## Steps

Pull between monitor runs. The output format is unchanged, so you don't
need to pause the jobs. But a run on the new prompts before step 1 is done
would leave a literal `{steve_positions}` in the prompt, so do step 1
right after pulling.

1. **New placeholder `{steve_positions}`:** fill it with the full contents
   of `~/autopilot/prompts/steve_positions.md`, verbatim and read fresh on
   every run. It sits in the cached prefix (above the "Caching note"), so
   it belongs in the `cache_control` system block with the voice sample.
2. **Web search on the drafting call only.** Add this tool to the Sonnet
   5.5 drafting request:
   `{"type": "web_search_20250305", "name": "web_search", "max_uses": 2}`
   - Use the 20250305 version, not `web_search_20260209`. In laptop tests
     the dynamic-filtering version mostly skipped searching and used about
     40K input tokens when it did search.
   - If OpenClaw can't attach Anthropic server tools to that call, tell
     Steve and skip this step. The prompts still work without search;
     they fall back to placeholders.
3. **Parsing with search on:**
   - The response has several `text` blocks, because citations split
     them. Join all `text` blocks with an empty string before you parse
     `OPTION` lines. Ignore `server_tool_use` and `web_search_tool_result`
     blocks, and any text before the first `OPTION` line.
   - The style can now repeat (two `data` options is valid). The style is
     still one of `data`, `needle` or `verdict`.
   - If `stop_reason` is `pause_turn` (unlikely with `max_uses: 2`),
     treat the candidate as SKIP and log it.
4. **Dropped-option logging** (from your 1-option feedback): keep `Post 1`
   when only one option survives. In the `x-surfacing-log.sh` `options`
   array, also include the dropped options, with
   `"dropped": "length" | "banned_phrase" | "fact_check"`, and add
   `"raw_option_count"` (how many the model returned). That tells us
   whether single-option candidates come from the model or the gates.
5. **Check:** after a few drafts, confirm `usage.server_tool_use.web_search_requests`
   is above 0 on some of them, and send Steve the first surfaced
   candidate with its options.
6. **Journal:** add a dated note under the new W45 entry's Verification.

## Cost

With search on, each drafted candidate is about 30K input tokens, mostly
search results, plus up to 2 searches at $0.01 each. That's roughly
$0.07 per candidate, or about $0.50-0.80 a day at the current cap.

## Rollback

- Remove the web_search tool from the drafting call.
- Prompts: copy `prompts/archive/2026-11-04b_x_reply_tier_*.md` back over
  `prompts/x_reply_tier_*.md`, and stop filling `{steve_positions}`.
