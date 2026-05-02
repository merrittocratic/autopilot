#!/usr/bin/env Rscript
# ============================================================================
# draft-expiry-nudge.R — Ping Steve when tweet drafts sit pending too long
# ============================================================================
# Groups pending drafts by article. Sends a Telegram nudge for any article
# batch that's been pending >24h AND hasn't been nudged in the past 24h.
#
# Usage:
#   Rscript draft-expiry-nudge.R              # standard run
#   Rscript draft-expiry-nudge.R --dry-run    # print to console, no Telegram
#   Rscript draft-expiry-nudge.R --force      # ignore re-nudge cooldown
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(googlesheets4)
  library(dplyr)
  library(jsonlite)
  library(glue)
  library(here)
})

# --- Args --------------------------------------------------------------------

args    <- commandArgs(trailingOnly = TRUE)
DRY_RUN <- "--dry-run" %in% args
FORCE   <- "--force"   %in% args

# --- Config ------------------------------------------------------------------

STALE_HOURS     <- 24   # hours before a draft is considered overdue
RENUDGE_HOURS   <- 24   # minimum hours between nudges for the same article
TELEGRAM_CHAT   <- "8676616323"
STATE_FILE      <- "/Users/merrittocracyclaw/.openclaw/workspace/memory/draft-nudge-state.json"
GOOGLE_SA_KEY   <- here::here(".secrets", "google-service-account.json")
REVIEW_SHEET_ID <- Sys.getenv("REVIEW_SHEET_ID", unset = "1-AP273mLlwwmf2sWSE32a7D6ZQzT2J2zwjPdVTnCjSw")

# --- Secrets -----------------------------------------------------------------

for (s in c("TELEGRAM_BOT_TOKEN")) {
  val <- system(paste0("security find-generic-password -s autopilot -a ", s, " -w 2>/dev/null"), intern = TRUE)
  if (length(val) > 0 && nchar(val[1]) > 0) do.call(Sys.setenv, setNames(list(val[1]), s))
}

TELEGRAM_BOT_TOKEN <- Sys.getenv("TELEGRAM_BOT_TOKEN")

# --- State -------------------------------------------------------------------

load_state <- function() {
  if (!file.exists(STATE_FILE)) return(list())
  tryCatch(fromJSON(STATE_FILE), error = function(e) list())
}

save_state <- function(state) {
  dir.create(dirname(STATE_FILE), recursive = TRUE, showWarnings = FALSE)
  write(toJSON(state, auto_unbox = TRUE), STATE_FILE)
}

