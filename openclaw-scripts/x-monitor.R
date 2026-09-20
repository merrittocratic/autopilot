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
  library(readr)
})

# --- Config ------------------------------------------------------------------
# 2026-08-31 — Add veteran-player matching against boxscore-prophet's
#              output/latest/scored_slate.csv (soft-optional, staleness-gated).
# 2026-08-31 — Drop candidate prospect fields when the matched row has NA
#              player_name/p_boom/p_bust instead of passing them through.
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

# boxscore-prophet's weekly veteran slate. output/latest/ is a gitignored,
# cron-refreshed handoff dir (see boxscore-prophet/scripts/refresh_latest.sh)
# -- soft-optional here the same way MODEL_DATA is, since the sibling repo's
# output may be absent, stale, or mid-refresh on any given run.
# 2026-09-02 -- boxscore-prophet repo relocated from
# ~/.openclaw/workspace/boxscore-prophet to ~/boxscore-prophet (top-level,
# matching every other sibling repo). Path corrected here to match.
BOXSCORE_PROPHET_LATEST <- file.path(HOME_DIR, "boxscore-prophet", "output", "latest")
BOXSCORE_SLATE          <- file.path(BOXSCORE_PROPHET_LATEST, "scored_slate.csv")
BOXSCORE_MANIFEST       <- file.path(BOXSCORE_PROPHET_LATEST, "run_manifest.json")
BOXSCORE_MAX_AGE_DAYS   <- 8   # weekly refresh cadence + buffer

# 2026-09-18 -- Content feature store (NFL/CFB/golf raw stats: EPA, target
# share, college production percentiles, strokes-gained), independently
# pulled by feature-store-refresh.R on its own daily cron -- decoupled from
# this script's 15-minute cadence so CFBD/DataGolf never see live traffic
# from here. Same soft-optional, staleness-gated contract as BOXSCORE_*
# above: missing or stale manifest entry -> NULL, never fails the scan.
FEATURE_STORE_DIR          <- file.path(AUTOPILOT, "data", "feature-store")
FEATURE_STORE_MANIFEST     <- file.path(FEATURE_STORE_DIR, "manifest.json")
FEATURE_STORE_MAX_AGE_DAYS <- 2   # daily refresh cadence + buffer

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
,
  list(
    slug = "burying-the-lead",
    keywords = c("giannis antetokounmpo", "kawhi leonard", "lebron james", "ja morant", "aj dybantsa", "darryn peterson", "dusty may", "nba draft 2026", "nba offseason", "toronto raptors", "portland trail blazers", "washington wizards", "utah jazz", "morez johnson", "mara lendeborg"),
    summary = "A chaotic NBA offseason sees blockbuster trades overshadow what was called an exceptional draft class."
  )
,
  list(
    slug = "when-everyones-super-no-one-turns",
    keywords = c("wnba", "caitlin clark", "adam silver", "indiana fever", "women's basketball profitability", "wnba revenue", "ticket sales", "merchandise", "television viewership", "nba ownership", "collective vs individual", "sports league economics", "cathy engelbert", "market capitalism", "women's sports business model"),
    summary = "WNBA's subsidy model prioritizes collective equality over star player profits, unlike market-driven sports."
  )
,
  list(
    slug = "am-i-a-soccer-guy-now",
    keywords = c("erling haaland", "world cup 2026", "norway", "christian pulisic", "usa soccer", "conversion rate", "gary lineker", "brazil elimination", "soccer analytics", "touches-per-goal", "quarterfinal", "american soccer pipeline", "world cup scoring", "belgium", "captain america"),
    summary = "A data-driven analyst questions why the U.S. lacks a generational soccer talent like Erling Haaland to compete on the World Cup stage."
  )
,
  list(
    slug = "scottie-doesnt-know",
    keywords = c("scottie doesn't know", "eric cole", "john deere classic", "golf model", "win probability", "datagolf", "us open", "the open championship", "wyndham clark", "mid-tier rankings", "golf analytics", "backtesting", "form windows", "per-round accuracy", "golf prediction model"),
    summary = "Golf model backtesting created false confidence in rankings until real tournament results exposed downstream bugs in win probability calculations."
  )
,
  list(
    slug = "predicting-the-majors-is-a-major",
    keywords = c("scottie scheffler", "ryan fox", "2026 majors", "royal birkdale", "claret jug", "pga championship", "open championship", "masters augusta", "golf predictions", "favorite odds", "cameron young", "sam burns", "wyndham clark", "aaron rai", "rory mcilroy", "major championship predictions"),
    summary = "Scheffler's zero major wins despite being favorite at all four proves predicting golf majors is harder than favorites suggest."
  )
