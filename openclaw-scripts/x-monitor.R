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
# 2026-06-13 — Path migration to single source of truth in autopilot/.
# 2026-06-13 — Tier-aware scoring + draft style routing.
#
# Paths are derived from $HOME so the same code works on the Mac Mini
# (merrittocracyclaw) and Steve's laptop (stephenmerritt) for testing.

HOME_DIR     <- Sys.getenv("HOME")
AUTOPILOT    <- file.path(HOME_DIR, "autopilot")
MONITOR_LIST <- file.path(AUTOPILOT, "openclaw-scripts", "x-monitor-list.md")
ENGAGED_LIST <- file.path(AUTOPILOT, "openclaw-scripts", "x-engaged-accounts.md")
PROMPTS_DIR  <- file.path(AUTOPILOT, "prompts")

# Runtime state stays outside the repo (state files are not git-tracked).
STATE_FILE <- file.path(HOME_DIR, ".openclaw", "workspace", "memory", "x-monitor-state.json")
MODEL_DATA <- file.path(HOME_DIR, "nfl-draft-model", "data", "05_scored_2026.rds")

# Daily caps
MAX_REPLIES_PER_DAY    <- 3   # API-eligible replies (engaged accounts only)
MAX_CANDIDATES_PER_DAY <- 8   # total surfacings across all tiers per day
TRACKED_TIERS          <- c("1A", "1B", "1C", "2")
RESERVED_TIER_SLOTS    <- c("1A" = 1L, "1B" = 2L)

# Tier-specific thresholds. The min_score is the keyword-match floor;
# velocity_override is an engagement-per-minute threshold that surfaces
# a tweet regardless of keyword match (catches "this is taking off"
# moments where reply timing matters more than topical overlap).
TIER_CONFIG <- list(
  "1A" = list(
    min_score         = 0,    # no keyword floor — substantiveness gates instead
    max_age_hours     = 2,
    velocity_override = 50,
    draft_style       = "tier_1a"
  ),
  "1B" = list(
    min_score         = 1,
    max_age_hours     = 4,
    velocity_override = 100,
    draft_style       = "tier_1b"
  ),
  "1C" = list(
    min_score         = 0,    # gated by analytical-hook check, not keywords
    max_age_hours     = 2,
    velocity_override = 200,  # tier-1C accounts are huge; high velocity bar
    draft_style       = "tier_1c"
  ),
  "2"  = list(
    min_score         = 2,    # current behavior preserved
    max_age_hours     = 12,
    velocity_override = Inf,  # no velocity override for tier-2
    draft_style       = "tier_2"
  )
)

# Cowherd-specific handles get the Cowherd prompt template instead of default 1A.
COWHERD_HANDLES <- c("colincowherd", "theherd")

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
,
  list(
    slug = "it-took-12-points-to-erase-53-years",
    keywords = c("2026 nba finals", "new york knicks", "san antonio spurs", "wembanyama", "fourth quarter collapse", "12-point margin", "3-1 finals lead", "castle", "brunson", "kat", "first quarter dominance", "spurs outscored q4", "nba championship", "finals comeback", "point differential"),
    summary = "Knicks won 2026 Finals despite being outscored by 12 total points, as San Antonio's first-quarter dominance crumbled in fourth quarters."
  )
,
  list(
    slug = "la-masia-never-got-these-kids",
    keywords = c("la masia", "youth soccer pipeline", "american athletes soccer", "saquon barkley", "justin jefferson", "jahmyr gibbs", "j.j. watt goalkeeper", "elite soccer xi", "youth academy development", "world cup performance", "athletic talent drain", "cornerbacks defenders", "barcelona scouts", "mbappé", "neymar"),
    summary = "American sports waste elite athletic talent on football instead of developing world-class soccer players through early academy systems."
  )
,
  list(
    slug = "seven-favorites-then-it-gets-fun",
    keywords = c("shinnecock hills", "u.s. open", "scheffler", "mcilroy", "rahm", "schauffele", "fleetwood", "cantlay", "fitzpatrick", "morikawa", "strokes gained", "win probability", "approach game", "fairway accuracy", "iron play"),
    summary = "Market overvalues McIlroy's name while underpricing Fleetwood and Morikawa's superior recent form at Shinnecock."
  )
