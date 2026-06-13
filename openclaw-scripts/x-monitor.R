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
,
  list(
    slug = "the-tax-man-cometh",
    keywords = c("cleveland cavaliers", "donovan mitchell", "evan mobley", "james harden", "toronto raptors", "scottie barnes", "darius garland", "superteam tax", "trade deadline", "playoff performance", "regular season vs playoffs", "first-round series", "roster flexibility", "harden playoff performance", "2026 nba playoffs", "detroit pistons", "pistons", "cade cunningham"),
    summary = "Cleveland's superteam struggles in playoffs despite trading assets for James Harden, exposing the cost of roster flexibility."
  ),
  list(
    slug = "can-coaches-be-clutch",
    keywords = c("nick nurse", "nurse", "sixers coach", "philadelphia 76ers", "joel embiid", "tyrese maxey",
                 "coach of the year", "playoff coaching", "coaching adjustment", "box and one",
                 "steve kerr", "mark daigneault", "playoff premium", "coaching record",
                 "regular season vs playoffs", "nba coaching", "clutch coaching",
                 "gregg popovich", "doc rivers", "tom thibodeau", "nba coach",
                 "game 7", "sixers celtics", "sixers knicks", "playoff adjustments"),
    summary = "Data-driven look at whether coaches actually matter in the playoffs — Nick Nurse as the case study, using COY win% above/below the regular season line."
  ),
  list(
    slug = "nba-playoffs-general",
    keywords = c(
      # General playoff terms
      "nba playoffs", "playoff basketball", "nba postseason", "first round",
      "second round", "conference semifinals", "conference finals", "nba finals",
      "series lead", "series tied", "elimination game", "closeout game",
      # West teams / players
      "oklahoma city thunder", "shai gilgeous-alexander", "sga",
      "denver nuggets", "nikola jokic", "jamal murray",
      "golden state warriors", "stephen curry", "steph curry",
      "memphis grizzlies", "ja morant",
      "houston rockets", "alperen sengun",
      "dallas mavericks", "kyrie irving",
      "minnesota timberwolves", "anthony edwards", "ant edwards",
      "los angeles clippers",
      # East teams / players
      "boston celtics", "jayson tatum", "jaylen brown",
      "new york knicks", "jalen brunson", "karl-anthony towns", "towns",
      "indiana pacers", "tyrese haliburton", "haliburton",
      "miami heat", "jimmy butler",
      "milwaukee bucks", "giannis", "giannis antetokounmpo",
      "orlando magic",
      # Storylines
      "home court advantage", "game 7", "sweep", "bench depth",
      "playoff seeding", "rest advantage", "load management playoffs",
      "nba analytics", "playoff rotation", "clutch time"
    ),
    summary = "General NBA playoffs 2026 coverage — team storylines, series results, and analytical takes across the full bracket."
  )
,
  list(
    slug = "dont-call-it-a-comeback",
    keywords = c(
      # Pistons–Cavs series
      "detroit pistons", "pistons", "cleveland cavaliers", "cavs",
      "donovan mitchell", "evan mobley", "cade cunningham",
      # Knicks–Sixers series / sweep
      "philadelphia 76ers", "76ers", "sixers", "new york knicks",
      "jalen brunson", "joel embiid", "embiid", "sweep",
      # Seeding / 3-1 comeback narrative
      "3-1 deficit", "3-1 comeback", "7-seed", "1-seed", "seeding",
      "regression to the mean", "additive effects",
      # Round 2 framing
      "round 2", "second round", "conference semifinals",
      "3-0 series lead", "series lead"
    ),
    summary = "Detroit (1-seed) and Philly (7-seed) both came back from 3-1 deficits in Round 1, but seed tells the real story: Pistons up 2-0 on Cavs, Knicks up 3-0 on Sixers. Two independent risk factors compound."
  ),
  list(
    slug = "holding-out-for-a-hero",
    keywords = c("anthony edwards", "luka dončić", "minnesota timberwolves", "san antonio spurs", "los angeles lakers", "oklahoma city thunder", "victor wembanyama", "donte divincenzo", "playoffs 2026", "injury return", "game 1", "hamstring injury", "torn achilles", "home court advantage", "playoff narrative"),
    summary = "Star injuries shape playoff narratives differently: Edwards' return energizes Wolves while Dončić's absence leaves Lakers outclassed."
  )
,
  list(
    slug = "you-cant-escape-your-past",
    keywords = c("kristoffer reitan", "u.s. open shinnecock hills", "pga championship aronimink", "golf predictive model", "form residual", "skill prior", "cameron young", "truist", "recent form vs historical baseline", "player ranking", "golf analytics", "model accuracy", "signature event", "form decay", "tournament prediction"),
    summary = "A golf prediction model struggles when recent hot form contradicts a player's poor historical baseline."
  )
,
  list(
    slug = "donald-ross-might-have-won-friday",
    keywords = c("pga championship", "aronimink", "scottie scheffler", "rory mcilroy", "maverick mcnealy", "alex smalley", "ludvig aberg", "tyrrell hatton", "donald ross course", "strokes gained", "hot hand form", "missed the cut", "ball-strikers", "friday pin placements", "moving day"),
    summary = "Donald Ross course design and brutal Friday conditions at PGA Championship upset favorites and elevated unlikely leaders."
  )
