# ============================================================================
# 04b_queue_linkedin.R — LinkedIn tab of the Google Sheet review queue
# 2026-07-11b: Drop first_comment column (links now live in post body per
#              substack-to-linkedin skill); model flags land in notes
# 2026-07-11: Initial version — LinkedIn distribution channel (posts via Zernio)
# ============================================================================
# Same approval model as the X queue: drafts land as "pending", only rows a
# human flips to "approved" get posted. One row per post (LinkedIn is a single
# post, not a thread). Lives in the same spreadsheet as the X queue, on a
# separate "linkedin" tab so the column schema can differ.
# ============================================================================

source(here::here("R", "00_config.R"))

# Column layout (letters matter for update_linkedin_status range writes):
# A post_id | B title | C post_link | D post_text | E char_count
# F image_url | G status | H created_at | I approved_at | J posted_at
# K linkedin_post_id | L notes

LINKEDIN_SHEET_TAB <- "linkedin"

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

write_to_linkedin_queue <- function(li_post, content, image_url = NA_character_) {
  sheet_id <- ensure_linkedin_tab()

  cli_h2("Writing LinkedIn draft to review queue")

  queue_row <- tibble(
    post_id          = content$post_id,
    title            = content$title,
    post_link        = content$link,
    post_text        = li_post$post_text,
    char_count       = li_post$char_count,
    image_url        = image_url,
    status           = "pending",
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

# --- Read approved posts --------------------------------------------------------

read_approved_linkedin <- function() {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set.")
  }

  if (!LINKEDIN_SHEET_TAB %in% sheet_names(sheet_id)) {
    cli_alert_info("No LinkedIn tab yet — nothing queued")
    return(tibble())
  }

  queue <- read_sheet(sheet_id, sheet = LINKEDIN_SHEET_TAB,
                      col_types = "c")  # everything as character; parse as needed

  if (nrow(queue) == 0) {
    cli_alert_info("LinkedIn queue is empty")
    return(tibble())
  }

  approved <- queue |>
    filter(status == "approved")

  if (nrow(approved) == 0) {
    cli_alert_info("No approved LinkedIn posts in queue")
  } else {
    pwalk(approved |> distinct(post_id, title), \(post_id, title) {
      cli_alert_success("Approved: {title}")
    })
  }

  approved
}

# --- Update status after posting -----------------------------------------------

update_linkedin_status <- function(post_id, new_status,
                                   linkedin_post_id = NA_character_) {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")

  queue <- read_sheet(sheet_id, sheet = LINKEDIN_SHEET_TAB, col_types = "c")

  row_idx <- which(queue$post_id == post_id)

  if (length(row_idx) == 0) {
    cli_alert_warning("No LinkedIn queue row for post {post_id}")
    return(invisible(FALSE))
  }
  if (length(row_idx) > 1) {
    # Shouldn't happen (one row per post) — update the most recent, flag it
    cli_alert_warning("{length(row_idx)} LinkedIn rows for post {post_id} — updating latest")
    row_idx <- max(row_idx)
  }

  # Status (column G)
  range_write(
    sheet_id,
    data = tibble(status = new_status),
    sheet = LINKEDIN_SHEET_TAB,
    range = glue("G{row_idx + 1}"),  # +1 for header row
    col_names = FALSE
  )

  # Timestamp column, if the status carries one
  timestamp_col <- switch(new_status,
    "approved" = "I",
    "posted"   = "J",
    NULL
  )
  if (!is.null(timestamp_col)) {
    range_write(
      sheet_id,
      data = tibble(ts = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
      sheet = LINKEDIN_SHEET_TAB,
      range = glue("{timestamp_col}{row_idx + 1}"),
      col_names = FALSE
    )
  }

  # Zernio post id (column K)
  if (!is.na(linkedin_post_id)) {
    range_write(
      sheet_id,
      data = tibble(linkedin_post_id = linkedin_post_id),
      sheet = LINKEDIN_SHEET_TAB,
      range = glue("K{row_idx + 1}"),
      col_names = FALSE
    )
  }

  cli_alert_success("LinkedIn post {post_id} -> {new_status}")
  invisible(TRUE)
}
