# SPEC: Tier-2 Fact-Check Gate for X Reply Drafts

Status: proposed by Earnest, approved by Steve (2026-09-02) for build. Not yet implemented.

## Why

2026-08-31 incident: a Tier-2 reply invented a player name ("Cooper Jr.") and
fabricated boom/bust stats (13%/18%) with zero backing data. Root cause was
not a bad match — the prospect/veteran matcher never fired for that tweet —
it was the drafting step (Earnest, the LLM) inventing content outright when
no match existed.

Existing guards (8bd4ca7, bc2466e) stop bad *data* from reaching the draft
step. They don't stop the draft step from hallucinating something with no
data behind it at all. This spec adds an independent verification pass
*after* the draft is written, before it reaches Telegram, scoped narrowly
to control cost.

## Scope

- **Tier 2 only.** Tier 1A/1B/1C are tightly templated off matched
  `prospect_*`/`veteran_*` fields already; Tier 2 is loose/conversational —
  the tier where the incident happened and where fabrication risk is
  highest. From `x-monitor-surfacings.jsonl` (79-day sample): Tier 2 volume
  is ~0.96 candidates/day. This keeps the added step to roughly 1 call/day.
- Do not expand to other tiers without re-checking cost/volume first.

## Trigger point

Insert as a new step in the Tier-2 drafting flow (wherever
`x_reply_tier_2.md` output currently gets written to
`x-monitor-surfacings.jsonl` / queued for Telegram), before the candidate is
surfaced to Steve.

## Skip-if-no-claims gate (cheap pre-check, no LLM call)

Before spawning the checker, scan the drafted reply text for anything that
needs verification: player/team proper nouns, numeric stats, or specific
factual claims (injury status, trade, roster move, etc.). If the draft is
pure opinion/banter with zero specific claims, skip the checker entirely —
log `fact_check: skipped_no_claims` and let it through. Simple heuristic
(regex for capitalized multi-word names + digit sequences) is fine; doesn't
need to be perfect, just needs to avoid spending a call on drafts with
nothing to check.

## The checker

- **Model:** `claude-haiku-4-5` via direct Anthropic API call (same pattern
  as `update-monitor-keywords.sh` / `morning-sports-digest.R` — no OpenClaw
  routing needed, no main-session token cost). Mechanical fact-matching
  task, not a judgment call — Haiku is the right size.
- **Input:** the drafted reply text, the original tweet text, and the full
  candidate JSON (including any `prospect_match`/`veteran_match` fields and
  their values).
- **Task:** for every player name, team, stat, or specific claim in the
  draft, confirm it traces to either (a) the literal tweet text, or (b) a
  `prospect_*`/`veteran_*` field actually present and non-NA in the
  candidate JSON. This mirrors the grounding checklist already in
  MEMORY.md — this is that checklist enforced by an independent call
  instead of self-review.
- **Tool cap:** max 1 additional lookup per verification run. Allowed
  lookups:
  - one `Rscript` query against the relevant `nfl-draft-model/data/*.rds`
    file or boxscore-prophet `output/latest` slate, if the claim needs
    re-confirming against source data directly, OR
  - one web search, if the claim is a real-world fact outside our model's
    data (e.g. current injury status, a trade that already happened).
  Never both. If one lookup isn't enough to resolve a claim, treat it as
  unverifiable and fail that claim.
- **Output:** structured pass/fail per claim, e.g.
  ```json
  {"pass": false, "failed_claims": ["Cooper Jr. 13% boom rate — not present in candidate JSON, not in tweet text"], "notes": "..."}
  ```

## Handling a FAIL

- If any claim fails: do not surface the draft as-is. Options in order of
  preference:
  1. Strip the unverified claim and re-check the remainder (one retry max).
  2. If stripping guts the reply, return `SKIP` — same behavior as the
     manual grounding rule already documents. Log
     `fact_check: failed_skipped` with the reason.
- Never surface a failed draft to Telegram for Steve's approval as if it
  passed.

## Logging

Append a `fact_check` field to the existing surfacing JSONL record:
`{"fact_check": "passed" | "failed_skipped" | "failed_stripped" | "skipped_no_claims"}`
so this is auditable alongside the existing feedback loop, no new log file
needed.

## Cost estimate

- ~1 Tier-2 candidate/day, skip-gate likely filters some of those to zero
  calls.
- Per verification: ~1.5-2k input tokens (draft + tweet + JSON), ~300-500
  output tokens, plus up to ~1-2k more if a lookup tool fires.
- At Haiku pricing this is fractions of a cent per call — well under $1/month
  at current volume, consistent with the existing Haiku jobs
  (`update-monitor-keywords.sh` is documented at ~$0.001/call).
- Do not silently expand scope beyond Tier 2 — re-evaluate cost explicitly
  if volume or tier scope changes.

## Not in scope for this spec

- Any change to Tier 1A/1B/1C drafting or matching logic.
- Any change to the underlying prospect/veteran matcher (8bd4ca7, bc2466e
  already cover that).
- Auto-editing the draft beyond the single strip-and-retry described above.
