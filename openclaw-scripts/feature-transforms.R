# feature-transforms.R -- shared content-feature helpers for the feature-store
# pipeline (feature-store-refresh.R) and x-monitor.R.
#
# 2026-09-18 -- initial version: pctile_rank() + format_pctile_stat(), the
#               percentile-rank transform agreed on for turning raw GBDT
#               units (EPA/opp, SG residual slope, etc.) into narratable
#               X-post stats. See nfl-draft-model/feature_dictionary.md for
#               the pattern this mirrors (percentile rank within cohort).

suppressPackageStartupMessages(library(glue))

# Percentile-rank a raw feature within its cohort (same position + week,
# same draft class + position group, same golf field -- whatever grouping
# the caller passes in via a pre-split vector). Raw model units aren't
# narratable on their own -- "0.14 EPA/opp" or "-0.03 residual slope" means
# nothing in a reply without knowing where it sits relative to peers.
#
# higher_is_better = FALSE sign-flips the rank for stats where lower is
# better (INT rate, 40 time) -- mirrors nfl-draft-model's qb_int_pct_pctile
# sign-flip so "80th percentile" always reads as "80th percentile good."
#
# Returns NA (not a noisy percentile) when the cohort has fewer than
# min_cohort_n non-missing values -- a percentile computed on 3 players
# isn't something to put in a tweet.
pctile_rank <- function(x, higher_is_better = TRUE, min_cohort_n = 8) {
  n_valid <- sum(!is.na(x))
  if (n_valid < min_cohort_n) return(rep(NA_real_, length(x)))

  r   <- rank(x, na.last = "keep", ties.method = "average")
  pct <- (r - 1) / (n_valid - 1)
  if (!higher_is_better) pct <- 1 - pct
  pct
}

# Format a (label, raw value, percentile) triple into a single display line
# for {model_data} in the reply prompts. Returns NULL (not a string) when
# the percentile is NA, so callers can drop it from the prompt with
# `purrr::compact()` instead of leaking a "NA percentile" line into a draft.
format_pctile_stat <- function(label, value, pctile, digits = 2) {
  if (is.na(pctile)) return(NULL)
  glue("{label}: {round(value, digits)} ({round(pctile * 100)}th percentile)")
}
