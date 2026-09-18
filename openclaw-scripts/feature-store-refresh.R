#!/usr/bin/env Rscript
# ============================================================================
# feature-store-refresh.R — Daily content-feature pull (NFL / CFB / Golf)
# ============================================================================
# Once-a-day pull of raw model-adjacent stats for X-reply content, sourced
# independently per sport (nflreadr, cfbfastR, DataGolf) rather than reading
# nfl-draft-model's / shadow-leaderboard's / boxscore-prophet's own outputs --
# same feature vocabulary as those repos (see feature_dictionary.md and
# 03_model_spec.R in each), recomputed here as a lightweight content-only
# pull with its own daily cadence, decoupled from x-monitor.R's 15-minute
# check loop so that cadence never hits CFBD's rate limit or DataGolf's
# metered quota (see 2026-09-18 chat: "one consistent feature-store
# pipeline" decision).
#
# Each sport's pull is independently try-caught and writes its own CSV +
# manifest entry -- one provider being down/rate-limited/unauthenticated
# never blocks the other two, same soft-optional contract x-monitor.R
# already uses for load_veteran_slate().
#
# NOT YET WIRED: x-monitor.R does not read data/feature-store/ yet. That's
# the next step (load_feature_store(sport), mirroring load_veteran_slate()'s
# age-check/tryCatch pattern) once this has run cleanly against live data.
#
# 2026-09-18 -- initial version. Written and reasoned from nfl-draft-model's
#               feature_dictionary.md / 01c_load_college_stats.R and
#               shadow-leaderboard's 03_model_spec.R (Context + In-round
#               feature groups dropped from golf per 2026-09-18 chat) --
#               NOT yet run against live data (no network access at
#               write-time). Run manually once before wiring into cron;
#               column names assumed from each package's documented/typical
#               schema may need adjustment against the installed version.
#
# Usage:
#   Rscript feature-store-refresh.R
# ============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(readr)
  library(purrr)
  library(glue)
  library(jsonlite)
  library(cli)
  library(httr2)
})

`%||%` <- function(a, b) if (is.null(a)) b else a

HOME_DIR  <- Sys.getenv("HOME")
AUTOPILOT <- file.path(HOME_DIR, "autopilot")
source(file.path(AUTOPILOT, "openclaw-scripts", "feature-transforms.R"))

STORE_DIR     <- file.path(AUTOPILOT, "data", "feature-store")
MANIFEST_PATH <- file.path(STORE_DIR, "manifest.json")
dir.create(STORE_DIR, showWarnings = FALSE, recursive = TRUE)

# Shared floor for pctile_rank() across all three sports -- a percentile
# computed on fewer than this many peers doesn't belong in a tweet.
MIN_COHORT_N <- 8

# --- Manifest ----------------------------------------------------------------
# One shared file, one entry per sport, so each sport ages out independently
# (golf only matters during tournament weeks; NFL/CFB refresh weekly-ish
# during their seasons) -- same generated_at/age-check contract x-monitor.R
# already applies to BOXSCORE_MANIFEST.

read_manifest <- function() {
  if (!file.exists(MANIFEST_PATH)) return(list())
  tryCatch(fromJSON(MANIFEST_PATH, simplifyVector = FALSE), error = function(e) list())
}

write_manifest_entry <- function(sport, extra = list()) {
  manifest <- read_manifest()
  manifest[[sport]] <- c(
    list(generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    extra
  )
  write(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE, null = "null"), MANIFEST_PATH)
}

# ============================================================================
# NFL — nflreadr (no key required)
# ============================================================================
# Mirrors boxscore-prophet's volume/efficiency split (baseline_epa_per_opp,
# rolling_epa_per_opp, target_share) but computed independently from
# nflreadr::load_player_stats() rather than reading boxscore-prophet's own
# (deliberately slimmed) scored_slate.csv -- see MODEL_BRIDGE.md discussion,
# 2026-09-18 chat.