,
  list(
    slug = "a-tale-of-two-tee-times",
    keywords = c("wyndham clark", "collin schauffele", "matt fitzpatrick", "rory mcilroy", "scottie scheffler", "shinnecock hills", "usga", "strokes gained", "approach play", "putting", "wind conditions", "thursday wave advantage", "moving day", "win probability", "regression to the mean"),
    summary = "Weather and course setup create unequal scoring conditions between AM/PM tee times, with Wyndham Clark's hot putter and approach game leading after two rounds."
  )
,
  list(
    slug = "three-tournaments-one-model-lots",
    keywords = c("kristoffer reitan", "aronimink", "rbc canadian open", "predictive model", "pre-tournament projection", "career baseline", "form mean", "stanger", "suber", "garnett", "potgieter", "shinnecock", "us open", "wyndham clark", "live scoring alerts"),
    summary = "Model struggles when applying major-championship confidence to weaker field tournaments where top-ranked players don't separate."
  )
,
  list(
    slug = "just-keep-tapping-just-keep-tapping",
    keywords = c("wyndham clark", "us open", "shinnecock hills", "strokes-gained", "earnest ai agent", "heater alert", "live golf scoring", "openclaw", "sports analytics", "real-time alerts", "golf model", "content automation", "nfl season", "cowherd", "dane brugler"),
    summary = "AI-powered alert system enables real-time sports content by flagging analytics-driven moments before they occur."
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
      replied_today          = list(),
      last_scan              = NULL,
      seen_tweet_ids         = character(0),
      daily_reply_count      = 0,
      daily_candidate_count  = 0,
      daily_tier_counts      = as.list(stats::setNames(rep(0L, length(TRACKED_TIERS)), TRACKED_TIERS)),
      day                    = as.character(Sys.Date())
    ))
  }
  state <- fromJSON(STATE_FILE, simplifyVector = FALSE)
  state$daily_tier_counts <- normalize_tier_counts(state$daily_tier_counts)
  # Reset daily counters on a new day
  if (is.null(state$day) || state$day != as.character(Sys.Date())) {
    state$daily_reply_count     <- 0
    state$daily_candidate_count <- 0
    state$daily_tier_counts     <- as.list(stats::setNames(rep(0L, length(TRACKED_TIERS)), TRACKED_TIERS))
    state$replied_today         <- list()
    state$day                   <- as.character(Sys.Date())
  }
  state
}

write_state <- function(state) {
  state$last_scan <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  write(toJSON(state, auto_unbox = TRUE, pretty = TRUE), STATE_FILE)
}

normalize_tier_counts <- function(x = NULL) {
  counts <- as.list(stats::setNames(rep(0L, length(TRACKED_TIERS)), TRACKED_TIERS))
  if (is.null(x)) return(counts)

  for (tier in TRACKED_TIERS) {
    value <- x[[tier]]
    if (is.null(value) || length(value) == 0 || is.na(value)) value <- 0L
    counts[[tier]] <- as.integer(value)
  }

  counts
}

remaining_reserved_slots <- function(state) {
  tier_counts <- normalize_tier_counts(state$daily_tier_counts)
  stats::setNames(
    vapply(
      names(RESERVED_TIER_SLOTS),
      function(tier) {
        max(as.integer(RESERVED_TIER_SLOTS[[tier]]) - as.integer(tier_counts[[tier]]), 0L)
      },
      integer(1)
    ),
    names(RESERVED_TIER_SLOTS)
  )
}

take_candidates <- function(candidates, n) {
  if (n <= 0 || length(candidates) == 0) return(list())
  candidates[seq_len(min(length(candidates), n))]
}

select_candidates_with_reservations <- function(candidates, remaining_total, state) {
  if (remaining_total <= 0 || length(candidates) == 0) return(list())

  reserved_remaining <- remaining_reserved_slots(state)
  selected           <- list()
  selected_ids       <- character(0)

  for (tier in names(reserved_remaining)) {
    tier_candidates <- candidates[map_chr(candidates, ~ .x$tier) == tier]
    picked          <- take_candidates(tier_candidates, reserved_remaining[[tier]])
    if (length(picked) == 0) next

    selected     <- c(selected, picked)
    selected_ids <- c(selected_ids, map_chr(picked, ~ .x$tweet_id))
  }

  remaining_slots <- remaining_total - length(selected)
  if (remaining_slots <= 0) return(selected)

  remaining_candidates <- candidates[!map_chr(candidates, ~ .x$tweet_id) %in% selected_ids]
  c(selected, take_candidates(remaining_candidates, remaining_slots))
}

