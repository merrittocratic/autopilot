#!/usr/bin/env Rscript
# ============================================================================
# x-daily-note.R -- 5pm ET roundup of the day's X conversation, drafted as
# one Substack Note for Steve to edit.
# ============================================================================
# 2026-11-04b -- Voice and facts: uses note_voice_sample.txt (Steve's own
#               short-form posts) and prompts/steve_positions.md, and gives
#               the model web_search (max 3) so numbers get looked up instead
#               of left as [STAT]. Joins all text blocks (citations split
#               them), drops any pre-answer narration, and resumes pause_turn.
# 2026-11-04 -- Scheduled by launchd (deploy/launchd/), not openclaw cron;
#               sends its own plain Telegram message (no buttons, no polling).
# 2026-11-04 -- Initial version.
#
# Reads the per-day tweet cache that x-monitor.R appends to on every scan
# (data/x-daily-cache/YYYY-MM-DD.jsonl), joins in what was already surfaced
# to Steve and his feedback, ranks the day's tweets, and asks Claude to
# cluster them into stories and draft a note on the top one.
#
# Writes the draft to staging/notes/, sends it to Telegram as a plain
# one-way sendMessage (same pattern as morning-sports-digest.R), and prints
# a JSON result on stdout. No reply_markup and no getUpdates -- button flows
# and inbound Telegram stay with Earnest per CLAUDE.md.
#
# Usage:
#   Rscript x-daily-note.R                     # today (ET)
#   Rscript x-daily-note.R --date 2026-11-03   # a specific day's cache
#   Rscript x-daily-note.R --dry-run           # rank + summarize, no API call
#   Rscript x-daily-note.R --no-send           # draft + write file, skip Telegram
#
# stdout (success):
#   {"ok": true, "date": "...", "no_note": false, "path": "...",
#    "n_tweets_cached": N, "n_tweets_sent": N, "n_accounts": N,
#    "message": "<markdown for Telegram>"}
# stdout (nothing to do):  {"ok": false, "reason": "..."}
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(purrr)
  library(glue)
  library(stringr)
})

# --- Config ------------------------------------------------------------------
HOME_DIR      <- Sys.getenv("HOME")
AUTOPILOT     <- file.path(HOME_DIR, "autopilot")
CACHE_DIR     <- file.path(AUTOPILOT, "data", "x-daily-cache")
SURFACING_LOG <- file.path(AUTOPILOT, "data", "x-monitor-surfacings.jsonl")
FEEDBACK_LOG  <- file.path(AUTOPILOT, "data", "x-monitor-feedback.jsonl")
NOTE_VOICE    <- file.path(AUTOPILOT, "data", "voice-sample", "note_voice_sample.txt")
VOICE_SAMPLE  <- file.path(AUTOPILOT, "data", "voice-sample", "voice_sample.txt")  # fallback
POSITIONS     <- file.path(AUTOPILOT, "prompts", "steve_positions.md")
SYSTEM_PROMPT <- file.path(AUTOPILOT, "prompts", "substack_note_daily_system.md")
NOTES_DIR     <- file.path(AUTOPILOT, "staging", "notes")

TZ_LOCAL        <- "America/New_York"
MAX_TWEETS      <- 150  # cap on tweets sent to the model; ranked, not random
CACHE_KEEP_DAYS <- 14   # cache files older than this are pruned each run

MODEL       <- "claude-opus-5-5"
EFFORT      <- "high"
MAX_TOKENS  <- 16000
NO_NOTE     <- "NO_NOTE_TODAY"
# Basic web search, not _20260209: in reply-drafting tests the dynamic-
# filtering version mostly skipped searching.
WEB_SEARCH  <- list(type = "web_search_20250305", name = "web_search", max_uses = 3)
MAX_RESUMES <- 2   # pause_turn continuations

TELEGRAM_CHAT_ID <- Sys.getenv("TELEGRAM_CHAT_ID", "8676616323")
TELEGRAM_MAX     <- 4000  # Telegram caps a message at 4096 chars

args    <- commandArgs(trailingOnly = TRUE)
DRY_RUN <- "--dry-run" %in% args
NO_SEND <- "--no-send" %in% args
day     <- if ("--date" %in% args) {
  args[which(args == "--date") + 1]
} else {
  format(Sys.time(), "%Y-%m-%d", tz = TZ_LOCAL)
}

emit <- function(x) {
  cat(toJSON(x, auto_unbox = TRUE, pretty = TRUE, na = "null"))
  invisible(NULL)
}

# --- Helpers -----------------------------------------------------------------
read_jsonl <- function(path) {
  if (!file.exists(path) || file.size(path) == 0) return(NULL)
  tryCatch(
    jsonlite::stream_in(file(path), verbose = FALSE),
    error = function(e) {
      message("WARN: could not parse ", path, ": ", conditionMessage(e))
      NULL
    }
  )
}