refresh_nfl_features <- function(season = NULL) {
  cli_h1("NFL feature pull")
  library(nflreadr)

  if (is.null(season)) season <- nflreadr::most_recent_season()

  stats <- tryCatch(
    nflreadr::load_player_stats(seasons = season, summary_level = "week"),
    error = function(e) {
      cli_alert_warning("nflreadr pull failed: {conditionMessage(e)}")
      NULL
    }
  )
  if (is.null(stats) || nrow(stats) == 0) {
    cli_alert_warning("No NFL player-week rows for {season} -- skipping")
    return(invisible(NULL))
  }

  if ("season_type" %in% names(stats)) stats <- stats |> filter(season_type == "REG")
  stats <- stats |> filter(position %in% c("QB", "RB", "WR", "TE", "FB"))
  if (nrow(stats) == 0) {
    cli_alert_warning("No REG-season offensive rows for {season} -- skipping")
    return(invisible(NULL))
  }

  latest_week  <- max(stats$week, na.rm = TRUE)
  window_start <- max(1, latest_week - 7)   # trailing ~8-week form window

  recent <- stats |>
    filter(week >= window_start, week <= latest_week) |>
    mutate(
      position      = if_else(position == "FB", "RB", position),
      opportunities = case_when(
        position == "QB" ~ coalesce(attempts, 0),
        position == "RB" ~ coalesce(carries, 0) + coalesce(targets, 0),
        TRUE              ~ coalesce(targets, 0)
      ),
      epa_total = coalesce(passing_epa, 0) + coalesce(rushing_epa, 0) + coalesce(receiving_epa, 0),
      epa_per_opp_obs = if_else(opportunities > 0, epa_total / opportunities, NA_real_)
    )

  form <- recent |>
    group_by(player_id) |>
    summarise(
      n_games_recent      = n(),
      rolling_epa_per_opp = mean(epa_per_opp_obs, na.rm = TRUE),
      .groups = "drop"
    )

  season_totals <- stats |>
    mutate(position = if_else(position == "FB", "RB", position)) |>
    group_by(player_id) |>
    summarise(
      player_name            = dplyr::last(player_display_name),
      position                = dplyr::last(position),
      team                     = dplyr::last(team),
      season_target_share      = mean(target_share, na.rm = TRUE),
      season_air_yards_share   = mean(air_yards_share, na.rm = TRUE),
      .groups = "drop"
    )

  nfl_features <- season_totals |>
    left_join(form, by = "player_id") |>
    filter(!is.na(rolling_epa_per_opp), is.finite(rolling_epa_per_opp)) |>
    group_by(position) |>
    mutate(
      epa_per_opp_pctile   = pctile_rank(rolling_epa_per_opp, min_cohort_n = MIN_COHORT_N),
      target_share_pctile  = pctile_rank(season_target_share, min_cohort_n = MIN_COHORT_N,
                                          higher_is_better = TRUE)
    ) |>
    ungroup() |>
    # 2026-09-18 -- flag (not filter) thin-sample players. A 1-2 game trailing
    # window can land at a real percentile purely from a hot/cold single game
    # -- rather than the feature store deciding that's not worth reporting,
    # this leaves the number in place and marks it, so the reply-drafting
    # step can choose to deprioritize/skip a low-confidence stat itself.
    mutate(low_sample = n_games_recent < 3) |>
    mutate(season = season, week = latest_week)

  out_path <- file.path(STORE_DIR, "nfl_features.csv")
  write_csv(nfl_features, out_path)
  write_manifest_entry("nfl", list(rows = nrow(nfl_features), season = season, week = latest_week))
  cli_alert_success("{out_path} ({nrow(nfl_features)} rows)")
  invisible(nfl_features)
}

# ============================================================================
# CFB — cfbfastR (CFBD_API_KEY required)
# ============================================================================
# Season-to-date production ratios, mirroring nfl-draft-model's "College
# Production" feature block (feature_dictionary.md) -- percentile-ranked
# within (season x position) instead of (draft-year x position group), since
# this is in-season current production, not a draft-class comparison.
#
# Deliberately NOT included in this first pass (nfl-draft-model has these,
# but they need more machinery than a daily content pull warrants):
# YoY trajectory (needs prior-season merge), domination/share-of-team
# (needs a team-stats join), program pipeline (multi-year leave-one-out),
# athleticism/combine (not applicable in-season). Flag if any of these turn
# out to matter for content -- straightforward to add once this baseline
# is confirmed working against live data.