,
  list(
    slug = "trust-the-process-distrust-the-fit",
    keywords = c("lebron james", "philadelphia 76ers", "joel embiid", "tyrese maxey", "jaylen brown", "paul george trade", "boston celtics", "bob myers", "vj edgecombe", "miami heat", "giannis antetokounmpo", "roster construction", "offensive fit", "possession touches", "finals mvp"),
    summary = "LeBron's 76ers signing looks good on paper but raises concerns about offensive fit with too many ball-dominant stars."
  )
,
  list(
    slug = "on-this-team-we-fight-for-that-inch",
    keywords = c("jahmyr gibbs", "fantasy football", "boxscore prophet", "derrick henry", "treveyon henderson", "quinshon judkins", "kyren williams", "kenneth walker", "bucky irving", "boom probability", "start probability", "fantasy model", "flex position", "running backs", "week 1 projections"),
    summary = "New fantasy model 'Boxscore Prophet' replaces decimals with boom/start probabilities for accurate weekly predictions."
  )
,
  list(
    slug = "thats-my-teammate-thats-my-quarterback",
    keywords = c("julian sayin", "jeremiah smith", "ohio state football", "arch manning", "texas longhorns", "cj carr", "notre dame", "dante moore", "oregon ducks", "john mateer", "oklahoma football", "carson beck", "miami hurricanes", "ryan day", "matt patricia", "caleb downs", "2026 college football", "77% completion rate", "national championship", "transfer portal"),
    summary = "Elite quarterback-led teams dominate 2026 college football, making defensive depth the real championship differentiator."
  )
,
  list(
    slug = "unscripted",
    keywords = c("patrick mahomes", "kansas city chiefs", "acl injury", "afc west", "one-score games", "super bowl mvp", "kenneth walker iii", "mansoor delane", "travis kelce", "denver broncos", "justin herbert", "drake maye", "new england patriots", "14-3 record", "regression to the mean"),
    summary = "Preseason narratives often collapse under scrutiny; regression analysis shows Chiefs and Patriots stories are more complex than camp hype suggests."
  )
,
  list(
    slug = "20-beats-your-five",
    keywords = c("arch manning", "julian sayin", "john mateer", "c.j. carr", "jeremiah smith", "dante moore", "heisman trophy", "college football production index", "quarterback rankings", "power 4 teams", "college football stats", "heisman predictions", "preseason rankings", "underdog candidates", "production baseline"),
    summary = "Contrarian Heisman analysis shows five consensus names miss top contenders who could replicate dark-horse winner patterns."
  )
,
  list(
    slug = "nothing-to-see-here-please",
    keywords = c("boxscore prophet", "epa (expected points added)", "week 1 launch", "predictive modeling", "running backs", "wide receivers", "tight ends", "quarterbacks", "weather features", "prediction error", "null results", "machine learning", "sports analytics", "forecast accuracy", "player-weeks sample size"),
    summary = "TheMerrittocracy publishes failed experiments from Boxscore Prophet's development to build audience trust through transparency."
  )
,
  list(
    slug = "not-my-problem",
    keywords = c("boxscore prophet", "fantasy football", "draft board", "rookie running backs", "bell-cow role", "committee back", "jeremiyah love", "saquon barkley", "christian mccaffrey", "derrick henry", "volume features", "carry share", "snap share", "in-season lineup tool", "draft capital"),
    summary = "Boxscore Prophet can't predict rookie RB roles before Week 1 because volume data doesn't exist yet."
  )
,
  list(
    slug = "public-math",
    keywords = c("boxscore prophet", "running back", "receiver", "quarterback", "tight end", "startable week", "boom", "ppr points", "probability model", "backtest", "player grading", "fantasy football", "model accuracy", "confidence buckets", "2016-2025 data"),
    summary = "Boxscore Prophet explains how its player grading model works and validates its probability predictions against historical data."
  )
,
  list(
    slug = "they-are-who-we-thought-they-were",
    keywords = c("darian mensah", "trinidad chambliss", "heisman trophy", "miami football", "notre dame", "julian sayin", "arch manning", "john mateer", "dante moore", "cj carr", "college football rankings", "pass defense", "quarterback performance", "college football playoff", "week 1 college football"),
    summary = "Heisman hype disproportionately favors QBs with high viewership over quality wins."
  )
,
  list(
    slug = "did-ya-get-that-memo",
    keywords = c("odell beckham jr.", "fantasy football model", "week 1 predictions", "fantasy receiver rankings", "malik willis", "miami dolphins", "deshaun watson", "mason rudolph", "nfl snaps data", "draft pedigree", "trailing statistics", "fantasy analytics", "model accuracy", "quarterback rankings", "2026 nfl season"),
    summary = "Fantasy model fails by ranking inactive players high due to missing in-season data and flawed fallback logic."
  )
