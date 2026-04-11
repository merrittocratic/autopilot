# ============================================================================
# 06_log_run.R — Run history, log reading, and pipeline diagnostics
# ============================================================================
# Utilities for reading logs, summarizing pipeline runs, and generating
# the accountability data that feeds into the "how I built this" content.
# ============================================================================

source(here::here("R", "00_config.R"))

# --- Log reading -------------------------------------------------------------

read_logs <- function(date = Sys.Date(), n_days = 1) {
  dates <- seq(date - (n_days - 1), date, by = "day")
  log_files <- file.path(PATH_LOGS, glue("{dates}_autopilot.log"))
  log_files <- log_files[file.exists(log_files)]

  if (length(log_files) == 0) {
    cli_alert_info("No log files found for the requested date range")
    return(tibble())
  }

  map_dfr(log_files, \(f) {
    lines <- read_lines(f)
    map_dfr(lines, \(line) {
      tryCatch(
        fromJSON(line) |> as_tibble(),
        error = function(e) tibble()
      )
    })
  })
}

# --- Pipeline status summary -------------------------------------------------

pipeline_status <- function() {
  cli_h1("Autopilot Pipeline Status")

  # Feed state
  state <- tryCatch(
    fromJSON(FEED_STATE_FILE),
    error = function(e) list(processed_ids = character(0), last_check = NULL)
  )

  cli_h2("Feed State")
  cli_alert_info("Posts processed: {length(state$processed_ids)}")
  cli_alert_info("Last check: {state$last_check %||% 'never'}")

  # Recent logs
  cli_h2("Recent Activity (last 7 days)")
  logs <- read_logs(n_days = 7)

  if (nrow(logs) > 0) {
    logs |>
      count(event_type) |>
      pwalk(\(event_type, n) {
        cli_alert_info("{event_type}: {n} events")
      })
  } else {
    cli_alert_info("No log entries")
  }

  # Queue status
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id != "") {
    cli_h2("Review Queue")
    tryCatch({
      queue <- read_sheet(sheet_id, sheet = "queue")
      if (nrow(queue) > 0) {
        queue |>
          count(status) |>
          pwalk(\(status, n) {
            icon <- switch(status,
              "pending"  = "clock",
              "approved" = "check",
              "posted"   = "rocket",
              "rejected" = "cross_mark",
              "info"
            )
            cli_alert_info("{status}: {n}")
          })
      } else {
        cli_alert_info("Queue is empty")
      }
    }, error = function(e) {
      cli_alert_warning("Could not read queue: {e$message}")
    })
  } else {
    cli_alert_warning("REVIEW_SHEET_ID not set — queue not configured")
  }
}

# --- Accountability export ---------------------------------------------------
# Generates a summary of all posts processed and their distribution status
# for use in the "how I built this" content

export_pipeline_history <- function(output_path = here::here("data", "pipeline_history.csv")) {
  sheet_id <- Sys.getenv("REVIEW_SHEET_ID", unset = "")
  if (sheet_id == "") {
    cli_abort("REVIEW_SHEET_ID not set")
  }

  queue <- read_sheet(sheet_id, sheet = "queue")

  if (nrow(queue) == 0) {
    cli_alert_info("No pipeline history to export")
    return(invisible(NULL))
  }

  summary <- queue |>
    group_by(post_id, title) |>
    summarize(
      n_tweets     = n(),
      status       = first(status),
      created_at   = first(created_at),
      posted_at    = first(posted_at, na_rm = TRUE),
      .groups      = "drop"
    )

  write_csv(summary, output_path)
  cli_alert_success("Pipeline history exported to {output_path}")
  summary
}