refresh_cfb_features <- function(season = NULL) {
  cli_h1("CFB feature pull")
  key <- Sys.getenv("CFBD_API_KEY", unset = "")
  if (key == "") {
    cli_alert_warning("CFBD_API_KEY not set -- skipping CFB feature pull")
    return(invisible(NULL))
  }

  library(cfbfastR)
  if (is.null(season)) season <- as.integer(format(Sys.Date(), "%Y"))

  categories <- c("passing", "rushing", "receiving")
  raw <- map(categories, function(cat) {
    tryCatch(
      cfbfastR::cfbd_stats_season_player(year = season, season_type = "regular", category = cat),
      error = function(e) {
        cli_alert_warning("cfbfastR pull failed for {cat} {season}: {conditionMessage(e)}")
        NULL
      }
    )
  })

  raw_all <- bind_rows(raw)
  if (nrow(raw_all) == 0) {
    cli_alert_warning("No CFB stats returned for {season} -- skipping")
    return(invisible(NULL))
  }
  if ("athlete_id" %in% names(raw_all)) {
    raw_all <- raw_all |> distinct(athlete_id, .keep_all = TRUE)
  }

  # Volume floors -- a 1-attempt garbage-time snap shouldn't get a real
  # percentile (and shouldn't dilute the cohort for players who do).
  passing <- raw_all |>
    filter(!is.na(passing_att), passing_att >= 10) |>
    transmute(
      athlete_id, player, team, position = "QB",
      qb_att = passing_att, qb_comp = passing_completions,
      qb_pass_yds = passing_yds, qb_pass_td = passing_td, qb_int = passing_int
    ) |>
    mutate(
      qb_cmp_pct = qb_comp / qb_att,
      qb_ypa     = qb_pass_yds / qb_att,
      qb_td_pct  = qb_pass_td / qb_att,
      qb_int_pct = qb_int / qb_att,
      qb_cmp_pct_pctile = pctile_rank(qb_cmp_pct, min_cohort_n = MIN_COHORT_N),
      qb_ypa_pctile     = pctile_rank(qb_ypa,     min_cohort_n = MIN_COHORT_N),
      qb_td_pct_pctile  = pctile_rank(qb_td_pct,  min_cohort_n = MIN_COHORT_N),
      qb_int_pct_pctile = pctile_rank(qb_int_pct, min_cohort_n = MIN_COHORT_N, higher_is_better = FALSE),
      # No per-game count from this endpoint (season totals only) -- this is
      # a volume rule of thumb (roughly 4 games' worth), not a game count.
      low_sample = qb_att < 60
    )

  rushing <- raw_all |>
    filter(!is.na(rushing_car), rushing_car >= 5) |>
    transmute(athlete_id, player, team, position = "RB",
              rush_att = rushing_car, rush_yds = rushing_yds) |>
    mutate(
      rush_ypc = rush_yds / rush_att,
      rush_ypc_pctile = pctile_rank(rush_ypc, min_cohort_n = MIN_COHORT_N),
      low_sample = rush_att < 30
    )

  receiving <- raw_all |>
    filter(!is.na(receiving_rec), receiving_rec >= 3) |>
    transmute(athlete_id, player, team, position = "WR",
              rec_rec = receiving_rec, rec_yds = receiving_yds) |>
    mutate(
      rec_ypr = rec_yds / pmax(rec_rec, 1),
      rec_ypr_pctile = pctile_rank(rec_ypr, min_cohort_n = MIN_COHORT_N),
      low_sample = rec_rec < 8
    )

  cfb_features <- bind_rows(passing, rushing, receiving) |>
    mutate(season = season)

  out_path <- file.path(STORE_DIR, "cfb_features.csv")
  write_csv(cfb_features, out_path)
  write_manifest_entry("cfb", list(rows = nrow(cfb_features), season = season))
  cli_alert_success("{out_path} ({nrow(cfb_features)} rows)")
  invisible(cfb_features)
}

