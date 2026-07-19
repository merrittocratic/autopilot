#!/usr/bin/env Rscript
# 2026-07-19: add persistent weekly JSON history tracking for digest metrics.
# x-weekly-digest.R — Weekly X performance digest for @Merrittocratic
# Runs Sunday mornings, delivers summary to Telegram
# Metrics: impressions, likes, retweets, replies, follower delta, top posts

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(stringr)
  library(lubridate)
})

# --- Config ------------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
DRY_RUN <- "--dry-run" %in% args
WRITE_HISTORY <- "--write-history" %in% args

TELEGRAM_BOT_TOKEN <- Sys.getenv("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID   <- Sys.getenv("TELEGRAM_CHAT_ID", "8676616323")
STATE_FILE <- "/Users/merrittocracyclaw/.openclaw/workspace/scripts/x-digest-state.json"
HISTORY_FILE <- "/Users/merrittocracyclaw/.openclaw/workspace/scripts/x-weekly-digest-history.json"
MERRITTOCRATIC_HANDLE <- "Merrittocratic"

# --- OAuth 1.0a (same pattern as x-monitor.R) --------------------------------
build_token <- function() {
  Token1.0$new(
    endpoint = oauth_endpoint(
      request   = "https://api.twitter.com/oauth/request_token",
      authorize = "https://api.twitter.com/oauth/authenticate",
      access    = "https://api.twitter.com/oauth/access_token"
    ),
    app = oauth_app("x", key = Sys.getenv("X_API_KEY"), secret = Sys.getenv("X_API_SECRET")),
    params = list(as_header = TRUE),
    credentials = list(
      oauth_token        = Sys.getenv("X_ACCESS_TOKEN"),
      oauth_token_secret = Sys.getenv("X_ACCESS_SECRET")
    ),
    private_key = NULL
  )
}

# --- Load/save follower state ------------------------------------------------
load_state <- function() {
  if (file.exists(STATE_FILE)) fromJSON(STATE_FILE)
  else list(last_follower_count = NULL, last_run = NULL)
}

save_state <- function(state) {
  write(toJSON(state, auto_unbox = TRUE), STATE_FILE)
}

load_history <- function() {
  if (!file.exists(HISTORY_FILE)) {
    return(list(
      schema = "merrittocracy.x_weekly_digest.v1",
      handle = MERRITTOCRATIC_HANDLE,
      history = list()
    ))
  }

  out <- tryCatch(fromJSON(HISTORY_FILE, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(out) || is.null(out$history)) {
    return(list(
      schema = "merrittocracy.x_weekly_digest.v1",
      handle = MERRITTOCRATIC_HANDLE,
      history = list()
    ))
  }
  out
}

save_history <- function(record) {
  hist <- load_history()
  key <- record$week_end
  existing_keys <- vapply(hist$history, function(x) x$week_end %||% NA_character_, character(1))
  hit <- which(existing_keys == key)

  if (length(hit)) {
    hist$history[[hit[[1]]]] <- record
  } else {
    hist$history[[length(hist$history) + 1]] <- record
  }

  hist$history <- hist$history[order(vapply(hist$history, function(x) x$week_end %||% "", character(1)))]
  write(toJSON(hist, auto_unbox = TRUE, pretty = TRUE), HISTORY_FILE)
}

get_previous_record <- function(week_end) {
  hist <- load_history()
  if (length(hist$history) == 0) return(NULL)

  candidates <- hist$history[vapply(hist$history, function(x) {
    !is.null(x$week_end) && !identical(x$week_end, week_end)
  }, logical(1))]

  if (length(candidates) == 0) return(NULL)

  ordered <- candidates[order(vapply(candidates, function(x) x$week_end %||% "", character(1)))]
  ordered[[length(ordered)]]
}

# --- X API helpers -----------------------------------------------------------
get_user_info <- function(handle, token) {
  resp <- GET(
    paste0("https://api.twitter.com/2/users/by/username/", handle),
    query  = list("user.fields" = "public_metrics"),
    config = config(token = token)
  )
  stop_for_status(resp)
  content(resp)$data
}

get_recent_tweets <- function(user_id, token, days = 7) {
  since <- format(Sys.time() - days(days), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  resp <- GET(
    paste0("https://api.twitter.com/2/users/", user_id, "/tweets"),
    query = list(
      "tweet.fields" = "public_metrics,organic_metrics,created_at,text",
      "max_results"  = 100,
      "start_time"   = since,
      "exclude"      = "retweets"
    ),
    config = config(token = token)
  )
  stop_for_status(resp)
  body <- content(resp)
  if (is.null(body$data)) list() else body$data
}

# --- Telegram ----------------------------------------------------------------
send_telegram <- function(text) {
  resp <- POST(
    paste0("https://api.telegram.org/bot", TELEGRAM_BOT_TOKEN, "/sendMessage"),
    body = list(
      chat_id    = TELEGRAM_CHAT_ID,
      text       = text,
      parse_mode = "HTML"
    ),
    encode = "json"
  )
  stop_for_status(resp)
}

# --- Format helpers ----------------------------------------------------------
fmt <- function(n) {
  if (is.null(n) || is.na(n)) return("—")
  n <- as.numeric(n)
  if (n >= 1000) paste0(round(n / 1000, 1), "k") else as.character(n)
}

delta_str <- function(d) {
  if (is.null(d) || is.na(d)) return("")
  if (d > 0) paste0(" (+", d, ")")
  else if (d < 0) paste0(" (", d, ")")
  else " (±0)"
}

wow_str <- function(current, previous, suffix = "") {
  if (is.null(previous) || is.na(previous)) return(NULL)
  delta <- as.numeric(current) - as.numeric(previous)
  sign <- if (delta > 0) "+" else if (delta < 0) "" else "±"
  paste0(sign, fmt(abs(delta)), suffix)
}

# --- Main --------------------------------------------------------------------
cat("Building OAuth token...\n")
token <- build_token()

cat("Fetching @Merrittocratic profile...\n")
user_info <- tryCatch(get_user_info(MERRITTOCRATIC_HANDLE, token), error = function(e) {
  cat("Error fetching user info:", conditionMessage(e), "\n")
  NULL
})

if (is.null(user_info)) {
  send_telegram("⚠️ Weekly X digest failed — could not fetch @Merrittocratic profile.")
  quit(status = 1)
}

user_id           <- user_info$id
metrics           <- user_info$public_metrics
current_followers <- metrics$followers_count

state <- load_state()
follower_delta <- if (!is.null(state$last_follower_count)) {
  current_followers - as.integer(state$last_follower_count)
} else NA

cat("Fetching tweets from last 7 days...\n")
tweets <- tryCatch(get_recent_tweets(user_id, token, days = 7), error = function(e) {
  cat("Error fetching tweets:", conditionMessage(e), "\n")
  list()
})

# --- Aggregate stats ---------------------------------------------------------
tweet_count <- length(tweets)

if (tweet_count > 0) {
  df <- bind_rows(lapply(tweets, function(t) {
    public  <- t$public_metrics
    organic <- t$organic_metrics
    data.frame(
      text        = t$text,
      impressions = as.numeric(organic$impression_count %||% 0),
      likes       = as.numeric(public$like_count %||% 0),
      retweets    = as.numeric(public$retweet_count %||% 0),
      replies     = as.numeric(public$reply_count %||% 0),
      is_reply    = str_detect(t$text, "^@"),
      stringsAsFactors = FALSE
    )
  }))
  original_count    <- sum(!df$is_reply, na.rm = TRUE)
  reply_count       <- sum(df$is_reply, na.rm = TRUE)
  total_impressions <- sum(df$impressions, na.rm = TRUE)
  total_likes       <- sum(df$likes, na.rm = TRUE)
  total_retweets    <- sum(df$retweets, na.rm = TRUE)
  total_replies     <- sum(df$replies, na.rm = TRUE)
  top_posts         <- df |> arrange(desc(impressions), desc(likes)) |> head(3)
} else {
  original_count <- reply_count <- 0
  total_impressions <- total_likes <- total_retweets <- total_replies <- 0
  top_posts <- data.frame()
}

# --- Build message -----------------------------------------------------------
week_label <- paste0(
  format(Sys.Date() - 7, "%b %d"),
  " – ",
  format(Sys.Date(), "%b %d")
)

msg <- paste0(
  "📊 <b>Weekly X Report — @Merrittocratic</b>\n",
  "<i>", week_label, "</i>\n\n",
  "<b>Followers:</b> ", fmt(current_followers), delta_str(follower_delta), "\n",
  "<b>Posts this week:</b> ", tweet_count,
  " (", original_count, " original, ", reply_count, " replies)\n\n",
  "<b>Totals, including replies</b>\n",
  "  Impressions: ", fmt(total_impressions), "\n",
  "  Likes:       ", fmt(total_likes), "\n",
  "  Retweets:    ", fmt(total_retweets), "\n",
  "  Replies:     ", fmt(total_replies), "\n"
)

top_post_records <- list()
if (nrow(top_posts) > 0) {
  msg <- paste0(msg, "\n<b>Top Posts</b>\n")
  for (i in seq_len(nrow(top_posts))) {
    post <- top_posts[i, ]
    snippet <- str_trunc(post$text, 80, ellipsis = "…")
    snippet <- str_remove_all(snippet, "https://t\\.co/\\S+")
    snippet <- str_trim(snippet)
    top_post_records[[i]] <- list(
      rank = i,
      impressions = as.numeric(post$impressions %||% 0),
      likes = as.numeric(post$likes %||% 0),
      retweets = as.numeric(post$retweets %||% 0),
      replies = as.numeric(post$replies %||% 0),
      is_reply = isTRUE(post$is_reply),
      text = snippet
    )
    msg <- paste0(
      msg,
      i, ". ", fmt(post$impressions), " imp · ", fmt(post$likes), " ❤️\n",
      "   \"", snippet, "\"\n"
    )
  }
}

history_record <- list(
  week_start = as.character(Sys.Date() - 7),
  week_end = as.character(Sys.Date()),
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  handle = MERRITTOCRATIC_HANDLE,
  followers = as.numeric(current_followers %||% NA),
  follower_delta = if (is.na(follower_delta)) NULL else as.numeric(follower_delta),
  posts_total = as.numeric(tweet_count),
  posts_original = as.numeric(original_count),
  posts_replies = as.numeric(reply_count),
  impressions = as.numeric(total_impressions),
  likes = as.numeric(total_likes),
  retweets = as.numeric(total_retweets),
  replies_received = as.numeric(total_replies),
  top_posts = top_post_records
)

previous_week <- get_previous_record(history_record$week_end)
if (!is.null(previous_week)) {
  prev_label <- paste0(previous_week$week_start %||% "?", " – ", previous_week$week_end %||% "?")
  msg <- paste0(
    msg,
    "\n<b>Vs prior week</b>\n",
    "  Impressions: ", wow_str(history_record$impressions, previous_week$impressions), "\n",
    "  Likes:       ", wow_str(history_record$likes, previous_week$likes), "\n",
    "  Posts:       ", wow_str(history_record$posts_total, previous_week$posts_total), "\n",
    "  Followers:   ", wow_str(history_record$followers, previous_week$followers), "\n",
    "  Baseline:    ", prev_label, "\n"
  )
}

msg <- paste0(msg, "\n<i>Next digest: next Sunday 8am ET</i>")

if (DRY_RUN) {
  cat("DRY RUN, not sending Telegram. Message:\n")
  cat(msg, "\n")
} else {
  cat("Sending digest to Telegram...\n")
  tryCatch({
    send_telegram(msg)
    cat("Digest sent successfully.\n")
  }, error = function(e) {
    cat("Error sending:", conditionMessage(e), "\n")
    quit(status = 1)
  })
}

if (!DRY_RUN) {
  save_state(list(
    last_follower_count = current_followers,
    last_run = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  ))
  save_history(history_record)
} else if (WRITE_HISTORY) {
  save_history(history_record)
  cat("History written in dry-run mode.\n")
}
cat("Done.\n")
