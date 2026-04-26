#!/bin/bash
# Check Google Sheet queue for pending drafts
# Called by Earnest during heartbeat checks
# Returns JSON with pending drafts or empty array

cd ~/autopilot

# Use autopilot-env.sh as a wrapper to inject secrets, then run Rscript inline
~/autopilot/scripts/autopilot-env.sh /opt/homebrew/bin/Rscript -e '
suppressPackageStartupMessages({
  library(here)
  library(googlesheets4)
  library(dplyr)
  library(jsonlite)
})

GOOGLE_SA_KEY <- here::here(".secrets", "google-service-account.json")
gs4_auth(path = GOOGLE_SA_KEY)
cli::cli_alert_success("Google Sheets authenticated via service account")

sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")

if (sheet_id == "") {
  cat("[]")
  quit(save = "no")
}

tryCatch({
  queue <- read_sheet(sheet_id, sheet = "queue")
  pending <- queue[queue$status == "pending", ]

  if (nrow(pending) == 0) {
    cat("[]")
  } else {
    result <- pending |>
      select(post_id, title, tweet_number, tweet_text, char_count, has_image, post_link) |>
      toJSON(auto_unbox = TRUE)
    cat(as.character(result))
  }
}, error = function(e) {
  cat(paste0("[{\"error\": \"", gsub("\"", "\\\\\"", e$message), "\"}]"))
})
'