# ============================================================================
# Golf — DataGolf (GOLF_API_KEY required)
# ============================================================================
# Content-simplified version of shadow-leaderboard's skill priors + form
# features (03_model_spec.R), Context and In-round groups dropped per
# 2026-09-18 chat. shadow-leaderboard's player_skill_prior/sg_*_prior use a
# leave-one-out, lagged multi-year expanding mean to avoid data leakage in
# a trained model -- that discipline doesn't apply here (we're describing
# current form for a tweet, not predicting an outcome), so this uses a
# plain season-to-date mean instead. form_residual_mean_8 mirrors the
# model's definition: trailing-8-round SG Total average minus the player's
# own season baseline (positive = playing above their own established level).
#
# Confirmed via live pull (2026-09-18): historical-raw-data/rounds returns
# an object keyed by event_id, each event carrying event_name/event_completed
# + a `scores` array of players, each player nesting round_1..round_4
# objects with the actual sg_ott/sg_app/sg_arg/sg_putt/sg_total fields.
# flatten_dg_rounds() below reshapes that into one row per player-round.

.dg_get <- function(path, params, api_key, simplify = TRUE) {
  params[["key"]] <- api_key
  req <- request("https://feeds.datagolf.com") |>
    req_url_path_append(path) |>
    req_url_query(!!!params) |>
    req_error(is_error = \(resp) FALSE)
  resp <- req_perform(req)
  if (resp_status(resp) != 200L) {
    cli_abort("DataGolf API returned HTTP {resp_status(resp)} for {path}")
  }
  resp_body_json(resp, simplifyVector = simplify)
}

# historical-raw-data/rounds is a nested object (event -> scores -> round_N),
# not a flat table -- reshape to one row per player-round.
flatten_dg_rounds <- function(raw) {
  if (is.null(raw) || length(raw) == 0) return(tibble())

  map_dfr(raw, function(event) {
    if (is.null(event$scores) || length(event$scores) == 0) return(NULL)
    map_dfr(event$scores, function(player) {
      round_keys <- grep("^round_\\d+$", names(player), value = TRUE)
      map_dfr(round_keys, function(rk) {
        r <- player[[rk]]
        if (is.null(r) || is.null(r$sg_total)) return(NULL)
        tibble(
          dg_id           = player$dg_id,
          player_name     = player$player_name,
          event_name      = event$event_name %||% NA_character_,
          event_completed = event$event_completed %||% NA_character_,
          round           = as.integer(sub("^round_", "", rk)),
          sg_total        = as.numeric(r$sg_total),
          sg_ott          = as.numeric(r$sg_ott %||% NA_real_),
          sg_app          = as.numeric(r$sg_app %||% NA_real_),
          sg_arg          = as.numeric(r$sg_arg %||% NA_real_),
          sg_putt         = as.numeric(r$sg_putt %||% NA_real_)
        )
      })
    })
  })
}