# --- Parse monitor list ------------------------------------------------------
# Returns a data.frame with columns: handle (no @ prefix, original case),
# handle_lower (for matching), and tier ("1A", "1B", "1C", or "2").
# Default tier is "2" for any handle without a [tier:X] annotation.

parse_monitor_list_with_tiers <- function() {
  lines <- readLines(MONITOR_LIST, warn = FALSE)
  has_handle <- str_detect(lines, "@[A-Za-z0-9_]+")
  lines <- lines[has_handle]

  handles <- str_remove(str_extract(lines, "@[A-Za-z0-9_]+"), "^@")
  tiers   <- str_match(lines, "\\[tier:([0-9A-Za-z]+)\\]")[, 2]
  tiers[is.na(tiers)] <- "2"
  tiers <- toupper(tiers)

  data.frame(
    handle       = handles,
    handle_lower = str_to_lower(handles),
    tier         = tiers,
    stringsAsFactors = FALSE
  )
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
# fetch_quotes = TRUE (tier 1A/1B only): also fetches the text of any quoted
# tweet so that a quote-tweet like Cowherd's "👀 [win-prob charts]" is scored
# on the *quoted* content, not just the emoji wrapper.

fetch_user_tweets <- function(user_id, username, token, since_hours = 3,
                              fetch_quotes = FALSE,
                              include_retweets = FALSE) {
  start_time <- format(
    Sys.time() - as.difftime(since_hours, units = "hours"),
    "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )

  query_params <- list(
    max_results           = "10",
    start_time            = start_time,
    "tweet.fields"        = "created_at,text,public_metrics,conversation_id,referenced_tweets",
    exclude               = if (include_retweets) "replies" else "retweets,replies"
  )
  if (fetch_quotes) {
    query_params[["expansions"]]              <- "referenced_tweets.id"
    query_params[["referenced_tweets.fields"]] <- "text"
  }

  resp <- GET(
    paste0("https://api.twitter.com/2/users/", user_id, "/tweets"),
    config = config(token = token),
    query  = query_params
  )

  if (status_code(resp) != 200) return(list())

  body <- content(resp)
  data <- body$data
  if (is.null(data)) return(list())

  # Build id -> text lookup for referenced (quoted) tweets
  referenced_map <- list()
  if (fetch_quotes && !is.null(body$includes$tweets)) {
    for (rt in body$includes$tweets) {
      referenced_map[[rt$id]] <- rt$text
    }
  }

  map(data, function(tw) {
    # Resolve quoted tweet text (if present and requested)
    quoted_text <- NULL
    if (fetch_quotes && !is.null(tw$referenced_tweets)) {
      for (ref in tw$referenced_tweets) {
        if (!is.null(ref$type) && ref$type == "quoted" &&
            !is.null(referenced_map[[ref$id]])) {
          quoted_text <- referenced_map[[ref$id]]
          break
        }
      }
    }
    list(
      id          = tw$id,
      text        = tw$text,
      quoted_text = quoted_text,
      created_at  = tw$created_at,
      username    = username,
      impressions = tw$public_metrics$impression_count %||% 0,
      likes       = tw$public_metrics$like_count %||% 0,
      retweets    = tw$public_metrics$retweet_count %||% 0,
      replies     = tw$public_metrics$reply_count %||% 0
    )
  })
}

# --- Tweet heuristics --------------------------------------------------------

# A tweet is "substantive" if it's long enough to have a real take in it
# OR contains a stat/number/question. Filters out "good morning",
# brand promo, schedule announcements, and similar throwaways.
# For tier 1A/1B quote tweets, combined_text includes the quoted content so
# a short wrapper (e.g. "👀") is scored on what it's actually quoting.
is_substantive <- function(text) {
  if (nchar(text) < 60) return(FALSE)
  has_number   <- str_detect(text, "\\d")
  has_question <- str_detect(text, "\\?")
  nchar(text) > 140 || has_number || has_question
}

# Minutes elapsed since the tweet was posted. X API returns ISO-8601
# timestamps, sometimes with milliseconds — strip those before parsing.
minutes_since <- function(created_at) {
  ts_clean <- sub("\\.\\d+Z$", "Z", created_at)
  ts_utc   <- as.POSIXct(ts_clean, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  as.numeric(difftime(Sys.time(), ts_utc, units = "mins"))
}

# Engagement velocity: likes+retweets per minute since posting. Used as
# a "this is taking off" override — surfaces hot tweets even when the
# keyword score is below threshold.
compute_engagement_velocity <- function(likes, retweets, minutes_old) {
  total <- (likes %||% 0) + (retweets %||% 0)
  total / max(minutes_old, 1)
}

# Which prompt template should Earnest use to draft the reply?
# Cowherd handles get the Cowherd-specific template; everyone else
# gets their tier's default.
derive_draft_style <- function(tier, handle_lower) {
  if (tier == "1A" && handle_lower %in% COWHERD_HANDLES) {
    return("tier_1a_cowherd")
  }
  TIER_CONFIG[[tier]]$draft_style
}

# Tier-1C "analytical hook": a newsbreak tweet only surfaces if it
# mentions a player/team in the model data OR an article-keyword
# concept Steve has published on. Filters out generic transactions
# that don't give Steve anything to add.
has_analytical_hook <- function(prospect_match, keyword_score) {
  prospect_match || keyword_score >= 1
}

# --- Relevance scoring -------------------------------------------------------
# Tier-aware: returns the keyword score, matched article (for tracking),
# prospect match, and a should_surface decision based on the tier's rules.

score_tweet <- function(tweet, tier, model_data = NULL) {
  # For tier 1A/1B, score against original + quoted text so that a minimal
  # wrapper ("👀", single emoji) doesn't kill a substantive quote tweet.
  combined_text <- if (tier %in% c("1A", "1B") && !is.null(tweet$quoted_text)) {
    paste(tweet$text, tweet$quoted_text, sep = " ")
  } else {
    tweet$text
  }
  text       <- combined_text
  text_lower <- str_to_lower(text)

  # Hard skip: race/politics — applies to all tiers
  if (any(str_detect(text_lower, SKIP_KEYWORDS))) {
    return(list(
      score          = -1,
      matched_article = NULL,
      prospect_match  = FALSE,
      matched_prospect = NULL,
      substantive    = FALSE,
      minutes_old    = NA_real_,
      velocity       = 0,
      should_surface = FALSE,
      reason         = "skip_topic"
    ))
  }

  cfg          <- TIER_CONFIG[[tier]]
  substantive  <- is_substantive(text)
  minutes_old  <- minutes_since(tweet$created_at)
  velocity     <- compute_engagement_velocity(tweet$likes, tweet$retweets, minutes_old)

  # Keyword score against article topics
  best_score   <- 0
  best_article <- NULL
  for (article in ARTICLE_TOPICS) {
    matches <- sum(str_detect(text_lower, str_to_lower(article$keywords)))
    if (matches > best_score) {
      best_score   <- matches
      best_article <- article
    }
  }

  # Prospect-name matching against model data (NFL draft)
  prospect_match   <- FALSE
  matched_prospect <- NULL
  if (!is.null(model_data)) {
    r1_prospects <- model_data |> filter(pick_est <= 64)
    for (i in seq_len(nrow(r1_prospects))) {
      pname <- str_to_lower(r1_prospects$player_name[i])
      if (str_detect(text_lower, fixed(pname))) {
        prospect_match   <- TRUE
        matched_prospect <- r1_prospects[i, ]
        best_score       <- best_score + 2  # Prospect mention bonus
        break
      }
    }
    # Fallback: distinctive last names only (avoid Smith/Jones collisions)
    if (!prospect_match) {
      key_prospects <- r1_prospects |>
        filter(pick_est <= 32) |>
        mutate(last_name = str_extract(str_to_lower(player_name), "\\S+$")) |>
        filter(!last_name %in% c("smith", "johnson", "williams", "jones",
                                  "brown", "davis", "miller", "wilson",
                                  "moore", "taylor", "anderson", "thomas",
                                  "jackson", "white", "harris", "martin",
                                  "allen", "young", "king", "wright",
                                  "scott", "green", "baker", "hill",
                                  "love", "woods", "cooper", "parker",
                                  "boston", "houston", "dallas", "denver",
                                  "memphis", "indiana", "orlando", "miami",
                                  "phoenix", "portland", "charlotte", "cleveland",
                                  "brooklyn", "golden", "sacramento", "oklahoma"))
      for (i in seq_len(nrow(key_prospects))) {
        last_name <- key_prospects$last_name[i]
        if (str_detect(text_lower, regex(paste0("\\b", last_name, "\\b")))) {
          prospect_match   <- TRUE
          matched_prospect <- key_prospects[i, ] |> select(-last_name)
          best_score       <- best_score + 2
          break
        }
      }
    }
  }

  # --- Tier-aware surfacing decision -----------------------------------------
  # Stale tweets never surface regardless of tier (freshness gates engagement).
  too_stale <- minutes_old > cfg$max_age_hours * 60

  # Velocity override: tweet is taking off fast — surface even without keywords.
  velocity_hit <- is.finite(cfg$velocity_override) && velocity >= cfg$velocity_override

  # Tier-specific gating
  surface_decision <- if (too_stale) {
    list(surface = FALSE, reason = "stale")
  } else if (!substantive) {
    list(surface = FALSE, reason = "not_substantive")
  } else if (velocity_hit) {
    list(surface = TRUE,  reason = "velocity_override")
  } else if (tier == "1C") {
    # 1C requires an analytical hook (model data or article concept)
    if (has_analytical_hook(prospect_match, best_score)) {
      list(surface = TRUE, reason = "news_hook")
    } else {
      list(surface = FALSE, reason = "no_analytical_hook")
    }
  } else if (best_score >= cfg$min_score) {
    list(
      surface = TRUE,
      reason  = if (best_score >= 2) "strong_match"
                else if (best_score == 1) "weak_match"
                else "tier1a_substantive"
    )
  } else {
    list(surface = FALSE, reason = "below_threshold")
  }

  list(
    score            = best_score,
    matched_article  = best_article,
    prospect_match   = prospect_match,
    matched_prospect = matched_prospect,
    substantive      = substantive,
    minutes_old      = minutes_old,
    velocity         = velocity,
    should_surface   = surface_decision$surface,
    reason           = surface_decision$reason
  )
}

# --- Main --------------------------------------------------------------------

args         <- commandArgs(trailingOnly = TRUE)
hours        <- 3
draft_night  <- FALSE
# tier_filter accepts a single tier ("1A") or comma-separated set
# ("1A,1B,1C") for the fast-lane cron. NULL means scan all tiers.
tier_filter  <- NULL

if ("--hours" %in% args) {
  idx   <- which(args == "--hours")
  hours <- as.numeric(args[idx + 1])
}
if ("--draft-night" %in% args) {
  hours       <- 1
  draft_night <- TRUE
}
if ("--tier" %in% args) {
  idx         <- which(args == "--tier")
  raw         <- args[idx + 1]
  tier_filter <- toupper(str_trim(str_split(raw, ",")[[1]]))
}

state <- read_state()

# Daily candidate cap (soft cap on total surfacings, separate from API reply cap)
if (!is.null(state$daily_candidate_count) &&
    state$daily_candidate_count >= MAX_CANDIDATES_PER_DAY) {
  cat("[]")
  quit(save = "no")
}

token            <- build_token()
monitor          <- parse_monitor_list_with_tiers()
engaged_accounts <- parse_engaged_accounts()

# Apply tier filter. Accepts a single tier or a set (fast-lane uses
# {"1A", "1B", "1C"} together; slow-lane uses {"2"}).
if (!is.null(tier_filter)) {
  monitor <- monitor[monitor$tier %in% tier_filter, , drop = FALSE]
}

# Load model data for prospect matching
model_data <- tryCatch(readRDS(MODEL_DATA), error = function(e) NULL)

# Resolve user IDs (cached in state to avoid repeated lookups)
needed_handles <- monitor$handle
cached_ids     <- state$user_ids %||% list()
missing        <- setdiff(needed_handles, names(cached_ids))
if (length(missing) > 0) {
  new_ids        <- resolve_user_ids(missing, token)
  cached_ids     <- c(cached_ids, new_ids)
  state$user_ids <- cached_ids
}
user_ids <- cached_ids[needed_handles]

# Fetch + score tweets
candidates <- list()

for (i in seq_len(nrow(monitor))) {
  handle <- monitor$handle[i]
  tier   <- monitor$tier[i]
  uid    <- user_ids[[handle]]
  if (is.null(uid)) next

  tweets <- fetch_user_tweets(uid, handle, token, since_hours = hours,
                              fetch_quotes = tier %in% c("1A", "1B"),
                              include_retweets = tier == "1A")

  for (tweet in tweets) {
    if (tweet$id %in% state$seen_tweet_ids) next

    scoring <- score_tweet(tweet, tier, model_data)
    if (!isTRUE(scoring$should_surface)) next

    handle_lower <- str_to_lower(tweet$username)
    is_engaged   <- handle_lower %in% engaged_accounts
    is_cowherd   <- handle_lower %in% COWHERD_HANDLES
    draft_style  <- derive_draft_style(tier, handle_lower)

    candidate <- list(
      tweet_id             = tweet$id,
      username             = tweet$username,
      tier                 = tier,
      is_cowherd           = is_cowherd,
      text                 = tweet$text,
      created_at           = tweet$created_at,
      minutes_old          = round(scoring$minutes_old, 1),
      impressions          = tweet$impressions,
      likes                = tweet$likes,
      retweets             = tweet$retweets,
      engagement_per_min   = round(scoring$velocity, 2),
      is_substantive       = scoring$substantive,
      relevance_score      = scoring$score,
      matched_article_slug = scoring$matched_article$slug %||% NA,
      prospect_match       = scoring$prospect_match,
      reason               = scoring$reason,
      engagement_status    = if (is_engaged) "engaged" else "cold",
      can_reply_via_api    = is_engaged,
      draft_style          = draft_style,
      draft_prompt_path    = file.path("prompts", paste0("x_reply_", draft_style, ".md"))
    )

    if (scoring$prospect_match && !is.null(scoring$matched_prospect)) {
      candidate$prospect_name     <- scoring$matched_prospect$player_name
      candidate$prospect_position <- scoring$matched_prospect$position
      candidate$prospect_school   <- scoring$matched_prospect$school
      candidate$prospect_boom     <- scoring$matched_prospect$p_boom
      candidate$prospect_bust     <- scoring$matched_prospect$p_bust
      candidate$prospect_verdict  <- scoring$matched_prospect$model_verdict
    }

    candidates <- c(candidates, list(candidate))
  }

  Sys.sleep(1)  # Rate-limit courtesy
}

# --- Sort and cap ------------------------------------------------------------
# Tier priority is 1A, then 1B, then 1C, then 2; within tier, freshness then velocity.
if (length(candidates) > 0) {
  tier_rank   <- c("1A" = 1L, "1B" = 2L, "1C" = 3L, "2" = 4L)
  tier_idx    <- tier_rank[map_chr(candidates, ~ .x$tier)]
  minutes_old <- map_dbl(candidates, ~ .x$minutes_old)
  velocity    <- map_dbl(candidates, ~ .x$engagement_per_min)
  order_idx   <- order(tier_idx, minutes_old, -velocity)
  candidates  <- candidates[order_idx]

  # Cap API replies separately (engaged-account auto-replies)
  engaged_candidates <- candidates[map_lgl(candidates, ~ .x$can_reply_via_api)]
  cold_candidates    <- candidates[map_lgl(candidates, ~ !.x$can_reply_via_api)]

  reply_remaining    <- max(MAX_REPLIES_PER_DAY - (state$daily_reply_count %||% 0), 0)
  engaged_candidates <- engaged_candidates[seq_len(min(length(engaged_candidates), reply_remaining))]

  # Combine and cap total at MAX_CANDIDATES_PER_DAY (less any already surfaced today),
  # while leaving daily room for reserved 1A/1B slots.
  combined         <- c(engaged_candidates, cold_candidates)
  surfaced_today   <- state$daily_candidate_count %||% 0
  remaining_total  <- max(MAX_CANDIDATES_PER_DAY - surfaced_today, 0)
  candidates       <- select_candidates_with_reservations(combined, remaining_total, state)
}

# Update seen tweets and daily candidate count
all_tweet_ids        <- unique(c(state$seen_tweet_ids, map_chr(candidates, ~ .x$tweet_id)))
state$seen_tweet_ids <- tail(all_tweet_ids, 500)
state$daily_candidate_count <- (state$daily_candidate_count %||% 0) + length(candidates)
state$daily_tier_counts <- normalize_tier_counts(state$daily_tier_counts)
if (length(candidates) > 0) {
  for (tier in map_chr(candidates, ~ .x$tier)) {
    state$daily_tier_counts[[tier]] <- as.integer(state$daily_tier_counts[[tier]] %||% 0L) + 1L
  }
}
write_state(state)

# Output
cat(toJSON(candidates, auto_unbox = TRUE, pretty = TRUE))