last_nudge_time <- function(state, post_id) {
  t <- state[[post_id]]
  if (is.null(t)) return(as.POSIXct(0, origin = "1970-01-01", tz = "UTC"))
  as.POSIXct(t, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

# --- Google Sheets -----------------------------------------------------------

fetch_pending_drafts <- function() {
  gs4_auth(path = GOOGLE_SA_KEY)
  queue <- read_sheet(REVIEW_SHEET_ID, sheet = "queue")
  queue %>%
    filter(status == "pending") %>%
    select(post_id, title, post_link, tweet_number, tweet_text, created_at)
}

# --- Overdue detection -------------------------------------------------------

parse_created_at <- function(ts_str) {
  # Handle ISO 8601 with offset like "2026-04-25T18:20:53-0400"
  tryCatch(
    as.POSIXct(ts_str, format = "%Y-%m-%dT%H:%M:%S%z", tz = "UTC"),
    error = function(e) NA
  )
}

hours_pending <- function(created_at_str) {
  t <- parse_created_at(created_at_str)
  if (is.na(t)) return(NA_real_)
  as.numeric(difftime(Sys.time(), t, units = "hours"))
}

# --- Telegram ----------------------------------------------------------------

send_telegram <- function(message) {
  r <- POST(
    glue("https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"),
    body = list(
      chat_id    = TELEGRAM_CHAT,
      text       = message,
      parse_mode = "Markdown"
    ),
    encode = "json"
  )
  if (status_code(r) == 200) {
    cat("  ✅ Sent to Telegram\n")
    return(TRUE)
  } else {
    cat("  ❌ Telegram failed:", status_code(r), "\n")
    cat("  ", rawToChar(r$content), "\n")
    return(FALSE)
  }
}

# --- Message formatting ------------------------------------------------------

format_age <- function(hours) {
  if (hours < 48) return(glue("{round(hours)}h"))
  days <- floor(hours / 24)
  glue("{days}d")
}

build_nudge <- function(post_id, title, post_link, tweet1_text, age_hours, n_tweets) {
  age_str <- format_age(age_hours)
  preview <- if (nchar(tweet1_text) > 100) paste0(substr(tweet1_text, 1, 97), "...") else tweet1_text

  glue(
    "⏰ *Stale draft — {age_str} pending*\n",
    "\n",
    "*{title}*\n",
    "{n_tweets} tweet{if (n_tweets > 1) 's' else ''} waiting for review\n",
    "\n",
    "_{preview}_\n",
    "\n",
    "📎 {post_link}"
  )
}

# --- Main --------------------------------------------------------------------

cat("=== Draft Expiry Nudge ===\n")
cat("Run time:", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "\n\n")

# Load state
state <- load_state()

# Fetch pending drafts
cat("Fetching pending drafts from Google Sheet...\n")
pending <- tryCatch(fetch_pending_drafts(), error = function(e) {
  cat("ERROR reading sheet:", e$message, "\n")
  quit(status = 1)
})

if (nrow(pending) == 0) {
  cat("No pending drafts. All clear.\n")
  quit(save = "no")
}

cat("Found", nrow(pending), "pending tweet(s) across",
    length(unique(pending$post_id)), "article(s)\n\n")

# Group by article, find oldest tweet (tweet 1 is always the reference)
articles <- pending %>%
  group_by(post_id, title, post_link) %>%
  summarise(
    n_tweets   = n(),
    tweet1     = tweet_text[tweet_number == min(tweet_number)][1],
    created_at = created_at[tweet_number == min(tweet_number)][1],
    .groups = "drop"
  ) %>%
  mutate(
    age_hours = vapply(created_at, hours_pending, numeric(1))
  ) %>%
  filter(!is.na(age_hours))

# Apply thresholds
now        <- Sys.time()
nudge_sent <- FALSE

for (i in seq_len(nrow(articles))) {
  row      <- articles[i, ]
  post_id  <- row$post_id
  age_h    <- row$age_hours

  if (age_h < STALE_HOURS) {
    cat(glue("[SKIP] {post_id}: only {round(age_h)}h old (threshold: {STALE_HOURS}h)\n\n"))
    next
  }

  last_nudge  <- last_nudge_time(state, post_id)
  hours_since <- as.numeric(difftime(now, last_nudge, units = "hours"))

  if (!FORCE && hours_since < RENUDGE_HOURS) {
    cat(glue("[SKIP] {post_id}: nudged {round(hours_since)}h ago (cooldown: {RENUDGE_HOURS}h)\n\n"))
    next
  }

  msg <- build_nudge(
    post_id   = post_id,
    title     = row$title,
    post_link = row$post_link,
    tweet1    = row$tweet1,
    age_hours = age_h,
    n_tweets  = row$n_tweets
  )

  cat(glue("[NUDGE] {post_id} ({format_age(age_h)} pending)\n"))
  cat(msg, "\n\n")

  if (DRY_RUN) {
    cat("[DRY RUN] Skipping Telegram send.\n\n")
    nudge_sent <- TRUE
  } else {
    ok <- send_telegram(msg)
    if (ok) {
      state[[post_id]] <- format(now, "%Y-%m-%dT%H:%M:%SZ")
      nudge_sent       <- TRUE
    }
  }
}

if (!DRY_RUN && nudge_sent) {
  save_state(state)
  cat("\nState saved.\n")
} else if (!nudge_sent) {
  cat("No nudges needed this run.\n")
}

cat("\nDone.\n")
