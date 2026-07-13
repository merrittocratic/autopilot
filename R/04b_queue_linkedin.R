# ============================================================================
# 04b_queue_linkedin.R — LinkedIn tab of the Google Sheet review queue
# 2026-07-13: Add Telegram-driven audit/log helpers for inline LinkedIn review
# 2026-07-11b: Drop first_comment column (links now live in post body per
#              substack-to-linkedin skill); model flags land in notes
# 2026-07-11: Initial version — LinkedIn distribution channel (posts via Zernio)
# ============================================================================
# LinkedIn drafts are logged here as one row per post. Telegram is the primary
# approval surface; the sheet is the audit trail and fallback posting queue.
# Lives in the same spreadsheet as the X queue, on a separate "linkedin" tab so
# the column schema can differ.
# ============================================================================

source(here::here("R", "00_config.R"))

# Column layout (letters matter for update_linkedin_status range writes):
# A post_id | B title | C post_link | D post_text | E char_count
# F image_url | G status | H created_at | I approved_at | J posted_at
# K linkedin_post_id | L notes

LINKEDIN_SHEET_TAB <- "linkedin"

LINKEDIN_COLS <- c(
  post_id          = "A",
  title            = "B",
  post_link        = "C",
  post_text        = "D",
  char_count       = "E",
  image_url        = "F",
  status           = "G",
  created_at       = "H",
  approved_at      = "I",
  posted_at        = "J",
  linkedin_post_id = "K",
  notes            = "L"
)

linkedin_queue_schema <- function() {
  tibble(
    post_id          = character(),
    title            = character(),
    post_link        = character(),
    post_text        = character(),
    char_count       = integer(),
    image_url        = character(),
    status           = character(),   # "pending" | "approved" | "rejected" | "posted"
    created_at       = character(),
    approved_at      = character(),
    posted_at        = character(),
    linkedin_post_id = character(),   # Zernio post _id, filled after posting
    notes            = character()    # model flags + manual comments
  )
}

# --- Tab setup (idempotent) ---------------------------------------------------

ensure_linkedin_tab <- function() {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set. Check your .env file.")
  }

  if (!LINKEDIN_SHEET_TAB %in% sheet_names(sheet_id)) {
    cli_alert_info("Creating '{LINKEDIN_SHEET_TAB}' tab in review sheet")
    sheet_write(linkedin_queue_schema(), sheet_id, sheet = LINKEDIN_SHEET_TAB)
    cli_alert_success("LinkedIn queue tab created")
  }

  sheet_id
}

# --- Queue operations ---------------------------------------------------------

write_to_linkedin_queue <- function(li_post, content, image_url = NA_character_,
                                    initial_status = "pending") {
  sheet_id <- ensure_linkedin_tab()

  cli_h2("Writing LinkedIn draft to review queue")

  queue_row <- tibble(
    post_id          = content$post_id,
    title            = content$title,
    post_link        = content$link,
    post_text        = li_post$post_text,
    char_count       = li_post$char_count,
    image_url        = image_url,
    status           = initial_status,
    created_at       = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    approved_at      = NA_character_,
    posted_at        = NA_character_,
    linkedin_post_id = NA_character_,
    notes            = li_post$notes
  )

  sheet_append(sheet_id, queue_row, sheet = LINKEDIN_SHEET_TAB)

  cli_alert_success("LinkedIn draft queued for review")
  log_event("linkedin_queue_write",
            glue("Queued LinkedIn draft for: {content$title}"),
            list(post_id = content$post_id, char_count = li_post$char_count))

  invisible(queue_row)
}

# --- Queue reads ----------------------------------------------------------------

read_linkedin_queue <- function() {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set.")
  }

  if (!LINKEDIN_SHEET_TAB %in% sheet_names(sheet_id)) {
    cli_alert_info("No LinkedIn tab yet — nothing queued")
    return(linkedin_queue_schema())
  }

  read_sheet(sheet_id, sheet = LINKEDIN_SHEET_TAB, col_types = "c")
}

read_linkedin_rows <- function(statuses = NULL) {
  queue <- read_linkedin_queue()

  if (nrow(queue) == 0 || is.null(statuses)) {
    return(queue)
  }

  queue |>
    filter(status %in% statuses)
}

get_linkedin_row <- function(post_id) {
  queue <- read_linkedin_queue()

  queue |>
    filter(post_id == !!post_id) |>
    slice_tail(n = 1)
}

latest_linkedin_row <- function(statuses = c("pending", "skip_recommended", "approved")) {
  queue <- read_linkedin_rows(statuses)

  if (nrow(queue) == 0) {
    return(tibble())
  }

  queue |>
    mutate(.row_n = row_number()) |>
    slice_max(order_by = .row_n, n = 1, with_ties = FALSE) |>
    select(-.row_n)
}

# --- Read approved posts --------------------------------------------------------

read_approved_linkedin <- function() {
  queue <- read_linkedin_queue()

  if (nrow(queue) == 0) {
    cli_alert_info("LinkedIn queue is empty")
    return(tibble())
  }

  approved <- read_linkedin_rows("approved")

  if (nrow(approved) == 0) {
    cli_alert_info("No approved LinkedIn posts in queue")
  } else {
    pwalk(approved |> distinct(post_id, title), \(post_id, title) {
      cli_alert_success("Approved: {title}")
    })
  }

  approved
}

# --- Targeted cell updates ------------------------------------------------------

update_linkedin_fields <- function(post_id, fields) {
  if (length(fields) == 0) {
    return(invisible(TRUE))
  }

  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  queue <- read_linkedin_queue()

  row_idx <- which(queue$post_id == post_id)

  if (length(row_idx) == 0) {
    cli_alert_warning("No LinkedIn queue row for post {post_id}")
    return(invisible(FALSE))
  }
  if (length(row_idx) > 1) {
    cli_alert_warning("{length(row_idx)} LinkedIn rows for post {post_id} — updating latest")
    row_idx <- max(row_idx)
  }

  unknown_fields <- setdiff(names(fields), names(LINKEDIN_COLS))
  if (length(unknown_fields) > 0) {
    cli_abort("Unknown LinkedIn field(s): {toString(unknown_fields)}")
  }

  walk(names(fields), \(field_name) {
    range_write(
      sheet_id,
      data = tibble(value = fields[[field_name]]),
      sheet = LINKEDIN_SHEET_TAB,
      range = glue("{LINKEDIN_COLS[[field_name]]}{row_idx + 1}"),
      col_names = FALSE
    )
  })

  invisible(TRUE)
}

append_linkedin_note <- function(post_id, note) {
  row <- get_linkedin_row(post_id)

  if (nrow(row) == 0) {
    cli_alert_warning("No LinkedIn queue row for post {post_id}")
    return(invisible(FALSE))
  }

  existing <- row$notes[[1]]
  merged <- if (is.na(existing) || !nzchar(existing)) {
    note
  } else {
    paste(existing, note, sep = "\n")
  }

  update_linkedin_fields(post_id, list(notes = merged))
  invisible(merged)
}

# --- Update status after posting -----------------------------------------------

update_linkedin_status <- function(post_id, new_status,
                                   linkedin_post_id = NA_character_,
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

  if (!is.na(linkedin_post_id)) {
    fields$linkedin_post_id <- linkedin_post_id
  }

  if (!is.na(note)) {
    fields$notes <- note
  }

  ok <- update_linkedin_fields(post_id, fields)

  cli_alert_success("LinkedIn post {post_id} -> {new_status}")
  invisible(ok)
}
