#!/usr/bin/env Rscript
# ============================================================================
# X Monitor — Scan curated follows for reply opportunities
# ============================================================================
# Scans tweets from curated list, scores for relevance against published
# articles and model data, returns top candidates as JSON.
#
# Usage:
#   Rscript x-monitor.R                  # default: last 3 hours
#   Rscript x-monitor.R --hours 6        # custom lookback window
#   Rscript x-monitor.R --draft-night    # high-frequency draft mode
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(stringr)
  library(purrr)
  library(glue)
})

# --- Config ------------------------------------------------------------------

MONITOR_LIST <- "/Users/merrittocracyclaw/.openclaw/workspace/x-monitor-list.md"
ENGAGED_LIST <- "/Users/merrittocracyclaw/.openclaw/workspace/x-engaged-accounts.md"
STATE_FILE <- "/Users/merrittocracyclaw/.openclaw/workspace/memory/x-monitor-state.json"
MODEL_DATA <- "/Users/merrittocracyclaw/nfl-draft-model/data/05_scored_2026.rds"
MAX_REPLIES_PER_DAY <- 3

# Articles we've published (topics we can speak to with authority)
ARTICLE_TOPICS <- list(
  list(
    slug = "the-big-arch-vs-the-mendoza-line",
    keywords = c("arch manning", "fernando mendoza", "mendoza", "qb1", "number one pick",
                 "manning", "raiders", "quarterback", "15 starts", "bust rate",
                 "cam newton", "quinn ewers"),
    summary = "Mendoza over Manning at #1. 15-start QBs have 75% bust rate. Manning family chose patience."
  ),
  list(
    slug = "the-van-isnt-the-variable",
    keywords = c("team development", "chargers", "raiders", "patriots", "bust rate",
                 "organizational", "talent development", "drafting team", "development grade"),
    summary = "Team development grades matter. Chargers improved after move to LA. Raiders stayed bad. The org is the variable."
  ),
  list(
    slug = "could-a-te-be-this-years-big-short",
    keywords = c("kenyon sadiq", "tight end", "receiver", "carnell tate", "jordyn tyson",
                 "makai lemon", "boom rate", "surplus value", "mispriced", "big short",
                 "receiver class", "oregon te"),
    summary = "Sadiq (TE, Oregon) has same boom rate as top WRs but goes 13 picks later. Market inefficiency."
  ),
  list(
    slug = "are-we-being-konned",
    keywords = c("konnor griffin", "griffin", "mississippi state", "transfer",
                 "quarterback evaluation"),
    summary = "Examining whether Griffin hype is justified by the data."
  ),
  list(
    slug = "ty-simpson-really",
    keywords = c("ty simpson", "alabama", "quarterback", "sleeper", "late round qb"),
    summary = "Model take on Ty Simpson as a QB prospect."
  ),
  list(
    slug = "sports-narratives-are-broken",
    keywords = c("narrative", "receipts", "analytics", "data-driven", "model",
                 "boom bust", "methodology"),
    summary = "The Merrittocracy thesis: sports media narratives need data checks."
  ),
  list(
    slug = "f-them-picks",
    keywords = c("ty simpson", "rams", "kenyon sadiq", "jets", "omar cooper",
                 "david bailey", "max iheanachor", "keylan rutledge", "steelers",
                 "texans", "malachi lawrence", "cowboys", "nfl draft", "first round",
                 "les snead", "draft capital", "boom rate", "organizational"),
    summary = "2026 NFL Draft Round 1 recap through the model lens. Jets taxed by retention rate, Rams bet on Simpson, Cowboys split."
  ),
  list(
    slug = "im-a-mj-guy-but",
    keywords = c("lebron", "lebron james", "lakers", "luka", "doncic", "austin reaves",
                 "goat", "michael jordan", "nba playoffs", "houston rockets",
                 "41 year old", "playoffs", "nba goat", "mj", "james"),
    summary = "LeBron at 41, no Luka, no Reaves, Lakers up 3-0. History has no comparison. MJ still GOAT but LeBron deserves his flowers."
  )
,
  list(
    slug = "the-r-word-nobody-in-the-nfl-wants",
    keywords = c("jeremiyah love", "2026 nfl draft", "running back", "top 5 pick", "new york giants", "todd mcshay", "offensive weapon", "draft evaluation", "position labeling", "nfl front offices", "draft analysis", "mock draft", "passing game", "player valuation", "draft strategy"),
    summary = "NFL analysts avoid calling elite players 'running backs,' using euphemisms to justify top-5 picks like Jeremiyah Love."
  )
,
  list(
    slug = "what-makes-a-consensus-elite-player",
    keywords = c("caleb downs", "2026 nfl draft", "safety position", "draft capital", "jeremiyah love", "sonny styles", "kyle hamilton", "positional value", "first-round picks", "daniel jeremiah", "surplus value", "draft analytics", "prospect evaluation", "running back", "linebacker"),
    summary = "Elite safety prospect Caleb Downs faces draft slide despite top talent due to NFL's undervaluation of the safety position."
  )
,
  list(
    slug = "pour-one-out-for-my-homies",
    keywords = c("2026 nfl draft", "sports analytics", "machine learning models", "homebrew", "open-source tools", "automation agent", "data pipeline", "position-specific models", "themerrittocracy", "draft analysis", "analytics operation", "software development", "content engine", "model building", "draft predictions"),
    summary = "TheMerrittocracy built a sports analytics operation in one month using open-source tools and ML models for 2026 NFL Draft coverage."
  )
,
  list(
    slug = "earnest-goes-to-the-draft",
    keywords = c("nfl draft", "ai automation", "openclaw", "earnest", "boom/bust probabilities", "draft prediction model", "human in the loop", "x-posts", "substack", "themerrittocracy", "ai agent", "draft analysis", "mac mini", "claude by anthropic", "soul.md"),
    summary = "TheMerrittocracy introduces Earnest, an AI automation agent that amplifies content reach while maintaining editorial control through human approval loops."
  )
)

