#!/usr/bin/env Rscript
# ============================================================================
# x-feedback-log.R -- append a feedback bucket record to JSONL log
# ============================================================================
# This script does NOT touch Telegram. Telegram callback_query events
# are routed by OpenClaw to Earnest; Earnest parses the callback_data
# ("fb:{tweet_id}:{bucket_code}"), ACKs via OpenClaw, then pipes the
# parsed event here as a single JSON document on stdin.
#
# Expected stdin shape:
#   {
#     "tweet_id":    "1234567890123456789",
#     "bucket_code": "s",                 // "s" | "c" | "e"
#     "message_id":  7891,                // optional but recommended
#     "chat_id":     "8676616323",        // optional
#     "from_user":   "merrittocratic",    // optional
#     "callback_id": "9483.7284",         // optional (Telegram-side)
#     "update_id":   94837284             // optional (Telegram-side)
#   }
#
# The script accepts either "bucket_code" alone (preferred -- single
# char from the callback_data) or "bucket" (the full label). It writes
# the canonical bucket label to the log.
# ============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(glue)
  library(purrr)
})

HOME_DIR     <- Sys.getenv("HOME")
AUTOPILOT    <- file.path(HOME_DIR, "autopilot")
FEEDBACK_LOG <- file.path(AUTOPILOT, "data", "x-monitor-feedback.jsonl")

# Bucket code (single char) -> human-readable label
BUCKETS <- c(s = "skip", c = "posted_clean", e = "posted_edited")

input <- tryCatch(
  jsonlite::fromJSON(file("stdin"), simplifyVector = FALSE),
  error = function(e) stop("Failed to parse stdin JSON: ", e$message)
)

tweet_id <- input$tweet_id
if (is.null(tweet_id) || tweet_id == "") {
  stop("Input missing required tweet_id field")
}

bucket_code <- input$bucket_code %||% NA_character_
bucket <- if (!is.null(input$bucket)) {
  input$bucket
} else if (!is.na(bucket_code) && bucket_code %in% names(BUCKETS)) {
  BUCKETS[[bucket_code]]
} else {
  "unknown"
}

entry <- list(
  timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  tweet_id      = tweet_id,
  bucket        = bucket,
  bucket_code   = bucket_code,
  update_id     = input$update_id %||% NA,
  callback_id   = input$callback_id %||% NA_character_,
  message_id    = input$message_id %||% NA,
  chat_id       = input$chat_id %||% NA_character_,
  from_user     = input$from_user %||% NA_character_
)

dir.create(dirname(FEEDBACK_LOG), showWarnings = FALSE, recursive = TRUE)
cat(toJSON(entry, auto_unbox = TRUE), "\n", sep = "",
    file = FEEDBACK_LOG, append = TRUE)

cat(toJSON(list(ok = TRUE, bucket = bucket), auto_unbox = TRUE))
