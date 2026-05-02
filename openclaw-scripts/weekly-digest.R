#!/usr/bin/env Rscript
# ============================================================================
# weekly-digest.R — Weekly X performance digest for @Merrittocratic
# ============================================================================
# Pulls last 7 days of tweets + metrics, compares follower count to prior week,
# formats a clean summary, and sends to Steve via Telegram.
#
# Usage:
#   Rscript weekly-digest.R              # standard weekly run
#   Rscript weekly-digest.R --dry-run    # print to console only, no Telegram
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(stringr)
  library(purrr)
  library(glue)
})

# --- Args --------------------------------------------------------------------

args       <- commandArgs(trailingOnly = TRUE)
DRY_RUN    <- "--dry-run" %in% args

# --- Secrets -----------------------------------------------------------------

load_secrets <- function() {
  secrets <- c("X_API_KEY", "X_API_SECRET", "X_ACCESS_TOKEN", "X_ACCESS_SECRET",
                "X_BEARER_TOKEN", "TELEGRAM_BOT_TOKEN")
  for (s in secrets) {
    val <- system(
      paste0("security find-generic-password -s autopilot -a ", s, " -w 2>/dev/null"),
      intern = TRUE
    )
    if (length(val) > 0 && nchar(val[1]) > 0) {
      do.call(Sys.setenv, setNames(list(val[1]), s))
    }
  }
}

load_secrets()

TELEGRAM_BOT_TOKEN <- Sys.getenv("TELEGRAM_BOT_TOKEN")
TELEGRAM_CHAT_ID   <- "8676616323"  # Steve's chat ID
USER_ID            <- "2034348190154334208"  # @Merrittocratic
STATE_FILE         <- "/Users/merrittocracyclaw/.openclaw/workspace/memory/weekly-digest-state.json"

# --- Auth --------------------------------------------------------------------

build_token <- function() {
  Token1.0$new(
    endpoint = oauth_endpoint(
      request   = "https://api.twitter.com/oauth/request_token",
      authorize = "https://api.twitter.com/oauth/authenticate",
      access    = "https://api.twitter.com/oauth/access_token"
    ),
    app = oauth_app("x",
      key    = Sys.getenv("X_API_KEY"),
      secret = Sys.getenv("X_API_SECRET")
    ),
    credentials = list(
      oauth_token        = Sys.getenv("X_ACCESS_TOKEN"),
      oauth_token_secret = Sys.getenv("X_ACCESS_SECRET")
    ),
    params = list(as_header = TRUE)
  )
}

# --- State (follower tracking) -----------------------------------------------

load_state <- function() {
  if (!file.exists(STATE_FILE)) return(list(last_followers = NA_integer_, last_run = NA_character_))
  tryCatch(fromJSON(STATE_FILE), error = function(e) list(last_followers = NA_integer_, last_run = NA_character_))
}

save_state <- function(followers_count) {
  dir.create(dirname(STATE_FILE), recursive = TRUE, showWarnings = FALSE)
  write(toJSON(list(
    last_followers = followers_count,
    last_run       = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
  ), auto_unbox = TRUE), STATE_FILE)
}

# --- X API helpers -----------------------------------------------------------

x_get <- function(url, query = list(), token) {
  r <- GET(url, query = query, config(token = token))
  if (status_code(r) != 200) {
    cat("[WARN] X API returned", status_code(r), "for", url, "\n")
    cat(rawToChar(r$content), "\n")
    return(NULL)
  }
  fromJSON(rawToChar(r$content), flatten = TRUE)
}

fetch_user_metrics <- function(token) {
  resp <- x_get(
    paste0("https://api.twitter.com/2/users/", USER_ID),
    query = list("user.fields" = "public_metrics"),
    token = token
  )
  resp$data$public_metrics
}

fetch_weekly_tweets <- function(token) {
  start_time <- format(Sys.time() - 7 * 24 * 3600, "%Y-%m-%dT%H:%M:%SZ")
  tweets_all <- list()
  next_token_val <- NULL

  repeat {
    q <- list(
      max_results  = 100,
      "tweet.fields" = "public_metrics,organic_metrics,created_at,text,referenced_tweets",
      start_time   = start_time
    )
    if (!is.null(next_token_val)) q$pagination_token <- next_token_val

    resp <- x_get(
      paste0("https://api.twitter.com/2/users/", USER_ID, "/tweets"),
      query = q,
      token = token
    )

    if (is.null(resp) || is.null(resp$data)) break

    # Normalize to list of rows
    rows <- tryCatch(as.data.frame(resp$data), error = function(e) NULL)
    if (!is.null(rows)) tweets_all <- c(tweets_all, list(rows))

    if (!is.null(resp$meta$next_token) && length(resp$meta$next_token) > 0) {
      next_token_val <- resp$meta$next_token
    } else {
      break
    }
  }

  if (length(tweets_all) == 0) return(NULL)
  bind_rows(tweets_all)
}

# --- Digest formatting -------------------------------------------------------

format_number <- function(n) {
  if (is.na(n) || is.null(n)) return("—")
  if (n >= 1000) paste0(round(n / 1000, 1), "k") else as.character(n)
}

