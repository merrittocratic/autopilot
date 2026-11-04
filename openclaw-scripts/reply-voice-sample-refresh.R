#!/usr/bin/env Rscript
# ============================================================================
# reply-voice-sample-refresh.R -- cache Steve's best hand-written X replies
# as few-shot voice examples for the reply-draft prompts
# ============================================================================
# 2026-11-04 -- Initial version. The 2026-11-04 reply review found the
#               drafts copied the explainer register of the Substack
#               excerpts in voice_sample.txt ("Stat Nerd alert!"), while
#               Steve's own replies -- the ones that actually get traction --
#               are blunt, sarcastic, take a side, and often run past 240
#               characters. This file replaces {voice_sample} with
#               {reply_voice_sample} in prompts/x_reply_tier_*.md.
#
# Pulls @Merrittocratic's recent posts (up to 200), keeps replies to other
# accounts, ranks by engagement, and writes the top N as
# "they posted / Steve replied" pairs to
# data/voice-sample/reply_voice_sample.txt.
#
# Cache-friendly like voice-sample-refresh.R: output is deterministic for a
# given selected set (sorted by tweet id, no timestamps in the file), and
# the file is only rewritten when that set or its text changes. Earnest
# pastes the content verbatim into the stable prefix of every reply prompt.
#
# Needs X OAuth 1.0a credentials -> run via scripts/autopilot-env.sh.
# Scheduled weekly by deploy/launchd/com.merritt.autopilot.reply-voice-sample.plist.
#
# Usage:
#   Rscript reply-voice-sample-refresh.R            # refresh if changed
#   Rscript reply-voice-sample-refresh.R --dry-run  # print, don't write
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(glue)
  library(cli)
  library(digest)
})

HOME_DIR      <- Sys.getenv("HOME")
AUTOPILOT     <- file.path(HOME_DIR, "autopilot")
OUT_DIR       <- file.path(AUTOPILOT, "data", "voice-sample")
OUT_FILE      <- file.path(OUT_DIR, "reply_voice_sample.txt")
MANIFEST_PATH <- file.path(OUT_DIR, "reply_manifest.json")

N_EXAMPLES    <- 25    # enough range across registers, small enough to read
MAX_PAGES     <- 2     # 100 posts per page
MIN_REPLY_CHR <- 12    # keeps one-liners like "Ask Jeremiyah Love...."
PARENT_CHR    <- 280   # parent tweet is context, not the example

DRY_RUN <- "--dry-run" %in% commandArgs(trailingOnly = TRUE)

# --- Auth (same OAuth 1.0a pattern as x-monitor.R) ----------------------------
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

# --- Fetch -------------------------------------------------------------------
fetch_own_posts <- function(token) {
  me <- GET("https://api.twitter.com/2/users/me", config(token = token))
  if (status_code(me) != 200) stop(glue("X /users/me failed: {status_code(me)}"))
  uid <- content(me)$data$id

  posts <- list(); parents <- list(); users <- list()
  next_token <- NULL
  for (page in seq_len(MAX_PAGES)) {
    query <- list(
      max_results    = "100",
      exclude        = "retweets",
      "tweet.fields" = "created_at,public_metrics,referenced_tweets",
      expansions     = "referenced_tweets.id,referenced_tweets.id.author_id",
      "user.fields"  = "username"
    )
    if (!is.null(next_token)) query$pagination_token <- next_token
    resp <- GET(glue("https://api.twitter.com/2/users/{uid}/tweets"),
                config(token = token), query = query)
    if (status_code(resp) != 200) {
      if (page == 1) stop(glue("X timeline fetch failed: {status_code(resp)}"))
      break
    }
    body <- content(resp)
    posts   <- c(posts, body$data %||% list())
    parents <- c(parents, body$includes$tweets %||% list())
    users   <- c(users, body$includes$users %||% list())
    next_token <- body$meta$next_token
    if (is.null(next_token)) break
  }
  list(uid = uid, posts = posts, parents = parents, users = users)
}

# Leading @mentions are reply plumbing, and trailing t.co links are media
# Steve attached -- neither is voice.
clean_text <- function(x) {
  x |>
    str_remove("^(@\\w+\\s+)+") |>
    str_remove_all("\\s*https://t\\.co/\\w+") |>
    str_replace_all("&amp;", "&") |>
    str_replace_all("&gt;", ">") |>
    str_replace_all("&lt;", "<") |>
    str_squish()
}

build_examples <- function(fetched) {
  parent_by_id <- set_names(fetched$parents, map_chr(fetched$parents, "id"))
  user_by_id   <- set_names(map_chr(fetched$users, "username"), map_chr(fetched$users, "id"))

  rows <- map(fetched$posts, function(p) {
    ref <- keep(p$referenced_tweets %||% list(), ~ identical(.x$type, "replied_to"))
    if (length(ref) == 0) return(NULL)
    parent <- parent_by_id[[ref[[1]]$id]]
    if (is.null(parent) || identical(parent$author_id, fetched$uid)) return(NULL)
    m <- p$public_metrics
    tibble(
      tweet_id    = p$id,
      parent_user = unname(user_by_id[parent$author_id]) %||% "unknown",
      parent_text = str_trunc(clean_text(parent$text), PARENT_CHR),
      reply_text  = clean_text(p$text),
      likes       = m$like_count %||% 0,
      retweets    = m$retweet_count %||% 0,
      replies     = m$reply_count %||% 0,
      impressions = m$impression_count %||% 0
    )
  })
  bind_rows(rows)
}

# --- Main --------------------------------------------------------------------
cli_h1("Reply voice sample refresh")

fetched  <- fetch_own_posts(build_token())
examples <- build_examples(fetched)
if (nrow(examples) == 0) {
  cli_alert_warning("No replies found -- leaving any existing {basename(OUT_FILE)} untouched")
  quit(save = "no")
}

# Replies-to-Steve count most: a reply that starts an argument is the
# behavior we want the drafts to copy.
selected <- examples |>
  filter(nchar(reply_text) >= MIN_REPLY_CHR) |>
  mutate(score = likes + 3 * replies + 2 * retweets + impressions / 1000) |>
  slice_max(score, n = N_EXAMPLES, with_ties = FALSE) |>
  arrange(desc(tweet_id))

blocks <- glue_data(
  selected,
  "They posted (@{parent_user}): {parent_text}\nSteve replied: {reply_text}"
)
candidate_text <- paste(blocks, collapse = "\n\n")
candidate_hash <- digest(candidate_text, algo = "sha256")

if (DRY_RUN) {
  cat(candidate_text, "\n")
  cli_alert_info("Dry run: {nrow(selected)} examples, {nchar(candidate_text)} chars, not written")
  quit(save = "no")
}

dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)
previous <- tryCatch(fromJSON(MANIFEST_PATH, simplifyVector = FALSE), error = function(e) NULL)
if (!is.null(previous) && identical(previous$content_hash, candidate_hash) && file.exists(OUT_FILE)) {
  cli_alert_info("Selected replies unchanged -- {basename(OUT_FILE)} left as-is (no cache-breaking rewrite)")
  quit(save = "no")
}

writeLines(candidate_text, OUT_FILE)
write(toJSON(list(
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  content_hash = candidate_hash,
  n_examples   = nrow(selected),
  n_replies_seen = nrow(examples),
  tweet_ids    = selected$tweet_id
), auto_unbox = TRUE, pretty = TRUE), MANIFEST_PATH)

cli_alert_success("{OUT_FILE} rewritten ({nrow(selected)} examples)")
