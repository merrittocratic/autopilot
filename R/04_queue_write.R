# ============================================================================
# 04_queue_write.R — Write draft threads to Google Sheet review queue
# 2026-07-13: Add Telegram-driven audit/log helpers for inline X thread review
# ============================================================================
# Writes the drafted thread, metadata, and status to a Google Sheet that now
# serves as the audit log and fallback queue. Telegram is the primary review
# surface for day-to-day X thread approvals.
# ============================================================================

source(here::here("R", "00_config.R"))

QUEUE_COLS <- c(
  post_id      = "A",
  title        = "B",
  post_link    = "C",
  tweet_number = "D",
  tweet_text   = "E",
  char_count   = "F",
  has_image    = "G",
  image_path   = "H",
  status       = "I",
  created_at   = "J",
  approved_at  = "K",
  posted_at    = "L",
  tweet_id     = "M",
  notes        = "N"
)

queue_schema <- function() {
  tibble(
    post_id       = character(),
    title         = character(),
    post_link     = character(),
    tweet_number  = character(),
    tweet_text    = character(),
    char_count    = character(),
    has_image     = character(),
    image_path    = character(),
    status        = character(),
    created_at    = character(),
    approved_at   = character(),
    posted_at     = character(),
    tweet_id      = character(),
    notes         = character()
  )
}

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

# --- Queue reads -------------------------------------------------------------

read_queue <- function() {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set.")
  }

  if (!("queue" %in% sheet_names(sheet_id))) {
    cli_alert_info("Queue tab not found yet")
    return(queue_schema())
  }

  read_sheet(sheet_id, sheet = "queue", col_types = "c")
}

read_queue_rows <- function(statuses = NULL) {
  queue <- read_queue()

  if (nrow(queue) == 0 || is.null(statuses)) {
    return(queue)
  }

  queue |>
    filter(status %in% statuses)
}

get_thread_rows <- function(post_id, statuses = NULL) {
  queue <- read_queue()

  if (!is.null(statuses)) {
    queue <- queue |>
      filter(status %in% statuses)
  }

  queue |>
    filter(post_id == !!post_id) |>
    arrange(as.numeric(tweet_number))
}

latest_thread_rows <- function(statuses = c("pending", "approved")) {
  queue <- read_queue_rows(statuses)

  if (nrow(queue) == 0) {
    return(queue_schema())
  }

  latest_post_id <- queue |>
    mutate(.row_n = row_number()) |>
    slice_max(order_by = .row_n, n = 1, with_ties = FALSE) |>
    pull(post_id)

  get_thread_rows(latest_post_id[[1]], statuses = statuses)
}

# --- Read approved threads ---------------------------------------------------

read_approved_threads <- function() {
  queue <- read_queue()

  if (nrow(queue) == 0) {
    cli_alert_info("Queue is empty")
    return(tibble())
  }

  approved <- read_queue_rows("approved")

  if (nrow(approved) == 0) {
    cli_alert_info("No approved threads in queue")
  } else {
    approved |>
      distinct(post_id, title) |>
      pwalk(\(post_id, title) {
        cli_alert_success("Approved: {title}")
      })
  }

  approved
}

# --- Targeted cell updates ---------------------------------------------------

update_queue_fields <- function(post_id, tweet_number, fields) {
  if (length(fields) == 0) {
    return(invisible(TRUE))
  }

  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  queue <- read_queue()

  row_idx <- which(
    queue$post_id == post_id &
      as.numeric(queue$tweet_number) == as.numeric(tweet_number)
  )

  if (length(row_idx) == 0) {
    cli_alert_warning("No matching row for post {post_id}, tweet {tweet_number}")
    return(invisible(FALSE))
  }
  if (length(row_idx) > 1) {
    cli_alert_warning("Multiple rows for post {post_id}, tweet {tweet_number} — updating latest")
    row_idx <- max(row_idx)
  }

  unknown_fields <- setdiff(names(fields), names(QUEUE_COLS))
  if (length(unknown_fields) > 0) {
    cli_abort("Unknown queue field(s): {toString(unknown_fields)}")
  }

  walk(names(fields), \(field_name) {
    range_write(
      sheet_id,
      data = tibble(value = fields[[field_name]]),
      sheet = "queue",
      range = glue("{QUEUE_COLS[[field_name]]}{row_idx + 1}"),
      col_names = FALSE
    )
  })

  invisible(TRUE)
}

append_queue_note <- function(post_id, tweet_number, note) {
  row <- get_thread_rows(post_id) |>
    filter(as.numeric(tweet_number) == as.numeric(!!tweet_number)) |>
    slice_tail(n = 1)

  if (nrow(row) == 0) {
    cli_alert_warning("No matching row for post {post_id}, tweet {tweet_number}")
    return(invisible(FALSE))
  }

  existing <- row$notes[[1]]
  merged <- if (is.na(existing) || !nzchar(existing)) {
    note
  } else {
    paste(existing, note, sep = "\n")
  }

  update_queue_fields(post_id, tweet_number, list(notes = merged))
  invisible(merged)
}

# --- Update status after posting ---------------------------------------------

update_queue_status <- function(post_id, tweet_number, new_status,
                                tweet_id = NA_character_,
                                note = NA_character_) {
  fields <- list(status = new_status)

  timestamp_field <- switch(new_status,
    "approved" = "approved_at",
    "posted"   = "posted_at",
    NULL
  )

  if (!is.null(timestamp_field)) {
    fields[[timestamp_field]] <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  }

  if (!is.na(tweet_id)) {
    fields$tweet_id <- tweet_id
  }

  if (!is.na(note)) {
    fields$notes <- note
  }

  ok <- update_queue_fields(post_id, tweet_number, fields)

  cli_alert_success("Updated tweet {tweet_number} → {new_status}")
  invisible(ok)
}
