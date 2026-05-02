#!/usr/bin/env Rscript
# ============================================================================
# Morning Sports Digest — Pull @ESPN + @FoxSports results, send to Telegram
# ============================================================================
# Runs at 6:00am ET via cron. Fetches previous day's tweets from ESPN and
# FoxSports, filters for NBA/NFL/Golf, counts player mentions across both
# feeds to pick a consensus Star of the Night, then sends digest to Telegram.
#
# Usage: Rscript morning-sports-digest.R [--dry-run]
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(stringr)
  library(purrr)
  library(glue)
  library(lubridate)
})

# --- Config ------------------------------------------------------------------

TELEGRAM_CHAT   <- "8676616323"
# Sport-specific accounts for better signal
# NBA: ESPN + Bleacher Report (FOX has no dedicated NBA account)
# NFL: ESPN + FOX Sports NFL
# Golf: ESPN Golf + FOX Sports Golf
SOURCE_ACCOUNTS <- list(
  NBA  = c("ESPNNba",  "BleacherReport"),
  NFL  = c("ESPNNFL",  "FoxSportsNFL"),
  Golf = c("ESPNGolf", "FoxSportsGolf")
)
ALL_ACCOUNTS <- unique(unlist(SOURCE_ACCOUNTS))
MAX_TWEETS      <- 50   # per account

# Required secrets
for (s in c("ANTHROPIC_API_KEY", "TELEGRAM_BOT_TOKEN", "X_API_KEY", "X_API_SECRET", "X_ACCESS_TOKEN", "X_ACCESS_SECRET")) {
  if (Sys.getenv(s) == "") stop(glue("Missing required secret: {s}"))
}
ANTHROPIC_KEY       <- Sys.getenv("ANTHROPIC_API_KEY")
TELEGRAM_BOT_TOKEN  <- Sys.getenv("TELEGRAM_BOT_TOKEN")

# Dry run: print to console instead of sending Telegram
args    <- commandArgs(trailingOnly = TRUE)
dry_run <- "--dry-run" %in% args

# --- Sport keyword filters ---------------------------------------------------

NBA_KEYWORDS  <- c("nba", "lakers", "celtics", "warriors", "bucks", "heat",
                   "knicks", "bulls", "nets", "76ers", "raptors", "nuggets",
                   "suns", "clippers", "mavericks", "rockets", "timberwolves",
                   "thunder", "grizzlies", "pelicans", "spurs", "jazz",
                   "kings", "trail blazers", "magic", "pacers", "pistons",
                   "cavaliers", "hawks", "hornets", "wizards",
                   "playoffs", "finals", "game [0-9]", "overtime", "triple.double")

NFL_KEYWORDS  <- c("nfl", "trade", "signed", "released", "contract",
                   "free agent", "quarterback", "wide receiver", "running back",
                   "offensive line", "defensive", "head coach", "gm ", "draft pick",
                   "bears", "packers", "vikings", "lions", "falcons", "panthers",
                   "saints", "buccaneers", "cowboys", "giants", "eagles",
                   "commanders", "49ers", "seahawks", "rams", "cardinals",
                   "chiefs", "raiders", "chargers", "broncos", "bills",
                   "dolphins", "patriots", "jets", "ravens", "bengals",
                   "browns", "steelers", "texans", "colts", "jaguars", "titans")

GOLF_KEYWORDS <- c("golf", "pga", "masters", "open championship", "us open",
                   "pga championship", "ryder cup", "presidents cup",
                   "liv golf", "birdie", "eagle", "under par", "leaderboard",
                   "mcilroy", "scheffler", "woods", "mickelson", "spieth",
                   "thomas", "cantlay", "morikawa", "matsuyama", "lowry",
                   "rahm", "fleetwood", "homa", "burns", "harman",
                   "round [0-9]", "final round", "cut", "course record")

# --- X API helpers (OAuth 1.0a) ----------------------------------------------

build_oauth_token <- function() {
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
    params = list(as_header = TRUE),
    credentials = list(
      oauth_token        = Sys.getenv("X_ACCESS_TOKEN"),
      oauth_token_secret = Sys.getenv("X_ACCESS_SECRET")
    ),
    private_key = NULL
  )
}

resolve_user_id <- function(username, token) {
  resp <- GET(
    glue("https://api.twitter.com/2/users/by/username/{username}"),
    config = config(token = token)
  )
  if (status_code(resp) != 200) stop(glue("Failed to resolve @{username}: {status_code(resp)}"))
  content(resp)$data$id
}