# Keywords that trigger HARD SKIP (no race, no politics)
SKIP_KEYWORDS <- c(
  "racist", "racism", "political", "politics", "election", "trump", "biden",
  "democrat", "republican", "liberal", "conservative", "woke", "dei",
  "immigration", "abortion", "gun control", "protest"
)

# --- Auth --------------------------------------------------------------------

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

# --- State management --------------------------------------------------------

read_state <- function() {
  if (!file.exists(STATE_FILE)) {
    return(list(
      replied_today = list(),
      last_scan = NULL,
      seen_tweet_ids = character(0),
      daily_reply_count = 0,
      day = as.character(Sys.Date())
    ))
  }
  state <- fromJSON(STATE_FILE, simplifyVector = FALSE)
  # Reset daily count if new day
  if (is.null(state$day) || state$day != as.character(Sys.Date())) {
    state$daily_reply_count <- 0
    state$replied_today <- list()
    state$day <- as.character(Sys.Date())
  }
  state
}

write_state <- function(state) {
  state$last_scan <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  write(toJSON(state, auto_unbox = TRUE, pretty = TRUE), STATE_FILE)
}

# --- Parse monitor list ------------------------------------------------------

parse_monitor_list <- function() {
  lines <- readLines(MONITOR_LIST, warn = FALSE)
  handles <- str_extract(lines, "@[A-Za-z0-9_]+")
  handles <- handles[!is.na(handles)]
  # Remove the @ prefix
  str_remove(handles, "^@")
}

# --- Parse engaged accounts list ---------------------------------------------
# Accounts where @Merrittocratic has prior engagement history.
# API replies and quote tweets are allowed for these accounts.
# Steve manually seeds this list by engaging via the X app first.

parse_engaged_accounts <- function() {
  if (!file.exists(ENGAGED_LIST)) return(character(0))
  lines <- readLines(ENGAGED_LIST, warn = FALSE)
  handles <- str_extract(lines, "@[A-Za-z0-9_]+")
  handles <- handles[!is.na(handles)]
  str_to_lower(str_remove(handles, "^@"))
}

# --- Resolve usernames to IDs -----------------------------------------------

