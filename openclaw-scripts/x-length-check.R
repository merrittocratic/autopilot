#!/usr/bin/env Rscript
# ============================================================================
# x-length-check.R -- deterministic character-budget gate for drafted replies
# ============================================================================
# 2026-09-19 -- Initial build. Prompted by a recurring failure across every
#               tier: prompt text says "240 characters is a ceiling, aim for
#               200-240," but gpt-5.4-mini can't reliably count its own
#               output length while generating -- a stronger instruction
#               doesn't close that gap, it's a capability limit, not an
#               attention one. This moves the check outside the model:
#               exact, code-level, no judgment call needed for the ceiling.
#
# This script does NOT touch Telegram and does NOT own the drafting flow.
# Same convention as x-fact-check.R: the OpenClaw-side drafting flow (owned
# by Earnest) calls this at the trigger point -- wherever a draft is about
# to be queued for Telegram, any tier -- and acts on the verdict before
# surfacing anything to Steve.
#
# Contract:
#   stdin (single JSON document):
#     { "draft": "the drafted reply text" }
#
#   stdout (single JSON document):
#     {
#       "length_ok":      true|false,   # FALSE only when over MAX_CHARS
#       "char_count":     172,
#       "max_chars":      240,
#       "over_by":        0,            # chars over MAX_CHARS, 0 if length_ok
#       "notably_short":  false,        # informational only -- never fails the gate
#       "notes":          "one-line summary"
#     }
#
#   The caller is expected to:
#     - Treat length_ok = FALSE as a hard stop: retry the draft with an
#       explicit "shorten to under {max_chars} characters" instruction, or
#       truncate at the last sentence boundary under the limit, or discard.
#       Do NOT surface an over-budget draft as-is.
#     - notably_short is advisory only -- log it, don't block on it. A
#       terse, sharp reply under the target range is not automatically a
#       defect; forcing length would fight the "don't pad" guidance already
#       in every prompt file.
#     - `SKIP` (literal) always passes trivially -- nothing to check.
#
# Scope: all tiers -- this bug wasn't tier-specific.
# ============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(stringr)
})

MAX_CHARS           <- 240   # hard ceiling, matches every x_reply_tier_*.md
NOTABLY_SHORT_CHARS <- 200   # informational only, never fails the gate --
                              # matches the bottom of the "aim for 200-240"
                              # target so a draft like 172 chars (real
                              # observed case, 2026-09-19) actually surfaces
                              # in the log instead of silently passing

input <- tryCatch(
  jsonlite::fromJSON(file("stdin"), simplifyVector = FALSE),
  error = function(e) stop("Failed to parse stdin JSON: ", e$message)
)

draft <- input$draft %||% ""

if (!nzchar(str_trim(draft)) || identical(str_trim(draft), "SKIP")) {
  cat(toJSON(list(
    length_ok = TRUE, char_count = 0, max_chars = MAX_CHARS, over_by = 0,
    notably_short = FALSE, notes = "Empty or SKIP draft -- nothing to check"
  ), auto_unbox = TRUE))
  quit(save = "no")
}

char_count <- nchar(draft, type = "chars")
over_by    <- max(0, char_count - MAX_CHARS)
length_ok  <- over_by == 0
notably_short <- length_ok && char_count < NOTABLY_SHORT_CHARS

notes <- if (!length_ok) {
  sprintf("Draft is %d characters, %d over the %d-character ceiling -- reject, retry, or truncate before surfacing.",
          char_count, over_by, MAX_CHARS)
} else if (notably_short) {
  sprintf("Draft is %d characters, well under the 200-240 target range -- not a hard failure, but worth a glance.",
          char_count)
} else {
  sprintf("Draft is %d characters -- within budget.", char_count)
}

cat(toJSON(list(
  length_ok = length_ok, char_count = char_count, max_chars = MAX_CHARS,
  over_by = over_by, notably_short = notably_short, notes = notes
), auto_unbox = TRUE))