# Plain text, no parse_mode: a stray * or _ in a tweet would otherwise make
# Telegram reject the whole message. Splits on paragraph breaks to stay
# under the length cap.
send_telegram <- function(text) {
  if (NO_SEND) return(invisible(TRUE))
  token <- Sys.getenv("TELEGRAM_BOT_TOKEN")
  if (token == "") {
    message("WARN: TELEGRAM_BOT_TOKEN not set; skipping send")
    return(invisible(FALSE))
  }
  paras  <- str_split(text, "\n\n")[[1]]
  chunks <- character(0)
  cur    <- ""
  for (p in paras) {
    p <- str_trunc(p, TELEGRAM_MAX)
    candidate <- if (cur == "") p else paste(cur, p, sep = "\n\n")
    if (nchar(candidate) > TELEGRAM_MAX) {
      chunks <- c(chunks, cur)
      cur    <- p
    } else {
      cur <- candidate
    }
  }
  if (cur != "") chunks <- c(chunks, cur)

  ok <- TRUE
  for (chunk in chunks) {
    resp <- POST(
      glue("https://api.telegram.org/bot{token}/sendMessage"),
      body   = list(chat_id = TELEGRAM_CHAT_ID, text = chunk,
                    disable_web_page_preview = TRUE),
      encode = "json",
      timeout(30)
    )
    if (status_code(resp) != 200) {
      message("WARN: Telegram send failed with status ", status_code(resp))
      ok <- FALSE
    }
  }
  invisible(ok)
}

prune_cache <- function() {
  files <- list.files(CACHE_DIR, pattern = "^\\d{4}-\\d{2}-\\d{2}\\.jsonl$", full.names = TRUE)
  if (length(files) == 0) return(invisible(NULL))
  file_days <- as.Date(str_remove(basename(files), "\\.jsonl$"))
  cutoff    <- as.Date(format(Sys.time(), "%Y-%m-%d", tz = TZ_LOCAL)) - CACHE_KEEP_DAYS
  old       <- files[file_days < cutoff]
  if (length(old) > 0) file.remove(old)
  invisible(NULL)
}

call_claude <- function(system_text, user_text) {
  key <- Sys.getenv("ANTHROPIC_API_KEY")
  if (key == "") stop("ANTHROPIC_API_KEY is not set")

  messages <- list(list(role = "user", content = user_text))
  out <- NULL
  for (attempt in 0:MAX_RESUMES) {
    body <- list(
      model         = MODEL,
      max_tokens    = MAX_TOKENS,
      output_config = list(effort = EFFORT),
      # Re-routes to another model if a safety classifier declines, instead
      # of returning an empty draft.
      fallbacks     = "default",
      system        = system_text,
      tools         = list(WEB_SEARCH),
      messages      = messages
    )
    resp <- POST(
      "https://api.anthropic.com/v1/messages",
      add_headers(
        "x-api-key"         = key,
        "anthropic-version" = "2023-06-01",
        "anthropic-beta"    = "server-side-fallback-2026-07-01",
        "content-type"      = "application/json"
      ),
      body   = toJSON(body, auto_unbox = TRUE, null = "null"),
      encode = "raw",
      timeout(600)
    )
    if (status_code(resp) != 200) {
      stop(glue("Claude API error {status_code(resp)}: {content(resp, as = 'text', encoding = 'UTF-8')}"))
    }
    out <- content(resp)
    if (identical(out$stop_reason, "refusal")) {
      stop(glue("Claude declined the request (category: {out$stop_details$category %||% 'unknown'})"))
    }
    # The server-side search loop can pause; re-send the assistant turn
    # as-is and it resumes.
    if (!identical(out$stop_reason, "pause_turn")) break
    messages <- c(messages, list(list(role = "assistant", content = out$content)))
  }
  if (identical(out$stop_reason, "pause_turn")) message("WARN: still pause_turn after resumes")
  if (identical(out$stop_reason, "max_tokens")) {
    message("WARN: response hit max_tokens; draft may be truncated")
  }
  searches <- out$usage$server_tool_use$web_search_requests %||% 0
  message(glue("usage: in={out$usage$input_tokens} out={out$usage$output_tokens} searches={searches}"))

  # Only text blocks are the draft. Citations split one answer across many
  # blocks, so join with "" -- a newline would break sentences apart.
  text <- out$content |>
    keep(~ identical(.x$type, "text")) |>
    map_chr(~ .x$text) |>
    paste(collapse = "")
  # Drop any narration before the answer ("Let me check...").
  start <- str_locate(text, "## Draft note|NO_NOTE_TODAY")[1, "start"]
  if (!is.na(start)) text <- str_sub(text, start)
  str_trim(text)
}

# --- Load the day's cache ----------------------------------------------------
prune_cache()

cache_path <- file.path(CACHE_DIR, paste0(day, ".jsonl"))
raw        <- read_jsonl(cache_path)
if (is.null(raw) || nrow(raw) == 0) {
  # An empty cache at 5pm means x-monitor didn't run today -- worth a ping.
  if (!DRY_RUN) send_telegram(glue("x-daily-note: no X cache for {day}. Check that x-monitor ran today."))
  emit(list(ok = FALSE, date = day, reason = glue("no cache at {cache_path}")))
  quit(save = "no", status = 0)
}