refresh_golf_features <- function(tour = "pga") {
  cli_h1("Golf feature pull")
  key <- Sys.getenv("GOLF_API_KEY", unset = "")
  if (key == "") {
    cli_alert_warning("GOLF_API_KEY not set -- skipping golf feature pull")
    return(invisible(NULL))
  }

  season <- as.integer(format(Sys.Date(), "%Y"))
  rounds_raw <- tryCatch(
    .dg_get("historical-raw-data/rounds",
            list(tour = tour, event_id = "all", year = season, file_format = "json"),
            api_key = key, simplify = FALSE),
    error = function(e) {
      cli_alert_warning("DataGolf pull failed: {conditionMessage(e)}")
      NULL
    }
  )
  rounds <- tryCatch(flatten_dg_rounds(rounds_raw), error = function(e) {
    cli_alert_warning("DataGolf response parsing failed: {conditionMessage(e)}")
    tibble()
  })
  if (nrow(rounds) == 0) {
    cli_alert_warning("No usable DataGolf rounds for {season} -- skipping")
    return(invisible(NULL))
  }

  rounds <- rounds |>
    filter(!is.na(sg_total)) |>
    arrange(dg_id, event_completed, round)

  season_avg <- rounds |>
    group_by(dg_id) |>
    summarise(
      player_name          = dplyr::last(player_name),
      n_prior_rounds       = n(),
      player_skill_prior   = mean(sg_total, na.rm = TRUE),
      sg_ott_prior         = mean(sg_ott,  na.rm = TRUE),
      sg_app_prior         = mean(sg_app,  na.rm = TRUE),
      sg_arg_prior         = mean(sg_arg,  na.rm = TRUE),
      sg_putt_prior        = mean(sg_putt, na.rm = TRUE),
      .groups = "drop"
    ) |>
    filter(n_prior_rounds >= 4)

  recent_form <- rounds |>
    group_by(dg_id) |>
    slice_tail(n = 8) |>
    mutate(round_idx = row_number()) |>
    summarise(
      form_ott_mean_8   = mean(sg_ott,  na.rm = TRUE),
      form_app_mean_8   = mean(sg_app,  na.rm = TRUE),
      form_arg_mean_8   = mean(sg_arg,  na.rm = TRUE),
      form_putt_mean_8  = mean(sg_putt, na.rm = TRUE),
      form_putt_sd_8    = sd(sg_putt,   na.rm = TRUE),
      form_total_mean_8 = mean(sg_total, na.rm = TRUE),
      form_residual_slope_8 = if (n() >= 4) {
        tryCatch(coef(lm(sg_total ~ round_idx))[["round_idx"]], error = function(e) NA_real_)
      } else NA_real_,
      .groups = "drop"
    )

  golf_features <- season_avg |>
    left_join(recent_form, by = "dg_id") |>
    mutate(form_residual_mean_8 = form_total_mean_8 - player_skill_prior) |>
    mutate(
      player_skill_pctile = pctile_rank(player_skill_prior,   min_cohort_n = MIN_COHORT_N),
      sg_ott_pctile        = pctile_rank(sg_ott_prior,          min_cohort_n = MIN_COHORT_N),
      sg_app_pctile        = pctile_rank(sg_app_prior,          min_cohort_n = MIN_COHORT_N),
      sg_arg_pctile        = pctile_rank(sg_arg_prior,          min_cohort_n = MIN_COHORT_N),
      sg_putt_pctile       = pctile_rank(sg_putt_prior,         min_cohort_n = MIN_COHORT_N),
      form_trend_pctile    = pctile_rank(form_residual_mean_8,  min_cohort_n = MIN_COHORT_N),
      # Matches MIN_COHORT_N -- fewer rounds than the cohort-size floor
      # itself isn't enough of a player's own history to trust.
      low_sample           = n_prior_rounds < MIN_COHORT_N,
      # DataGolf returns "Last, First" -- x-monitor.R matches against tweet
      # text, which says "First Last". Normalize here (data-shape concern),
      # not in the matching code.
      player_display_name  = trimws(paste(
        trimws(sub("^[^,]+,\\s*", "", player_name)),
        trimws(sub(",.*$", "", player_name))
      ))
    ) |>
    mutate(season = season, tour = tour)

  out_path <- file.path(STORE_DIR, "golf_features.csv")
  write_csv(golf_features, out_path)
  write_manifest_entry("golf", list(rows = nrow(golf_features), season = season, tour = tour))
  cli_alert_success("{out_path} ({nrow(golf_features)} rows)")
  invisible(golf_features)
}

# ============================================================================
# Main -- each sport independently try-caught, one failure never blocks
# the others (same soft-optional contract as x-monitor.R's model reads).
# ============================================================================

cli_h1("Feature store refresh")

for (sport in c("nfl", "cfb", "golf")) {
  fn <- switch(sport,
    nfl  = refresh_nfl_features,
    cfb  = refresh_cfb_features,
    golf = refresh_golf_features
  )
  tryCatch(
    fn(),
    error = function(e) cli_alert_danger("{sport} feature pull failed: {conditionMessage(e)}")
  )
}

cli_alert_success("Feature store refresh complete")