,
  list(
    slug = "four-scores-and-one-week-ago",
    keywords = c("jaxson dart", "giants offense", "epa (expected points added)", "cpoe (completion % over expected)", "cam skattebo", "cincinnati bengals", "joe burrow", "week 1 nfl", "success rate", "passing epa", "quarterback efficiency", "expert consensus ranking", "run-efficiency", "fantasy points", "box score analysis"),
    summary = "Week 1 NFL box scores reveal which preseason narratives hold up and which don't through advanced metrics like EPA and CPOE."
  )
)

# Keywords that trigger HARD SKIP (no race, no politics)
SKIP_KEYWORDS <- c(
  # Race / politics — hard stop per SOUL.md
  "racist", "racism", "political", "politics", "election", "trump", "biden",
  "democrat", "republican", "liberal", "conservative", "woke", "dei",
  "immigration", "abortion", "gun control", "protest",
  # Off-field conduct / legal incidents — not analytical-reply territory
  # (2026-09-20: added after Keenan Allen DUI draft incident)
  "drunk driving", "\\bdui\\b", "\\bdwi\\b",
  "domestic violence", "sexual assault", "sexual harassment",
  "was arrested", "facing arrest", "\\barraigned\\b"
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
    query_params[["expansions"]] <- "referenced_tweets.id"
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
has_analytical_hook <- function(prospect_match, veteran_match, keyword_score,
                                 cfb_match = FALSE, golf_match = FALSE) {
  prospect_match || veteran_match || cfb_match || golf_match || keyword_score >= 1
}

# Assemble the {model_data} string for reply prompts from a candidate's
# matched-player fields. Pre-formats with human-readable labels so raw
# field names (e.g. p_boom_recal) never leak into a draft.
# Stat priority: feature-store (EPA/opp, target share) first; boxscore-
# prophet (start probability, boom recall) as fallback per MEMORY.md.
# Returns "NONE" when no match data is present.
# (2026-09-20: added to kill the "boom recal" label-leak incident)
format_model_data <- function(candidate) {
  blocks <- character(0)

  # --- Veteran block ----------------------------------------------------------
  if (isTRUE(candidate$veteran_match) && !is.null(candidate$veteran_name)) {
    low  <- if (isTRUE(candidate$veteran_low_sample)) " (small sample)" else ""
    name <- paste0(candidate$veteran_name, ", ", candidate$veteran_position,
                   ", ", candidate$veteran_team)

    has_fs <- !is.null(candidate$veteran_epa_per_opp) &&
               length(candidate$veteran_epa_per_opp) > 0 &&
               !is.na(candidate$veteran_epa_per_opp)

    if (has_fs) {
      # Feature-store stats (EPA/opp, target share) are the primary source.
      # Use them even when low_sample — just tag the block. Only fall back
      # to boxscore-prophet when feature-store is completely absent.
      epa_pctile <- round(candidate$veteran_epa_per_opp_pctile * 100)
      # Skip target share for QBs — it's always 0 (QBs throw targets,
      # they don't receive them), so the percentile is meaningless.
      is_qb <- !is.null(candidate$veteran_position) &&
                identical(candidate$veteran_position, "QB")
      if (!is_qb && !is.null(candidate$veteran_target_share) &&
          !is.na(candidate$veteran_target_share)) {
        tgt_pctile <- round(candidate$veteran_target_share_pctile * 100)
        tgt_share  <- round(candidate$veteran_target_share * 100, 1)
        blocks <- c(blocks, paste0(
          name, " — EPA/opportunity: ", candidate$veteran_epa_per_opp,
          ", ", epa_pctile, "th percentile at position;",
          " target share: ", tgt_share, "%, ", tgt_pctile, "th percentile",
          low
        ))
      } else {
        blocks <- c(blocks, paste0(
          name, " — EPA/opportunity: ", candidate$veteran_epa_per_opp,
          ", ", epa_pctile, "th percentile at position",
          low
        ))
      }
    } else {
      # Fallback: boxscore-prophet boom/start (skill positions only).
      p_start <- round(candidate$veteran_p_start * 100, 1)
      p_boom  <- round(candidate$veteran_p_boom_recal * 100, 1)
      blocks <- c(blocks, paste0(
        name, " — start probability: ", p_start, "%, boom recall: ", p_boom, "%", low
      ))
    }
  }

  # --- Prospect block ---------------------------------------------------------
  if (isTRUE(candidate$prospect_match) && !is.null(candidate$prospect_name)) {
    p_boom  <- round(candidate$prospect_boom * 100, 1)
    p_bust  <- round(candidate$prospect_bust * 100, 1)
    verdict <- if (!is.null(candidate$prospect_verdict) &&
                    length(candidate$prospect_verdict) > 0 &&
                    !is.na(candidate$prospect_verdict))
      paste0(", verdict: ", candidate$prospect_verdict) else ""
    blocks <- c(blocks, paste0(
      candidate$prospect_name, ", ", candidate$prospect_position,
      ", ", candidate$prospect_school,
      " — boom: ", p_boom, "%, bust: ", p_bust, "%", verdict
    ))
  }

  # --- CFB block --------------------------------------------------------------
  if (isTRUE(candidate$cfb_match) && !is.null(candidate$cfb_name)) {
    low   <- if (isTRUE(candidate$cfb_low_sample)) " (small sample)" else ""
    stats <- character(0)
    if (!is.null(candidate$cfb_qb_ypa_pctile) && !is.na(candidate$cfb_qb_ypa_pctile))
      stats <- c(stats, paste0("YPA: ", round(candidate$cfb_qb_ypa_pctile * 100), "th percentile"))
    if (!is.null(candidate$cfb_qb_cmp_pct_pctile) && !is.na(candidate$cfb_qb_cmp_pct_pctile))
      stats <- c(stats, paste0("Cmp%: ", round(candidate$cfb_qb_cmp_pct_pctile * 100), "th percentile"))
    if (!is.null(candidate$cfb_qb_int_pct_pctile) && !is.na(candidate$cfb_qb_int_pct_pctile))
      stats <- c(stats, paste0("INT%: ", round(candidate$cfb_qb_int_pct_pctile * 100), "th percentile"))
    if (!is.null(candidate$cfb_rush_ypc_pctile) && !is.na(candidate$cfb_rush_ypc_pctile))
      stats <- c(stats, paste0("YPC: ", round(candidate$cfb_rush_ypc_pctile * 100), "th percentile"))
    if (!is.null(candidate$cfb_rec_ypr_pctile) && !is.na(candidate$cfb_rec_ypr_pctile))
      stats <- c(stats, paste0("YPR: ", round(candidate$cfb_rec_ypr_pctile * 100), "th percentile"))
    if (length(stats) > 0) {
      blocks <- c(blocks, paste0(
        candidate$cfb_name, ", ", candidate$cfb_position, ", ", candidate$cfb_team,
        " — ", paste(stats, collapse = "; "), low
      ))
    }
  }

  # --- Golf block -------------------------------------------------------------
  if (isTRUE(candidate$golf_match) && !is.null(candidate$golf_name)) {
    low <- if (isTRUE(candidate$golf_low_sample)) " (small sample)" else ""
    blocks <- c(blocks, paste0(
      candidate$golf_name, " (", candidate$golf_n_rounds, " rounds) — ",
      "skill: ", round(candidate$golf_skill_pctile * 100), "th percentile; ",
      "SG off-tee: ", round(candidate$golf_sg_ott_pctile * 100), "th, ",
      "approach: ", round(candidate$golf_sg_app_pctile * 100), "th, ",
      "around-green: ", round(candidate$golf_sg_arg_pctile * 100), "th, ",
      "putting: ", round(candidate$golf_sg_putt_pctile * 100), "th; ",
      "form trend: ", round(candidate$golf_form_trend_pctile * 100), "th percentile",
      low
    ))
  }

  if (length(blocks) == 0) return("NONE")
  paste(blocks, collapse = "\n")
}

# 2026-09-19 audit (H-3) -- shared name-matching helper for the four
# player-matching blocks below (prospect, veteran, CFB, golf). All four
# used to `break` on the first name found in the tweet text, which is
# wrong whenever a tweet names more than one player -- the first name
# mentioned is not reliably the actionable one. Confirmed in production:
# a Sharp tweet citing Jefferson's stat line as evidence, recommending
# Wilson vs. GB, matched Jefferson (mentioned first) and produced a reply
# about the wrong player entirely.
#
# Collects every row whose name appears in the tweet text (no break),
# scores each match (+2 if has_data_fn says this row carries real,
# non-thin data; +1 if opponent_fn says the row's opponent/team also
# appears in the tweet -- a same-tweet contextual anchor), and returns
# the single highest-scoring row. Ties keep the first match found
# (which.max's default), i.e. behave like the old code when there's
# nothing to disambiguate on.
#
# match_fn, has_data_fn, and opponent_fn all take (text_lower, row) and
# return a scalar logical; has_data_fn/opponent_fn are optional (NULL
# skips that scoring component -- e.g. CFB/golf have no per-week
# opponent field, so opponent_fn is NULL for those).
find_best_name_match <- function(text_lower, data, match_fn,
                                  has_data_fn = NULL, opponent_fn = NULL) {
  if (is.null(data) || nrow(data) == 0) return(NULL)

  hits <- vapply(seq_len(nrow(data)), function(i) {
    isTRUE(match_fn(text_lower, data[i, ]))
  }, logical(1))
  if (!any(hits)) return(NULL)

  candidates <- data[hits, , drop = FALSE]
  scores <- vapply(seq_len(nrow(candidates)), function(i) {
    row   <- candidates[i, ]
    score <- 0
    if (!is.null(has_data_fn)  && isTRUE(has_data_fn(text_lower, row)))  score <- score + 2
    if (!is.null(opponent_fn)  && isTRUE(opponent_fn(text_lower, row)))  score <- score + 1
    score
  }, numeric(1))

  candidates[which.max(scores), , drop = FALSE]
}

# Load boxscore-prophet's current-week veteran slate (QB/RB/WR/TE), if
# present and not stale. Soft-optional the same way MODEL_DATA is: a
# missing file, unreadable manifest, or a manifest older than
# BOXSCORE_MAX_AGE_DAYS (offseason, refresh mid-run, sibling repo not
# checked out) all just return NULL rather than failing the scan.
# generated_at is parsed at day granularity only (timezone offset
# dropped) -- fine for an N-day staleness check, not for anything finer.
load_veteran_slate <- function() {
  tryCatch({
    manifest     <- fromJSON(BOXSCORE_MANIFEST)
    generated_at <- str_extract(manifest$generated_at,
                                 "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}")
    generated_at <- as.POSIXct(generated_at, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    age_days     <- as.numeric(difftime(Sys.time(), generated_at, units = "days"))
    if (is.na(age_days) || age_days > BOXSCORE_MAX_AGE_DAYS) return(NULL)
    read_csv(BOXSCORE_SLATE, show_col_types = FALSE)
  }, error = function(e) NULL)
}

# Load one sport's slice of the content feature store (see
# feature-store-refresh.R), soft-optional against its shared manifest.json
# the same way load_veteran_slate() is against BOXSCORE_MANIFEST: missing
# file, unreadable manifest, no entry for this sport, or an entry older
# than FEATURE_STORE_MAX_AGE_DAYS all just return NULL.
load_feature_store <- function(sport) {
  tryCatch({
    manifest <- fromJSON(FEATURE_STORE_MANIFEST, simplifyVector = FALSE)
    entry    <- manifest[[sport]]
    if (is.null(entry)) return(NULL)
    generated_at <- str_extract(entry$generated_at,
                                 "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}")
    generated_at <- as.POSIXct(generated_at, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
    age_days     <- as.numeric(difftime(Sys.time(), generated_at, units = "days"))
    if (is.na(age_days) || age_days > FEATURE_STORE_MAX_AGE_DAYS) return(NULL)
    read_csv(file.path(FEATURE_STORE_DIR, paste0(sport, "_features.csv")), show_col_types = FALSE)
  }, error = function(e) NULL)
}

# --- Relevance scoring -------------------------------------------------------
# Tier-aware: returns the keyword score, matched article (for tracking),
# prospect match, and a should_surface decision based on the tier's rules.

score_tweet <- function(tweet, tier, model_data = NULL, veteran_data = NULL,
                         cfb_data = NULL, golf_data = NULL) {
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
      veteran_match   = FALSE,
      matched_veteran = NULL,
      cfb_match       = FALSE,
      matched_cfb     = NULL,
      golf_match      = FALSE,
      matched_golf    = NULL,
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

  # Prospect-name matching against model data (NFL draft). Full-name pass
  # first; only falls back to distinctive-last-name matching if the
  # full-name pass found nothing at all (avoids Smith/Jones collisions).
  # has_data_fn: a match only counts as "real data present" if boom/bust
  # are both populated -- mirrors the prospect_fields_valid guard applied
  # later when building the candidate. No opponent_fn -- team dev features
  # are NA pre-draft-night (feature_dictionary.md), so there's no reliable
  # opponent/team signal to disambiguate on for prospects.
  prospect_match   <- FALSE
  matched_prospect <- NULL
  if (!is.null(model_data)) {
    r1_prospects <- model_data |> filter(pick_est <= 64)
    has_prospect_data <- function(text_lower, row) !is.na(row$p_boom) && !is.na(row$p_bust)

    best <- find_best_name_match(
      text_lower, r1_prospects,
      match_fn = function(text_lower, row) str_detect(text_lower, fixed(str_to_lower(row$player_name))),
      has_data_fn = has_prospect_data
    )

    if (!is.null(best)) {
      prospect_match   <- TRUE
      matched_prospect <- best
      best_score       <- best_score + 2  # Prospect mention bonus
    } else {
      # Fallback: distinctive last names only (avoid Smith/Jones collisions)
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

      best_fallback <- find_best_name_match(
        text_lower, key_prospects,
        match_fn = function(text_lower, row) str_detect(text_lower, regex(paste0("\\b", row$last_name, "\\b"))),
        has_data_fn = has_prospect_data
      )

      if (!is.null(best_fallback)) {
        prospect_match   <- TRUE
        matched_prospect <- best_fallback |> select(-last_name)
        best_score       <- best_score + 2
      }
    }
  }

  # Veteran-name matching against boxscore-prophet's current-week slate
  # (QB/RB/WR/TE). Full-name match only, deliberately no last-name fallback
  # -- this pool is ~900 rows vs. the ~30 key draft prospects above, so a
  # surname fallback here would be a much bigger collision risk.
  # has_data_fn: prefers a row the independent NFL feature-store join
  # actually hit (rolling_epa_per_opp non-NA). opponent_fn: +1 if the
  # row's own defteam (upcoming opponent) is also named in the tweet --
  # a same-tweet contextual anchor. 2026-09-19 audit (H-3): this is the
  # fix for the confirmed Jefferson/Wilson mismatch -- a Sharp tweet
  # citing Jefferson's stat line as evidence, recommending Wilson vs. GB,
  # previously matched Jefferson (named first) instead of Wilson.
  veteran_match   <- FALSE
  matched_veteran <- NULL
  if (!is.null(veteran_data)) {
    best <- find_best_name_match(
      text_lower, veteran_data,
      match_fn = function(text_lower, row) str_detect(text_lower, fixed(str_to_lower(row$player_name))),
      has_data_fn = function(text_lower, row) {
        !is.null(row$rolling_epa_per_opp) && !is.na(row$rolling_epa_per_opp)
      },
      opponent_fn = function(text_lower, row) {
        dt <- row$defteam
        !is.null(dt) && !is.na(dt) && nzchar(dt) &&
          str_detect(text_lower, regex(paste0("\\b", str_to_lower(dt), "\\b")))
      }
    )
    if (!is.null(best)) {
      veteran_match   <- TRUE
      matched_veteran <- best
      best_score      <- best_score + 2  # Veteran mention bonus
    }
  }

  # CFB-name matching against the content feature store's current-season
  # production stats. Full-name match only, same collision reasoning as
  # veteran_match above (~2,000+ rows -- a much bigger pool than the ~30
  # key draft prospects, so no last-name fallback here either).
  # has_data_fn: prefers a row that cleared the volume floor (!low_sample)
  # over a thin-sample one. No opponent_fn -- the CFB feature store is a
  # season-aggregate pull with no per-week matchup/opponent column.
  cfb_match   <- FALSE
  matched_cfb <- NULL
  if (!is.null(cfb_data)) {
    best <- find_best_name_match(
      text_lower, cfb_data,
      match_fn = function(text_lower, row) str_detect(text_lower, fixed(str_to_lower(row$player))),
      has_data_fn = function(text_lower, row) !isTRUE(row$low_sample)
    )
    if (!is.null(best)) {
      cfb_match   <- TRUE
      matched_cfb <- best
      best_score  <- best_score + 2  # CFB mention bonus
    }
  }

  # Golf-name matching against the content feature store's skill/form
  # data. Uses player_display_name ("First Last") -- DataGolf's own
  # player_name field is "Last, First" and won't match tweet text.
  # has_data_fn: prefers a row that cleared the round-count floor
  # (!low_sample) over a thin-sample one. No opponent_fn -- stroke play
  # has no opponent concept.
  golf_match   <- FALSE
  matched_golf <- NULL
  if (!is.null(golf_data)) {
    best <- find_best_name_match(
      text_lower, golf_data,
      match_fn = function(text_lower, row) str_detect(text_lower, fixed(str_to_lower(row$player_display_name))),
      has_data_fn = function(text_lower, row) !isTRUE(row$low_sample)
    )
    if (!is.null(best)) {
      golf_match   <- TRUE
      matched_golf <- best
      best_score   <- best_score + 2  # Golf mention bonus
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
    if (has_analytical_hook(prospect_match, veteran_match, best_score,
                             cfb_match, golf_match)) {
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
    veteran_match    = veteran_match,
    matched_veteran  = matched_veteran,
    cfb_match        = cfb_match,
    matched_cfb      = matched_cfb,
    golf_match       = golf_match,
    matched_golf     = matched_golf,
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
# 2026-06-29 — Allow run to continue when total cap is exhausted if reserved
# 1A/1B slots have not yet been consumed. Without this, 1C newsbreaks can burn
# the entire daily budget and leave no room for later 1A/1B candidates.
if (!is.null(state$daily_candidate_count) &&
    state$daily_candidate_count >= MAX_CANDIDATES_PER_DAY) {
  if (sum(remaining_reserved_slots(state)) <= 0L) {
    cat("[]")
    quit(save = "no")
  }
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

# Load boxscore-prophet's veteran slate for veteran-name matching
veteran_data <- load_veteran_slate()

# Content feature store (feature-store-refresh.R's daily pull). NFL's raw
# features supplement boxscore-prophet's p_start/p_boom probabilities
# rather than replacing them (2026-09-18 chat) -- joined on player_id,
# which both boxscore-prophet and nflreadr derive from the same nflverse
# id scheme. CFB and golf have no existing slate to join onto, so they
# stay as their own data frames and get their own match block in
# score_tweet().
nfl_feature_store <- load_feature_store("nfl")
cfb_data          <- load_feature_store("cfb")
golf_data         <- load_feature_store("golf")

if (!is.null(veteran_data) && !is.null(nfl_feature_store)) {
  veteran_data <- veteran_data |>
    left_join(
      nfl_feature_store |>
        select(player_id, rolling_epa_per_opp, epa_per_opp_pctile,
               season_target_share, target_share_pctile, low_sample) |>
        rename(nfl_low_sample = low_sample),
      by = "player_id"
    )
  if (mean(!is.na(veteran_data$rolling_epa_per_opp)) == 0) {
    message("WARN: NFL feature-store join matched 0 rows against boxscore-prophet's veteran slate -- check player_id compatibility between the two sources")
  }
}

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

    scoring <- score_tweet(tweet, tier, model_data, veteran_data, cfb_data, golf_data)
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
      veteran_match        = scoring$veteran_match,
      cfb_match            = scoring$cfb_match,
      golf_match           = scoring$golf_match,
      reason               = scoring$reason,
      engagement_status    = if (is_engaged) "engaged" else "cold",
      can_reply_via_api    = is_engaged,
      draft_style          = draft_style,
      draft_prompt_path    = file.path("prompts", paste0("x_reply_", draft_style, ".md"))
    )

    if (scoring$prospect_match && !is.null(scoring$matched_prospect)) {
      mp <- scoring$matched_prospect
      # 2026-08-31 -- guard against NA fields in a matched row leaking into
      # candidate JSON as if they were real data (see x-monitor-feedback
      # "Cooper Jr." incident review: prospect_match was FALSE for that
      # tweet, so this specific case wasn't caused by this path, but the
      # invariant -- prospect fields only ever come from a real matched
      # row -- was previously unenforced).
      prospect_fields_valid <- !is.na(mp$player_name) && !is.na(mp$p_boom) &&
        !is.na(mp$p_bust)
      if (prospect_fields_valid) {
        candidate$prospect_name     <- mp$player_name
        candidate$prospect_position <- mp$position
        candidate$prospect_school   <- mp$school
        candidate$prospect_boom     <- mp$p_boom
        candidate$prospect_bust     <- mp$p_bust
        candidate$prospect_verdict  <- mp$model_verdict
      } else {
        message(glue(
          "WARN: prospect_match=TRUE for tweet {tweet$id} but matched row ",
          "has NA fields (player_name={mp$player_name %||% 'NA'}) -- ",
          "dropping prospect data from candidate"
        ))
      }
    }

    if (scoring$veteran_match && !is.null(scoring$matched_veteran)) {
      mv <- scoring$matched_veteran
      # Same NA-field guard as the prospect block above. 2026-09-19 audit
      # (M-1) -- p_boom_recal added: it's the specific field the drafting
      # payload cites as "boom %", but it wasn't previously guarded, so a
      # calibration miss (recal_method_boom NA for an edge player) let a
      # null leak into candidate JSON and the model either invented a
      # number or literally wrote "null%".
      veteran_fields_valid <- !is.na(mv$player_name) && !is.na(mv$p_start) &&
        !is.na(mv$pred_tot) && !is.na(mv$p_boom_recal)
      if (veteran_fields_valid) {
        candidate$veteran_name         <- mv$player_name
        candidate$veteran_position     <- mv$position
        candidate$veteran_team         <- mv$posteam
        candidate$veteran_p_start      <- mv$p_start
        candidate$veteran_p_boom       <- mv$p_boom
        candidate$veteran_p_boom_recal <- mv$p_boom_recal
        candidate$veteran_pred_tot     <- mv$pred_tot
        # pred_vol dropped (2026-09-19 audit, M-1) -- confirmed unreferenced
        # in every prompt file and in x-fact-check.R/x-length-check.R.

        # 2026-09-18 -- supplement (not replace, per chat) with raw content
        # features from the independent NFL feature-store pull, joined onto
        # this row by player_id above. Only present when that join hit --
        # mv$rolling_epa_per_opp is NULL (not just NA) if nfl_feature_store
        # was itself unavailable, so check existence before is.na().
        if (!is.null(mv$rolling_epa_per_opp) && !is.na(mv$rolling_epa_per_opp)) {
          candidate$veteran_epa_per_opp         <- round(mv$rolling_epa_per_opp, 3)
          candidate$veteran_epa_per_opp_pctile  <- round(mv$epa_per_opp_pctile, 2)
          candidate$veteran_target_share        <- round(mv$season_target_share, 3)
          candidate$veteran_target_share_pctile <- round(mv$target_share_pctile, 2)
          candidate$veteran_low_sample          <- mv$nfl_low_sample
        }
      } else {
        message(glue(
          "WARN: veteran_match=TRUE for tweet {tweet$id} but matched row ",
          "has NA fields (player_name={mv$player_name %||% 'NA'}) -- ",
          "dropping veteran data from candidate"
        ))
      }
    }

    if (scoring$cfb_match && !is.null(scoring$matched_cfb)) {
      mc <- scoring$matched_cfb
      cfb_fields_valid <- !is.na(mc$player)
      if (cfb_fields_valid) {
        candidate$cfb_name       <- mc$player
        candidate$cfb_team       <- mc$team
        candidate$cfb_position   <- mc$position
        candidate$cfb_low_sample <- mc$low_sample
        if (mc$position == "QB" && !is.na(mc$qb_ypa)) {
          candidate$cfb_qb_ypa_pctile     <- round(mc$qb_ypa_pctile, 2)
          candidate$cfb_qb_cmp_pct_pctile <- round(mc$qb_cmp_pct_pctile, 2)
          candidate$cfb_qb_int_pct_pctile <- round(mc$qb_int_pct_pctile, 2)
        } else if (mc$position == "RB" && !is.na(mc$rush_ypc)) {
          candidate$cfb_rush_ypc_pctile <- round(mc$rush_ypc_pctile, 2)
        } else if (mc$position == "WR" && !is.na(mc$rec_ypr)) {
          candidate$cfb_rec_ypr_pctile <- round(mc$rec_ypr_pctile, 2)
        }
      } else {
        message(glue(
          "WARN: cfb_match=TRUE for tweet {tweet$id} but matched row ",
          "has NA player -- dropping CFB data from candidate"
        ))
      }
    }

    if (scoring$golf_match && !is.null(scoring$matched_golf)) {
      mg <- scoring$matched_golf
      golf_fields_valid <- !is.na(mg$player_display_name) && !is.na(mg$player_skill_prior)
      if (golf_fields_valid) {
        candidate$golf_name             <- mg$player_display_name
        candidate$golf_n_rounds         <- mg$n_prior_rounds
        candidate$golf_low_sample       <- mg$low_sample
        candidate$golf_skill_pctile     <- round(mg$player_skill_pctile, 2)
        candidate$golf_sg_ott_pctile    <- round(mg$sg_ott_pctile, 2)
        candidate$golf_sg_app_pctile    <- round(mg$sg_app_pctile, 2)
        candidate$golf_sg_arg_pctile    <- round(mg$sg_arg_pctile, 2)
        candidate$golf_sg_putt_pctile   <- round(mg$sg_putt_pctile, 2)
        candidate$golf_form_trend_pctile <- round(mg$form_trend_pctile, 2)
      } else {
        message(glue(
          "WARN: golf_match=TRUE for tweet {tweet$id} but matched row ",
          "has NA fields -- dropping golf data from candidate"
        ))
      }
    }

    candidate$model_data <- format_model_data(candidate)
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
  combined        <- c(engaged_candidates, cold_candidates)
  surfaced_today  <- state$daily_candidate_count %||% 0
  remaining_total <- max(MAX_CANDIDATES_PER_DAY - surfaced_today, 0)
  # When total cap is exhausted but reserved slots remain, use reserved budget
  # so select_candidates_with_reservations doesn't bail at remaining_total <= 0.
  if (remaining_total == 0L) {
    remaining_total <- sum(remaining_reserved_slots(state))
  }
  candidates      <- select_candidates_with_reservations(combined, remaining_total, state)
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
