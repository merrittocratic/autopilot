#!/usr/bin/env Rscript
# ============================================================================
# x-feedback-poll.R -- Poll Telegram for callback_query updates from the
# inline feedback buttons attached by x-feedback-send.R. For each new
# callback: log the bucket, ACK the callback so Telegram clears the
# button's loading spinner.
# ============================================================================
# Called by a cron job every minute during waking hours. Each run reads
# the offset from the poller state file, requests new updates from
# Telegram's getUpdates endpoint, processes any callback_query events
# whose data starts with "fb:", appends to the feedback log, and writes
# the new offset back to state.
#
# Telegram requires answering a callback_query within ~30 sec or the
# button shows a loading spinner indefinitely. Hence the 1-min cron.
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
FEEDBACK_LOG  <- file.path(AUTOPILOT, "data", "x-monitor-feedback.jsonl")
POLLER_STATE  <- file.path(AUTOPILOT, "data", "x-feedback-poller-state.json")

TG_TOKEN <- Sys.getenv("TELEGRAM_BOT_TOKEN")
if (TG_TOKEN == "") {
  stop("TELEGRAM_BOT_TOKEN not set in environment (autopilot-env.sh)")
}

# Bucket code (single char) -> human-readable label written to the log
BUCKETS <- c(s = "skip", c = "posted_clean", e = "posted_edited")

# --- State -------------------------------------------------------------------

read_state <- function() {
  if (!file.exists(POLLER_STATE)) return(list(last_update_id = 0))
  jsonlite::fromJSON(POLLER_STATE, simplifyVector = FALSE)
}
write_state <- function(state) {
  dir.create(dirname(POLLER_STATE), showWarnings = FALSE, recursive = TRUE)
  writeLines(
    jsonlite::toJSON(state, auto_unbox = TRUE, pretty = TRUE),
    POLLER_STATE
  )
}

ack_callback <- function(cq_id, text = NULL) {
  body <- list(callback_query_id = cq_id)
  if (!is.null(text)) body$text <- text
  tryCatch(
    request(glue("https://api.telegram.org/bot{TG_TOKEN}/answerCallbackQuery")) |>
      req_body_json(body) |>
      req_error(is_error = function(r) FALSE) |>
      req_perform(),
    error = function(e) {
      message("[x-feedback-poll] ACK failed: ", e$message)
      NULL
    }
  )
}

# --- Poll --------------------------------------------------------------------

state  <- read_state()
offset <- (state$last_update_id %||% 0) + 1

resp <- tryCatch(
  request(glue("https://api.telegram.org/bot{TG_TOKEN}/getUpdates")) |>
    req_url_query(
      offset          = offset,
      timeout         = 0,
      allowed_updates = '["callback_query"]'
    ) |>
    req_error(is_error = function(r) FALSE) |>
    req_perform(),
  error = function(e) {
    message("[x-feedback-poll] getUpdates error: ", e$message)
    NULL
  }
)

if (is.null(resp) || resp_status(resp) != 200) {
  status <- if (is.null(resp)) "request_error" else resp_status(resp)
  message("[x-feedback-poll] getUpdates non-200: ", status)
  quit(save = "no", status = 1)
}

payload <- resp_body_json(resp)
updates <- payload$result %||% list()

if (length(updates) == 0) {
  # Nothing to do; do NOT advance offset (Telegram requires offset > update_id
  # only after success, and getUpdates with no result preserves the queue).
  message("[x-feedback-poll] no updates")
  quit(save = "no")
}

dir.create(dirname(FEEDBACK_LOG), showWarnings = FALSE, recursive = TRUE)
max_id    <- state$last_update_id %||% 0
processed <- 0

for (upd in updates) {
  upd_id <- upd$update_id
  if (!is.null(upd_id) && upd_id > max_id) max_id <- upd_id

  cq <- upd$callback_query
  if (is.null(cq)) next

  data <- cq$data %||% ""
  if (!str_starts(data, "fb:")) {
    # Foreign callback (not ours) -- just ACK so the user's button clears
    ack_callback(cq$id)
    next
  }

  parts    <- str_split(data, ":")[[1]]
  if (length(parts) < 3) {
    ack_callback(cq$id, "Malformed feedback data")
    next
  }
  tweet_id <- parts[2]
  bucket_c <- parts[3]
  bucket   <- BUCKETS[[bucket_c]] %||% "unknown"

  entry <- list(
    timestamp_utc = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    tweet_id      = tweet_id,
    bucket        = bucket,
    bucket_code   = bucket_c,
    update_id     = upd_id,
    callback_id   = cq$id,
    message_id    = cq$message$message_id %||% NA_character_,
    chat_id       = cq$message$chat$id %||% NA_character_,
    from_user     = cq$from$username %||% as.character(cq$from$id %||% "")
  )
  cat(toJSON(entry, auto_unbox = TRUE), "\n", sep = "",
      file = FEEDBACK_LOG, append = TRUE)

  toast <- switch(bucket,
    skip          = "Logged: Skip",
    posted_clean  = "Logged: Posted as-is",
    posted_edited = "Logged: Posted with edits",
    paste0("Logged: ", bucket)
  )
  ack_callback(cq$id, toast)

  processed <- processed + 1
}

state$last_update_id <- max_id
write_state(state)

cat("[x-feedback-poll] processed ", processed, " feedback callback(s); ",
    "advanced offset to ", max_id, "\n", sep = "")