resolve_user_ids <- function(usernames, token) {
  # X API v2 allows up to 100 usernames per request
  ids <- list()
  chunks <- split(usernames, ceiling(seq_along(usernames) / 100))
  
  for (chunk in chunks) {
    resp <- GET(
      "https://api.twitter.com/2/users/by",
      config = config(token = token),
      query = list(
        usernames = paste(chunk, collapse = ","),
        "user.fields" = "id,username"
      )
    )
    
    if (status_code(resp) == 200) {
      data <- content(resp)$data
      for (user in data) {
        ids[[user$username]] <- user$id
      }
    }
    Sys.sleep(1)  # Rate limit courtesy
  }
  ids
}

# --- Fetch recent tweets from a user ----------------------------------------

fetch_user_tweets <- function(user_id, username, token, since_hours = 3) {
  start_time <- format(
    Sys.time() - as.difftime(since_hours, units = "hours"),
    "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )
  
  resp <- GET(
    paste0("https://api.twitter.com/2/users/", user_id, "/tweets"),
    config = config(token = token),
    query = list(
      max_results = "10",
      start_time = start_time,
      "tweet.fields" = "created_at,text,public_metrics,conversation_id",
      exclude = "retweets,replies"  # Only original tweets
    )
  )
  
  if (status_code(resp) != 200) return(list())
  
  data <- content(resp)$data
  if (is.null(data)) return(list())
  
  map(data, ~ list(
    id = .x$id,
    text = .x$text,
    created_at = .x$created_at,
    username = username,
    impressions = .x$public_metrics$impression_count %||% 0,
    likes = .x$public_metrics$like_count %||% 0,
    retweets = .x$public_metrics$retweet_count %||% 0,
    replies = .x$public_metrics$reply_count %||% 0
  ))
}

# --- Relevance scoring -------------------------------------------------------

score_tweet <- function(tweet_text, model_data = NULL) {
  text_lower <- str_to_lower(tweet_text)
  
  # Hard skip: race/politics
  if (any(str_detect(text_lower, SKIP_KEYWORDS))) {
    return(list(score = -1, matched_article = NULL, reason = "skip_topic"))
  }
  
  # Score against each article's keywords
  best_score <- 0
  best_article <- NULL
  
  for (article in ARTICLE_TOPICS) {
    matches <- sum(str_detect(text_lower, str_to_lower(article$keywords)))
    if (matches > best_score) {
      best_score <- matches
      best_article <- article
    }
  }
  
  # Also check against prospect names from model data
  prospect_match <- FALSE
  matched_prospect <- NULL
  if (!is.null(model_data)) {
    r1_prospects <- model_data |> filter(pick_est <= 64)
    for (i in seq_len(nrow(r1_prospects))) {
      pname <- str_to_lower(r1_prospects$player_name[i])
      # Require full name match to avoid false positives ("Jordan Smith" golfer != prospect)
      if (str_detect(text_lower, fixed(pname))) {
        prospect_match <- TRUE
        matched_prospect <- r1_prospects[i, ]
        best_score <- best_score + 2  # Bonus for prospect mention
        break
      }
    }
    # If no full name match, try well-known prospects (unique last names only)
    if (!prospect_match) {
      key_prospects <- r1_prospects |> 
        filter(pick_est <= 32) |>
        mutate(last_name = str_extract(str_to_lower(player_name), "\\S+$")) |>
        # Only match last names that are distinctive enough
        filter(!last_name %in% c("smith", "johnson", "williams", "jones", 
                                  "brown", "davis", "miller", "wilson",
                                  "moore", "taylor", "anderson", "thomas",
                                  "jackson", "white", "harris", "martin",
                                  "allen", "young", "king", "wright",
                                  "scott", "green", "baker", "hill",
                                  "love", "woods", "cooper", "parker"))
      for (i in seq_len(nrow(key_prospects))) {
        last_name <- key_prospects$last_name[i]
        if (str_detect(text_lower, fixed(last_name))) {
          prospect_match <- TRUE
          matched_prospect <- key_prospects[i, ] |> select(-last_name)
          best_score <- best_score + 2
          break
        }
      }
    }
  }
  
  list(
    score = best_score,
    matched_article = best_article,
    prospect_match = prospect_match,
    matched_prospect = matched_prospect,
    reason = if (best_score >= 2) "strong_match" else if (best_score == 1) "weak_match" else "no_match"
  )
}

# --- Main --------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
hours <- 3
draft_night <- FALSE

if ("--hours" %in% args) {
  idx <- which(args == "--hours")
  hours <- as.numeric(args[idx + 1])
}
if ("--draft-night" %in% args) {
  hours <- 1
  draft_night <- TRUE
}

state <- read_state()

# Check daily limit
if (state$daily_reply_count >= MAX_REPLIES_PER_DAY) {
  cat("[]")  # At daily limit
  quit(save = "no")
}

token <- build_token()
usernames <- parse_monitor_list()

# Load model data for prospect matching
model_data <- tryCatch(
  readRDS(MODEL_DATA),
  error = function(e) NULL
)

# Resolve user IDs (cache this in state to avoid repeated lookups)
if (is.null(state$user_ids) || length(state$user_ids) == 0) {
  user_ids <- resolve_user_ids(usernames, token)
  state$user_ids <- user_ids
} else {
  user_ids <- state$user_ids
}

# Fetch and score tweets
candidates <- list()
engaged_accounts <- parse_engaged_accounts()

for (username in names(user_ids)) {
  tweets <- fetch_user_tweets(user_ids[[username]], username, token, since_hours = hours)
  
  for (tweet in tweets) {
    # Skip already-seen tweets
    if (tweet$id %in% state$seen_tweet_ids) next
    
    scoring <- score_tweet(tweet$text, model_data)
    
    if (scoring$score >= 2) {  # Require at least 2 keyword matches
      is_engaged <- str_to_lower(tweet$username) %in% engaged_accounts
      candidate <- list(
        tweet_id = tweet$id,
        username = tweet$username,
        text = tweet$text,
        created_at = tweet$created_at,
        impressions = tweet$impressions,
        likes = tweet$likes,
        relevance_score = scoring$score,
        matched_article_slug = scoring$matched_article$slug %||% NA,
        matched_article_summary = scoring$matched_article$summary %||% NA,
        prospect_match = scoring$prospect_match,
        reason = scoring$reason,
        engagement_status = if (is_engaged) "engaged" else "cold",
        can_reply_via_api = is_engaged
      )
      
      # Add prospect data if matched
      if (scoring$prospect_match && !is.null(scoring$matched_prospect)) {
        candidate$prospect_name <- scoring$matched_prospect$player_name
        candidate$prospect_position <- scoring$matched_prospect$position
        candidate$prospect_school <- scoring$matched_prospect$school
        candidate$prospect_boom <- scoring$matched_prospect$p_boom
        candidate$prospect_bust <- scoring$matched_prospect$p_bust
        candidate$prospect_verdict <- scoring$matched_prospect$model_verdict
      }
      
      candidates <- c(candidates, list(candidate))
    }
  }
  
  Sys.sleep(1)  # Rate limit: 1 second between users
}

# Sort by relevance score descending, then by impressions
if (length(candidates) > 0) {
  scores <- map_dbl(candidates, ~ .x$relevance_score)
  impressions <- map_dbl(candidates, ~ .x$impressions)
  order_idx <- order(-scores, -impressions)
  candidates <- candidates[order_idx]
  
  # Split into engaged (API-ready) and cold (manual) candidates
  engaged_candidates <- candidates[map_lgl(candidates, ~ .x$can_reply_via_api)]
  cold_candidates    <- candidates[map_lgl(candidates, ~ !.x$can_reply_via_api)]

  # Cap API-ready replies at daily limit
  remaining <- MAX_REPLIES_PER_DAY - state$daily_reply_count
  engaged_candidates <- engaged_candidates[seq_len(min(length(engaged_candidates), remaining))]

  # Always surface up to 3 cold candidates so Steve can reply manually
  cold_candidates <- cold_candidates[seq_len(min(length(cold_candidates), 3))]

  # Recombine: engaged first (API), then cold (manual)
  candidates <- c(engaged_candidates, cold_candidates)
}

# Update seen tweets
all_tweet_ids <- unique(c(
  state$seen_tweet_ids,
  map_chr(candidates, ~ .x$tweet_id)
))
# Keep last 500 to prevent unbounded growth
state$seen_tweet_ids <- tail(all_tweet_ids, 500)
write_state(state)

# Output
cat(toJSON(candidates, auto_unbox = TRUE, pretty = TRUE))