fetch_user_tweets_yesterday <- function(user_id, username, token) {
  # Calculate yesterday midnight→midnight in ET
  et_now   <- with_tz(Sys.time(), "America/New_York")
  et_today <- floor_date(et_now, "day")
  et_start <- et_today - days(1)
  et_end   <- et_today

  utc_start <- format(with_tz(et_start, "UTC"), "%Y-%m-%dT%H:%M:%SZ")
  utc_end   <- format(with_tz(et_end,   "UTC"), "%Y-%m-%dT%H:%M:%SZ")

  resp <- GET(
    glue("https://api.twitter.com/2/users/{user_id}/tweets"),
    config = config(token = token),
    query = list(
      max_results    = as.character(MAX_TWEETS),
      start_time     = utc_start,
      end_time       = utc_end,
      "tweet.fields" = "created_at,text,public_metrics",
      exclude        = "replies"
    )
  )

  if (status_code(resp) != 200) {
    warning(glue("Failed to fetch tweets for @{username}: {status_code(resp)}"))
    return(list())
  }

  data <- content(resp)$data
  if (is.null(data)) return(list())

  map(data, ~ {
    # Tag tweets by time-of-day in ET for weighting
    # X API returns timestamps with milliseconds e.g. "2026-05-01T22:30:00.000Z"
    ts_clean  <- sub("\\.\\d+Z$", "Z", .x$created_at)  # strip milliseconds
    tweet_utc <- as.POSIXct(ts_clean, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    tweet_et  <- with_tz(tweet_utc, "America/New_York")
    hour_et   <- as.integer(format(tweet_et, "%H"))
    # Prime time = 9pm–2am ET (games wrapping up, live results window)
    # 6pm-9pm catches too much prior-day reaction/recap content
    prime_time <- hour_et >= 21 || hour_et < 2
    list(
      id         = .x$id,
      text       = .x$text,
      source     = username,
      likes      = .x$public_metrics$like_count    %||% 0,
      retweets   = .x$public_metrics$retweet_count %||% 0,
      hour_et    = hour_et,
      prime_time = prime_time
    )
  })
}

# --- Sport classification ----------------------------------------------------

classify_sport <- function(text) {
  t <- str_to_lower(text)
  sports <- character(0)
  if (any(str_detect(t, NBA_KEYWORDS)))  sports <- c(sports, "NBA")
  if (any(str_detect(t, NFL_KEYWORDS)))  sports <- c(sports, "NFL")
  if (any(str_detect(t, GOLF_KEYWORDS))) sports <- c(sports, "Golf")
  if (length(sports) == 0) return(NA_character_)
  paste(sports, collapse = "/")
}

# --- Build tweet bundle for Claude -------------------------------------------

format_tweet_bundle <- function(tweets) {
  map_chr(tweets, function(tw) {
    time_tag    <- if (isTRUE(tw$prime_time)) "[PRIME]" else "[DAY]"
    engagement  <- tw$likes + tw$retweets
    glue("{time_tag}[{tw$hour_et}h ET][eng:{engagement}] [{tw$source}] {tw$text}")
  }) |> paste(collapse = "\n\n")
}

# --- Call Claude to synthesize digest ----------------------------------------

call_claude <- function(tweet_bundle, date_label) {
  prompt <- glue(
    "You are Earnest, an AI sports digest for TheMerrittocracy. ",
    "Based on the following tweets from @ESPNNba, @ESPNNFL, @ESPNGolf, @BleacherReport, @FoxSportsNFL, and @FoxSportsGolf from {date_label}, ",
    "create a concise morning sports digest for Steve.\n\n",
    "Instructions:\n",
    "1. Summarize key results/news for each sport present: NBA, NFL, Golf.\n",
    "   - NBA: scores, standout performances, series status if in playoffs\n",
    "   - NFL: notable trades, signings, releases, transactions\n",
    "   - Golf: leaderboard, round results, or tournament news\n",
    "2. IMPORTANT — Tweet timing context:\n",
    "   - Tweets are tagged [PRIME][Xh ET] (posted 9pm-2am ET, games wrapping up) or [DAY][Xh ET] (prior-day analysis/reaction)\n",
    "   - PRIORITIZE [PRIME] tweets for game results and the Star of the Night pick\n",
    "   - [DAY] tweets are background context only — do NOT use them to pick the Star\n",
    "   - If a player only appears in [DAY] tweets, they are NOT eligible for Star of the Night\n",
    "   - A player mentioned heavily at 6-8pm ET is likely yesterday's story, not last night's — ignore for Star\n",
    "3. Identify the STAR OF THE NIGHT using this logic:\n",
    "   - Only consider players mentioned in [PRIME] tweets (9pm-2am ET)\n",
    "   - USE ENGAGEMENT (likes + retweets) as the primary signal, NOT mention count\n",
    "   - Find the highest-engagement [PRIME] tweets and identify the player they feature\n",
    "   - A game-winner, big performance, or clutch moment will generate far more engagement than analysis pieces\n",
    "   - Cross-feed agreement is a tiebreaker, not the primary criteria\n",
    "   - If no [PRIME] tweets exist, say 'No clear star — quiet prime time'\n",
    "   - Include a one-sentence reason with their stat line or key moment\n",
    "3. Format rules:\n",
    "   - Use emoji section headers: 🏀 NBA, 🏈 NFL, ⛳ Golf, ⭐ Star of the Night\n",
    "   - Keep each sport section to 2-4 bullet points max\n",
    "   - Be factual and concise — no fluff\n",
    "   - Omit any sport section if there were no relevant tweets\n",
    "   - End with the Star of the Night section always last\n\n",
    "Tweets:\n{tweet_bundle}"
  )

  resp <- POST(
    "https://api.anthropic.com/v1/messages",
    add_headers(
      "x-api-key"         = ANTHROPIC_KEY,
      "anthropic-version" = "2023-06-01",
      "content-type"      = "application/json"
    ),
    body = toJSON(list(
      model      = "claude-haiku-4-5",
      max_tokens = 600,
      messages   = list(list(role = "user", content = prompt))
    ), auto_unbox = TRUE),
    encode = "raw"
  )

  if (status_code(resp) != 200) stop(glue("Claude API error: {status_code(resp)} — {rawToChar(content(resp, as='raw'))}"))
  content(resp)$content[[1]]$text
}

# --- Send Telegram message ---------------------------------------------------

send_telegram <- function(text) {
  resp <- POST(
    glue("https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"),
    body = list(
      chat_id    = TELEGRAM_CHAT,
      text       = text,
      parse_mode = "Markdown"
    ),
    encode = "form"
  )
  if (status_code(resp) != 200) {
    warning(glue("Telegram send failed: {status_code(resp)}"))
    return(FALSE)
  }
  TRUE
}

# --- Main --------------------------------------------------------------------

et_now     <- with_tz(Sys.time(), "America/New_York")
yesterday  <- format(et_now - days(1), "%A, %B %d")
date_label <- yesterday

cat(glue("Morning Sports Digest — {date_label}\n"))
cat("Fetching tweets from sport-specific accounts...\n")

token      <- build_oauth_token()
all_tweets <- list()

for (account in ALL_ACCOUNTS) {
  cat(glue("  Resolving @{account}...\n"))
  uid <- tryCatch(resolve_user_id(account, token), error = function(e) {
    warning(glue("Could not resolve @{account}: {e$message}"))
    NULL
  })
  if (is.null(uid)) next

  Sys.sleep(1)

  cat(glue("  Fetching tweets from @{account}...\n"))
  tweets <- tryCatch(
    fetch_user_tweets_yesterday(uid, account, token),
    error = function(e) {
      warning(glue("Failed to fetch @{account}: {e$message}"))
      list()
    }
  )
  cat(glue("    Got {length(tweets)} tweets\n"))
  all_tweets <- c(all_tweets, tweets)

  Sys.sleep(1)
}

# Filter to sports we care about
sports_tweets <- keep(all_tweets, function(tw) {
  sport <- classify_sport(tw$text)
  !is.na(sport)
})

cat(glue("Filtered to {length(sports_tweets)} sports-relevant tweets\n"))

if (length(sports_tweets) == 0) {
  msg <- glue("*Morning Sports Digest — {date_label}*\n\nNo sports results found in @ESPN or @FoxSports tweets from yesterday. Quiet day? ⚾")
  if (dry_run) {
    cat("\n--- DRY RUN OUTPUT ---\n", msg, "\n")
  } else {
    send_telegram(msg)
  }
  quit(save = "no")
}

# Sort: prime-time tweets first (live game coverage), then by engagement
sports_tweets <- sports_tweets[order(
  -map_int(sports_tweets,  ~ as.integer(.x$prime_time)),
  -(map_dbl(sports_tweets, ~ .x$likes) + map_dbl(sports_tweets, ~ .x$retweets))
)]

# Count prime-time vs daytime for Claude context
n_prime   <- sum(map_lgl(sports_tweets, ~ .x$prime_time))
n_daytime <- length(sports_tweets) - n_prime
cat(glue("  Prime-time tweets (6pm-2am ET): {n_prime} | Daytime: {n_daytime}\n"))

# Cap at 60 tweets to stay within Claude's context reasonably
if (length(sports_tweets) > 60) sports_tweets <- sports_tweets[1:60]

cat("Calling Claude to synthesize digest...\n")
bundle  <- format_tweet_bundle(sports_tweets)
digest  <- tryCatch(
  call_claude(bundle, date_label),
  error = function(e) {
    stop(glue("Claude synthesis failed: {e$message}"))
  }
)

# Prepend header
header  <- glue("*Morning Sports Digest — {date_label}*\n\n")
message <- paste0(header, digest)

if (dry_run) {
  cat("\n--- DRY RUN OUTPUT ---\n")
  cat(message, "\n")
  cat("--- END ---\n")
} else {
  cat("Sending to Telegram...\n")
  ok <- send_telegram(message)
  if (ok) cat("Delivered to Steve ✅\n") else cat("Telegram send failed ❌\n")
}