# Each scan re-reads overlapping windows, so a tweet appears many times;
# the last line has the freshest engagement counts.
tweets <- raw |>
  mutate(tweet_id = as.character(tweet_id)) |>
  group_by(tweet_id) |>
  slice_tail(n = 1) |>
  ungroup() |>
  filter(is.na(reason) | reason != "skip_topic")

n_cached <- nrow(tweets)
if (n_cached == 0) {
  emit(list(ok = FALSE, date = day, reason = "cache had no usable tweets"))
  quit(save = "no", status = 0)
}

# --- Join surfacing + feedback -----------------------------------------------
surfacings <- read_jsonl(SURFACING_LOG)
surfaced_ids <- if (!is.null(surfacings)) as.character(surfacings$tweet_id) else character(0)

feedback <- read_jsonl(FEEDBACK_LOG)
feedback_by_id <- if (!is.null(feedback) && nrow(feedback) > 0) {
  feedback |>
    mutate(tweet_id = as.character(tweet_id)) |>
    group_by(tweet_id) |>
    slice_tail(n = 1) |>
    ungroup() |>
    select(tweet_id, feedback = bucket)
} else {
  tibble(tweet_id = character(0), feedback = character(0))
}

# --- Rank --------------------------------------------------------------------
# Engagement on a log scale so one viral Schefter post doesn't drown out
# everything; relevance and model matches add the Merrittocracy angle.
num0 <- function(x) coalesce(as.numeric(x), 0)

ranked <- tweets |>
  left_join(feedback_by_id, by = "tweet_id") |>
  mutate(
    surfaced   = tweet_id %in% surfaced_ids,
    engagement = num0(likes) + 2 * num0(retweets) + num0(replies),
    any_match  = coalesce(prospect_match, FALSE) | coalesce(veteran_match, FALSE) |
                 coalesce(cfb_match, FALSE) | coalesce(golf_match, FALSE),
    rank_score = log1p(engagement) + 1.5 * pmax(num0(relevance_score), 0) + 1.0 * any_match,
    url        = glue("https://x.com/{username}/status/{tweet_id}")
  ) |>
  arrange(desc(rank_score))

sent <- ranked |> slice_head(n = MAX_TWEETS)
n_accounts <- n_distinct(ranked$username)

if (DRY_RUN) {
  emit(list(
    ok = TRUE, dry_run = TRUE, date = day,
    n_tweets_cached = n_cached, n_tweets_sent = nrow(sent), n_accounts = n_accounts,
    n_surfaced = sum(ranked$surfaced),
    top_10 = sent |>
      slice_head(n = 10) |>
      transmute(username, likes, retweets, rank_score = round(rank_score, 2),
                text = str_trunc(text, 120))
  ))
  quit(save = "no", status = 0)
}

# --- Draft -------------------------------------------------------------------
read_text <- function(path) {
  if (file.exists(path)) paste(readLines(path, warn = FALSE), collapse = "\n") else ""
}
voice_sample <- read_text(NOTE_VOICE)
if (!nzchar(voice_sample)) {
  message("WARN: ", basename(NOTE_VOICE), " missing; falling back to ", basename(VOICE_SAMPLE))
  voice_sample <- read_text(VOICE_SAMPLE)
}

payload <- list(
  date   = day,
  tweets = sent |>
    transmute(username, tier, created_at, text, quoted_text,
              likes, retweets, replies, url, relevance_score,
              prospect_match, veteran_match, cfb_match, golf_match,
              matched_article_slug, surfaced, feedback),
  steve_positions = read_text(POSITIONS),
  voice_sample    = voice_sample
)

system_text <- paste(readLines(SYSTEM_PROMPT, warn = FALSE), collapse = "\n")
user_text   <- toJSON(payload, auto_unbox = TRUE, na = "null", dataframe = "rows")

draft   <- call_claude(system_text, user_text)
no_note <- str_detect(draft, fixed(NO_NOTE))

dir.create(NOTES_DIR, showWarnings = FALSE, recursive = TRUE)
note_path <- file.path(NOTES_DIR, glue("{day}_daily_note.md"))
writeLines(
  c(glue("# Daily note draft -- {day}"),
    glue("_{n_cached} tweets from {n_accounts} accounts; top {nrow(sent)} sent to {MODEL}._"),
    "",
    draft),
  note_path
)

header <- if (no_note) {
  glue("Daily X roundup ({day}): quiet day, no note drafted. Runners-up below.")
} else {
  glue("Daily Substack Note draft ({day}), from {n_cached} tweets across {n_accounts} accounts:")
}

message_text <- paste(header, draft, sep = "\n\n")
sent_ok      <- send_telegram(message_text)

emit(list(
  ok              = TRUE,
  date            = day,
  no_note         = no_note,
  telegram_sent   = !NO_SEND && isTRUE(sent_ok),
  path            = note_path,
  n_tweets_cached = n_cached,
  n_tweets_sent   = nrow(sent),
  n_accounts      = n_accounts,
  message         = message_text
))
