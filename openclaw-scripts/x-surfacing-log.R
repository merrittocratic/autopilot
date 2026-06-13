#!/usr/bin/env Rscript
# ============================================================================
# x-surfacing-log.R -- append a surfacing record to JSONL log
# ============================================================================
# This script does NOT touch Telegram. Telegram I/O is owned by Earnest
# via OpenClaw's routing layer; bypassing that creates a two-poller
# conflict on getUpdates and (per Earnest's incident report) appears to
# also suppress outbound sends from non-OpenClaw senders.
#
# Contract:
#   - After Earnest successfully sends a candidate-with-buttons message
#     to Telegram via OpenClaw, he pipes the surfacing event here as
#     a single JSON document on stdin.
#   - This script appends one JSON line to
#     data/x-monitor-surfacings.jsonl and exits.
#
# Expected stdin shape:
#   {
#     "candidate":  { ...full x-monitor.R candidate JSON... },
#     "draft":      "the drafted reply text",
#     "message_id": 7891
#   }
# ============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(glue)
  library(purrr)
})

HOME_DIR      <- Sys.getenv("HOME")
AUTOPILOT     <- file.path(HOME_DIR, "autopilot")
SURFACING_LOG <- file.path(AUTOPILOT, "data", "x-monitor-surfacings.jsonl")

input <- tryCatch(
  jsonlite::fromJSON(file("stdin"), simplifyVector = FALSE),
  error = function(e) stop("Failed to parse stdin JSON: ", e$message)
)

candidate  <- input$candidate
draft      <- input$draft %||% "(no draft generated)"
message_id <- input$message_id %||% NA

if (is.null(candidate) || is.null(candidate$tweet_id)) {
  stop("Input missing required candidate.tweet_id field")
}

entry <- list(
  timestamp_utc      = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  tweet_id           = candidate$tweet_id,
  username           = candidate$username %||% NA_character_,
  tier               = candidate$tier %||% NA_character_,
  is_cowherd         = candidate$is_cowherd %||% FALSE,
  draft_style        = candidate$draft_style %||% NA_character_,
  draft_prompt_path  = candidate$draft_prompt_path %||% NA_character_,
  reason             = candidate$reason %||% NA_character_,
  engagement_status  = candidate$engagement_status %||% NA_character_,
  can_reply_via_api  = candidate$can_reply_via_api %||% FALSE,
  minutes_old        = candidate$minutes_old %||% NA_real_,
  engagement_per_min = candidate$engagement_per_min %||% NA_real_,
  relevance_score    = candidate$relevance_score %||% 0,
  prospect_match     = candidate$prospect_match %||% FALSE,
  draft              = draft,
  message_id         = message_id
)

dir.create(dirname(SURFACING_LOG), showWarnings = FALSE, recursive = TRUE)
cat(toJSON(entry, auto_unbox = TRUE), "\n", sep = "",
    file = SURFACING_LOG, append = TRUE)

cat(toJSON(list(ok = TRUE), auto_unbox = TRUE))
