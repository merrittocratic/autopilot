#!/usr/bin/env Rscript
# post-single-tweet.R — Post a single approved tweet directly to X
# Usage: Rscript post-single-tweet.R "tweet text here"

# Load secrets from keychain before anything else
env_out <- system("bash -c 'source ~/autopilot/scripts/autopilot-env.sh && env'", intern = TRUE)
for (line in env_out) {
  parts <- strsplit(line, "=", fixed = TRUE)[[1]]
  if (length(parts) >= 2) {
    key <- parts[1]
    val <- paste(parts[-1], collapse = "=")
    if (grepl("^(X_|ANTHROPIC_|REVIEW_SHEET)", key)) {
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
}

library(here)
source(here::here("R", "00_config.R"))
source(here::here("R", "05_post_to_x.R"))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 0 || nchar(trimws(args[1])) == 0) {
  cat("❌ No tweet text provided. Usage: Rscript post-single-tweet.R \"tweet text\"\n")
  quit(status = 1)
}

tweet_text <- args[1]
cat("Posting tweet:\n", tweet_text, "\n\n")

token <- build_x_auth()
tweet_id <- post_tweet(text = tweet_text, token = token)

if (!is.null(tweet_id)) {
  cat("✅ Posted! Tweet ID:", tweet_id, "\n")
} else {
  cat("❌ Failed to post.\n")
  quit(status = 1)
}