,
  list(
    slug = "the-struggle-was-real",
    keywords = c("scottie scheffler", "rory mcilroy", "alex smalley", "aaron rai", "pga major championship", "aronimink", "strokes gained", "predictive model", "t2 finish", "form residual", "skill prior", "2027 masters", "leaderboard", "sunday collapse", "golf analytics"),
    summary = "Predictive model correctly identified contenders like Alex Smalley at major despite limitations in ranking Sunday leaders."
  )
,
  list(
    slug = "i-dont-do-sidekicks-im-a-solo-act",
    keywords = c("victor wembanyama", "de'aaron fox", "san antonio spurs", "western conference finals", "okc thunder", "shai gilgeous-alexander", "stephon castle", "per-36 stats", "playoff scoring", "running mate", "co-star role", "kareem abdul-jabbar", "oscar robertson", "michael jordan", "championship contention"),
    summary = "Wembanyama struggles to carry Spurs alone without a reliable co-star, proving elite wings need defined running mates to win titles."
  )

,
  list(
    slug = "sports-narratives-are-broken-the",
    keywords = c("nfl draft", "sports narratives", "draft analysis", "mock drafts", "face of the league", "tiger woods", "masters", "consensus opinion", "sports analytics", "draft evaluation", "accountability", "sports media", "boom/bust probability model", "draft class", "conventional wisdom"),
    summary = "Sports media narratives lack accountability; TheMerrittocracy uses data to fact-check consensus opinions starting with NFL Draft analysis."
  )
,
  list(
    slug = "the-not-so-magnificent-seven",
    keywords = c("interior defensive line", "idl", "pass rush", "edge rushers", "front seven", "aaron donald", "ndamukong suh", "haloti ngata", "fletcher cox", "jeffery simmons", "chris jones", "boom/bust differential", "nfl draft", "defensive tackle", "first-round picks"),
    summary = "Interior defensive line is the safest premium bet in the front seven with a +10.9% boom/bust differential."
  )
,
  list(
    slug = "there-can-be-only-one-precedent",
    keywords = c("victor wembanyama", "san antonio spurs", "nba playoffs 2026", "generational big man", "lew alcindor", "kareem abdul-jabbar", "milwaukee bucks", "oscar robertson", "de'aaron fox", "60-win team", "year three", "nba finals", "postseason awards", "playoff narrative", "championship contender"),
    summary = "Victor Wembanyama's young Spurs team parallels Kareem's 1969-70 Bucks run, but lacks the co-star supporting cast."
  )
,
  list(
    slug = "there-will-never-be-another-tiger",
    keywords = c("tiger woods", "rory mcilroy", "earl woods", "kultida woods", "next tiger", "masters", "green jacket", "psychological conditioning", "golf legacy", "36-hole lead", "augusta", "scottie scheffler", "jordan spieth", "sports parenting", "golf goat"),
    summary = "Tiger Woods was uniquely shaped by intentional psychological conditioning from his father Earl, making him irreplaceable rather than a benchmark."
  )
,
  list(
    slug = "dream-the-impossible-dream",
    keywords = c("oklahoma city thunder", "new york knicks", "nba finals", "chet holmgren", "shai gilgeous-alexander", "jalen williams", "karl-anthony towns", "jude brunson", "san antonio spurs", "madison square garden", "2026 nba finals", "okc vs nyk", "regular season matchup", "defending champions", "ajay mitchell"),
    summary = "OKC's 2-0 regular season sweep over NY provides blueprint for potential Finals matchup despite injury concerns."
  )
,
  list(
    slug = "you-had-one-job-just-the-one",
    keywords = c("karl-anthony towns", "kat", "new york knicks", "san antonio spurs", "nba finals", "dylan harper", "mike brown", "jalen brunson", "foul trouble", "playmaking", "conference finals", "screening offense", "half-court spacing", "3.8 fouls per game", "nba cup final"),
    summary = "KAT's foul trouble against San Antonio's screening-heavy defense is the key variable determining if the Knicks can reach the Finals."
  )
,
  list(
    slug = "the-opposite",
    keywords = c("knicks", "spurs", "kat", "karl-anthony towns", "jalen brunson", "dejounte castle", "wembanyama", "nba finals", "2-0 series lead", "assists trend", "foul trouble", "plus/minus", "defensive strategy", "playoff trends", "point-of-attack defense"),
    summary = "Knicks defy preseason trend predictions to lead Finals 2-0 behind KAT's physical defense and Brunson's clutch plays."
  )
,
  list(
    slug = "who-the-f-is-private-santiago",
    keywords = c("jimmy stanger", "u.s. open golf", "golf tournament prediction", "predictive model", "strokes gained", "shinnecock", "weather impact golf", "era5 reanalysis data", "win probability", "pga championship", "golf analytics", "course conditions", "wind speed analysis", "player performance modeling", "golf forecasting"),
    summary = "A predictive golf model improved by adding weather data and fixing win probability calculations for tournament predictions."
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
                                  "love", "woods", "cooper", "parker",
                                  # NBA/NFL city & team name false positives
                                  "boston", "houston", "dallas", "denver",
                                  "memphis", "indiana", "orlando", "miami",
                                  "phoenix", "portland", "charlotte", "cleveland",
                                  "brooklyn", "golden", "sacramento", "oklahoma"))
      for (i in seq_len(nrow(key_prospects))) {
        last_name <- key_prospects$last_name[i]
        if (str_detect(text_lower, regex(paste0("\\b", last_name, "\\b")))) {
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