truncate_text <- function(text, max_chars = 80) {
  if (nchar(text) <= max_chars) return(text)
  paste0(substr(text, 1, max_chars - 3), "...")
}

build_digest_message <- function(tweets_df, user_metrics, state) {
  week_end   <- format(Sys.Date(), "%b %d")
  week_start <- format(Sys.Date() - 7, "%b %d")

  # Follower delta
  current_followers <- user_metrics$followers_count %||% 0
  follower_delta    <- if (!is.na(state$last_followers)) {
    current_followers - as.integer(state$last_followers)
  } else NA_integer_

  follower_line <- if (!is.na(follower_delta)) {
    sign_str <- if (follower_delta >= 0) paste0("+", follower_delta) else as.character(follower_delta)
    glue("Followers: {current_followers} ({sign_str} this week)")
  } else {
    glue("Followers: {current_followers}")
  }

  # Aggregate tweet stats — exclude replies for main metrics
  if (is.null(tweets_df) || nrow(tweets_df) == 0) {
    return(glue(
      "📊 *Weekly X Digest* ({week_start}–{week_end})\n\n",
      "No tweets found in the past 7 days.\n\n",
      "{follower_line}"
    ))
  }

  # Pull metrics columns safely
  get_metric <- function(df, col) {
    if (col %in% names(df)) as.integer(df[[col]]) else rep(0L, nrow(df))
  }

  tweets_df <- tweets_df %>%
    mutate(
      impressions  = get_metric(., "organic_metrics.impression_count"),
      likes        = get_metric(., "public_metrics.like_count"),
      retweets     = get_metric(., "public_metrics.retweet_count"),
      replies      = get_metric(., "public_metrics.reply_count"),
      link_clicks  = get_metric(., "organic_metrics.url_link_clicks"),
      is_reply     = str_detect(text, "^@")
    )

  original_tweets <- tweets_df %>% filter(!is_reply)
  all_tweets_n    <- nrow(tweets_df)
  original_n      <- nrow(original_tweets)

  total_impressions <- sum(tweets_df$impressions, na.rm = TRUE)
  total_likes       <- sum(tweets_df$likes, na.rm = TRUE)
  total_retweets    <- sum(tweets_df$retweets, na.rm = TRUE)
  total_link_clicks <- sum(tweets_df$link_clicks, na.rm = TRUE)

  # Top post by impressions
  top_tweet <- tweets_df %>% arrange(desc(impressions)) %>% slice(1)
  top_text  <- truncate_text(top_tweet$text[1])
  top_imp   <- top_tweet$impressions[1]
  top_likes <- top_tweet$likes[1]

  # Engagement rate (likes+RTs / impressions)
  eng_rate <- if (total_impressions > 0) {
    sprintf("%.1f%%", 100 * (total_likes + total_retweets) / total_impressions)
  } else "—"

  glue(
    "📊 *Weekly X Digest* ({week_start}–{week_end})\n",
    "\n",
    "📝 *Posts:* {all_tweets_n} total ({original_n} original, {all_tweets_n - original_n} replies)\n",
    "👁 *Impressions:* {format_number(total_impressions)}\n",
    "❤️ *Likes:* {total_likes}   🔁 *Retweets:* {total_retweets}\n",
    "🔗 *Link clicks:* {total_link_clicks}\n",
    "📈 *Engagement rate:* {eng_rate}\n",
    "\n",
    "🏆 *Top post* ({format_number(top_imp)} impressions, {top_likes} ❤️):\n",
    "_{top_text}_\n",
    "\n",
    "👥 {follower_line}"
  )
}

# R doesn't have %||% built-in outside of rlang
`%||%` <- function(x, y) if (!is.null(x) && !is.na(x)) x else y

# --- Telegram send -----------------------------------------------------------

send_telegram <- function(message) {
  r <- POST(
    glue("https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"),
    body = list(
      chat_id    = TELEGRAM_CHAT_ID,
      text       = message,
      parse_mode = "Markdown"
    ),
    encode = "json"
  )
  if (status_code(r) == 200) {
    cat("✅ Digest sent to Telegram\n")
  } else {
    cat("❌ Telegram send failed:", status_code(r), "\n")
    cat(rawToChar(r$content), "\n")
  }
}

# --- Main --------------------------------------------------------------------

cat("=== Weekly X Digest ===\n")
cat("Run time:", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), "\n\n")

state <- load_state()
token <- build_token()

cat("Fetching user metrics...\n")
user_metrics <- fetch_user_metrics(token)
cat("  Followers:", user_metrics$followers_count, "\n")

cat("Fetching weekly tweets...\n")
tweets_df <- fetch_weekly_tweets(token)
if (!is.null(tweets_df)) {
  cat("  Found", nrow(tweets_df), "tweets in the past 7 days\n")
} else {
  cat("  No tweets found\n")
}

message <- build_digest_message(tweets_df, user_metrics, state)

cat("\n--- Digest Preview ---\n")
cat(message, "\n")
cat("----------------------\n\n")

if (DRY_RUN) {
  cat("[DRY RUN] Skipping Telegram send.\n")
} else {
  cat("Sending to Telegram...\n")
  send_telegram(message)
  save_state(user_metrics$followers_count)
  cat("State saved.\n")
}

cat("\nDone.\n")
