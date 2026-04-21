# ============================================================================
# 04_queue_write.R — Write draft threads to Google Sheet review queue
# ============================================================================
# Writes the drafted thread, metadata, and approval status to a Google Sheet
# that serves as the human-in-the-loop review surface.
# ============================================================================

source(here::here("R", "00_config.R"))

# --- Sheet setup -------------------------------------------------------------
# Run once to create the review queue sheet with proper headers

setup_review_sheet <- function(sheet_name = "Merrittocracy Autopilot Queue") {
  cli_h1("Setting up review queue sheet")

  # Auth handled in 00_config.R via service account

  ss <- gs4_create(
    sheet_name,
    sheets = list(
      queue = tibble(
        post_id       = character(),
        title         = character(),
        post_link     = character(),
        tweet_number  = integer(),
        tweet_text    = character(),
        char_count    = integer(),
        has_image     = logical(),
        image_path    = character(),
        status        = character(),   # "pending" | "approved" | "rejected" | "posted"
        created_at    = character(),
        approved_at   = character(),
        posted_at     = character(),
        tweet_id      = character(),   # filled after posting
        notes         = character()    # for manual edits / comments
      )
    )
  )

  sheet_id <- as.character(ss)
  cli_alert_success("Review sheet created: {sheet_id}")
  cli_alert_info("Add this to your .env file:")
  cli_code("REVIEW_SHEET_ID={sheet_id}")

  sheet_id
}

# --- Queue operations --------------------------------------------------------

write_to_queue <- function(thread, content, image_paths = character(0)) {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set. Run setup_review_sheet() first.")
  }

  cli_h2("Writing to review queue")

  # Build the queue rows — one row per tweet in the thread
  queue_rows <- thread |>
    mutate(
      post_id      = content$post_id,
      title        = content$title,
      post_link    = content$link,
      tweet_text   = text,
      image_path   = if_else(
        has_image & length(image_paths) > 0,
        image_paths[1],  # primary chart
        NA_character_
      ),
      status       = "pending",
      created_at   = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      approved_at  = NA_character_,
      posted_at    = NA_character_,
      tweet_id     = NA_character_,
      notes        = NA_character_
    ) |>
    select(
      post_id, title, post_link, tweet_number, tweet_text,
      char_count, has_image, image_path, status, created_at,
      approved_at, posted_at, tweet_id, notes
    )

  # Append to the sheet
  sheet_append(sheet_id, queue_rows, sheet = "queue")

  cli_alert_success("Added {nrow(queue_rows)} tweets to review queue")
  log_event("queue_write", glue("Queued thread for: {content$title}"),
            list(post_id = content$post_id, n_tweets = nrow(queue_rows)))

  invisible(queue_rows)
}

# --- Read approved threads ---------------------------------------------------

read_approved_threads <- function() {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set.")
  }

  queue <- read_sheet(sheet_id, sheet = "queue")

  if (nrow(queue) == 0) {
    cli_alert_info("Queue is empty")
    return(tibble())
  }

  approved <- queue |>
    filter(status == "approved")

  if (nrow(approved) == 0) {
    cli_alert_info("No approved threads in queue")
  } else {
    # Group by post_id to show thread-level summary
    approved |>
      distinct(post_id, title) |>
      pwalk(\(post_id, title) {
        cli_alert_success("Approved: {title}")
      })
  }

  approved
}

# --- Update status after posting ---------------------------------------------

update_queue_status <- function(post_id, tweet_number, new_status,
                                 tweet_id = NA_character_) {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")

  queue <- read_sheet(sheet_id, sheet = "queue")

  row_idx <- which(queue$post_id == post_id & queue$tweet_number == tweet_number)

  if (length(row_idx) == 0) {
    cli_alert_warning("No matching row for post {post_id}, tweet {tweet_number}")
    return(invisible(FALSE))
  }

  # Update the specific cells
  timestamp_col <- switch(new_status,
    "approved" = "approved_at",
    "posted"   = "posted_at",
    NULL
  )

  # Write status
  range_write(
    sheet_id,
    data = tibble(status = new_status),
    sheet = "queue",
    range = glue("I{row_idx + 1}"),  # +1 for header row
    col_names = FALSE
  )

  # Write timestamp if applicable
  if (!is.null(timestamp_col)) {
    col_letter <- switch(timestamp_col,
      "approved_at" = "K",
      "posted_at"   = "L"
    )
    range_write(
      sheet_id,
      data = tibble(ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
      sheet = "queue",
      range = glue("{col_letter}{row_idx + 1}"),
      col_names = FALSE
    )
  }

  # Write tweet_id if provided
  if (!is.na(tweet_id)) {
    range_write(
      sheet_id,
      data = tibble(tweet_id = tweet_id),
      sheet = "queue",
      range = glue("M{row_idx + 1}"),
      col_names = FALSE
    )
  }

  cli_alert_success("Updated tweet {tweet_number} → {new_status}")
  invisible(TRUE)
}
