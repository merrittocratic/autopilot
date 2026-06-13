#!/usr/bin/env Rscript
# ============================================================================
# x-feedback-send.R -- Send a candidate + draft to Telegram with feedback
# buttons, and append a surfacing entry to the JSONL log.
# ============================================================================
# Input format (read from stdin as JSON):
#   {"candidate": { ...x-monitor.R candidate object... },
#    "draft":     "the drafted reply text"}
#
# Behavior:
#   1. Format a Telegram message containing the candidate metadata, the
#      tweet text, and the drafted reply.
#   2. Send it via sendMessage with an inline_keyboard markup providing
#      three buttons: Skip, As-is, Edited.
#   3. Append a surfacing record to data/x-monitor-surfacings.jsonl.
#   4. Echo the Telegram message_id to stdout as JSON.
#
# Called by the cron-driven drafting step on the Mac Mini, once per
# candidate, after the reply has been drafted from the tier-specific
# prompt template.
# ============================================================================

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(glue)
  library(stringr)
  library(purrr)
})

HOME_DIR      <- Sys.getenv("HOME")
AUTOPILOT     <- file.path(HOME_DIR, "autopilot")
SURFACING_LOG <- file.path(AUTOPILOT, "data", "x-monitor-surfacings.jsonl")

TG_TOKEN <- Sys.getenv("TELEGRAM_BOT_TOKEN")
TG_CHAT  <- Sys.getenv("TELEGRAM_CHAT_ID", unset = "8676616323")

if (TG_TOKEN == "") {
  stop("TELEGRAM_BOT_TOKEN not set in environment (autopilot-env.sh)")
}

# --- Read stdin --------------------------------------------------------------

input <- tryCatch(
  jsonlite::fromJSON(file("stdin"), simplifyVector = FALSE),
  error = function(e) stop("Failed to parse stdin JSON: ", e$message)
)

candidate <- input$candidate
draft     <- input$draft %||% "(no draft generated)"

if (is.null(candidate) || is.null(candidate$tweet_id)) {
  stop("Input missing required candidate.tweet_id field")
}

# --- Compose message ---------------------------------------------------------
# Plain text (no parse_mode) avoids Markdown escaping landmines when the
# source tweet or draft contains *, _, or backticks.

tier_label  <- candidate$tier %||% "?"
account     <- candidate$username %||% "?"
mins_old    <- candidate$minutes_old %||% NA_real_
eng_per_min <- candidate$engagement_per_min %||% NA_real_
status      <- candidate$engagement_status %||% "?"
reason      <- candidate$reason %||% "?"
style       <- candidate$draft_style %||% "?"

header <- glue(
  "[Tier {tier_label} | {status} | {reason}] @{account} | ",
  "{round(mins_old)}m old | {round(eng_per_min, 1)} eng/min"
)

msg <- glue(
  "{header}\n",
  "Style: {style}\n\n",
  "Their tweet:\n",
  "{candidate$text}\n\n",
  "Draft reply:\n",
  "{draft}"
)

# --- Build inline keyboard ---------------------------------------------------
# callback_data format: "fb:{tweet_id}:{bucket_code}"
# bucket codes: s=skip, c=posted_clean, e=posted_edited
# Total length is well under Telegram's 64-byte callback_data limit
# (tweet IDs are ~19 digits, prefix + bucket adds 5 chars).

tweet_id <- candidate$tweet_id
buttons <- list(
  inline_keyboard = list(
    list(
      list(text = "Skip",   callback_data = glue("fb:{tweet_id}:s")),
      list(text = "As-is",  callback_data = glue("fb:{tweet_id}:c")),
      list(text = "Edited", callback_data = glue("fb:{tweet_id}:e"))
    )
  )
)

# --- Send to Telegram --------------------------------------------------------

resp <- tryCatch(
  request(glue("https://api.telegram.org/bot{TG_TOKEN}/sendMessage")) |>
    req_body_json(list(
      chat_id      = TG_CHAT,
      text         = msg,
      reply_markup = buttons
    )) |>
    req_error(is_error = function(r) FALSE) |>
    req_perform(),
  error = function(e) {
    message("[x-feedback-send] Telegram request error: ", e$message)
    NULL
  }
)

if (is.null(resp) || resp_status(resp) != 200) {
  status_code <- if (is.null(resp)) "request_error" else as.character(resp_status(resp))
  cat(toJSON(list(ok = FALSE, error = status_code), auto_unbox = TRUE))
  quit(save = "no", status = 1)
}

result     <- resp_body_json(resp)
message_id <- result$result$message_id

# --- Append to surfacing log -------------------------------------------------

entry <- list(
  timestamp_utc      = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  tweet_id           = tweet_id,
  username           = account,
  tier               = tier_label,
  is_cowherd         = candidate$is_cowherd %||% FALSE,
  draft_style        = style,
  draft_prompt_path  = candidate$draft_prompt_path %||% NA_character_,
  reason             = reason,
  engagement_status  = status,
  can_reply_via_api  = candidate$can_reply_via_api %||% FALSE,
  minutes_old        = mins_old,
  engagement_per_min = eng_per_min,
  relevance_score    = candidate$relevance_score %||% 0,
  prospect_match     = candidate$prospect_match %||% FALSE,
  draft              = draft,
  message_id         = message_id
)

dir.create(dirname(SURFACING_LOG), showWarnings = FALSE, recursive = TRUE)
cat(toJSON(entry, auto_unbox = TRUE), "\n", sep = "",
    file = SURFACING_LOG, append = TRUE)

cat(toJSON(list(ok = TRUE, message_id = message_id), auto_unbox = TRUE))
