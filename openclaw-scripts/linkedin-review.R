#!/usr/bin/env Rscript
# ============================================================================
# linkedin-review.R — Telegram-driven LinkedIn approvals/editing
# 2026-07-13: Add inline review actions so Telegram, not the Sheet, drives
#             LinkedIn approval while the Sheet remains the audit trail.
# ============================================================================

args <- commandArgs(trailingOnly = TRUE)

usage <- function() {
  cat(
    paste(
      "Usage:",
      "  linkedin-review.R show [post_id]",
      "  linkedin-review.R approve [post_id]",
      "  linkedin-review.R reject [post_id] [--note text]",
      "  linkedin-review.R edit [post_id] --text text",
      "  linkedin-review.R edit-and-approve [post_id] --text text",
      sep = "\n"
    ),
    "\n"
  )
}

if (length(args) == 0 || args[[1]] %in% c("-h", "--help", "help")) {
  usage()
  quit(status = 0)
}

if (requireNamespace("here", quietly = TRUE)) {
  setwd(here::here())
}

source("R/00_config.R")
load_env()
ensure_dirs()
source("R/04b_queue_linkedin.R")
source("R/05b_post_to_linkedin.R")

command <- args[[1]]
rest <- args[-1]

parse_args <- function(tokens) {
  out <- list(post_id = NULL, text = NULL, note = NULL)
  i <- 1
  while (i <= length(tokens)) {
    token <- tokens[[i]]
    if (token %in% c("--text", "--note") && i == length(tokens)) {
      cli::cli_abort("{token} requires a value")
    }
    if (token == "--text") {
      out$text <- tokens[[i + 1]]
      i <- i + 2
    } else if (token == "--note") {
      out$note <- tokens[[i + 1]]
      i <- i + 2
    } else if (is.null(out$post_id)) {
      out$post_id <- token
      i <- i + 1
    } else {
      cli::cli_abort("Unexpected argument: {token}")
    }
  }
  out
}

opts <- parse_args(rest)

stamp_note <- function(label, extra = NULL) {
  stamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S %z")
  if (is.null(extra) || is.na(extra) || !nzchar(extra)) {
    glue::glue("{label} via Telegram ({stamp})")
  } else {
    glue::glue("{label} via Telegram ({stamp}) — {extra}")
  }
}

resolve_row <- function(post_id = NULL,
                        statuses = c("pending", "skip_recommended", "approved")) {
  row <- if (is.null(post_id)) {
    latest_linkedin_row(statuses)
  } else {
    get_linkedin_row(post_id) |>
      dplyr::filter(status %in% statuses)
  }

  if (nrow(row) == 0) {
    cli::cli_abort("No actionable LinkedIn draft found{if (!is.null(post_id)) paste0(' for post ', post_id) else ''}.")
  }

  row
}

show_row <- function(row) {
  cat(
    paste(
      glue::glue("post_id: {row$post_id[[1]]}"),
      glue::glue("title: {row$title[[1]]}"),
      glue::glue("status: {row$status[[1]]}"),
      glue::glue("char_count: {row$char_count[[1]]}"),
      glue::glue("notes: {ifelse(is.na(row$notes[[1]]), '', row$notes[[1]])}"),
      "",
      row$post_text[[1]],
      sep = "\n"
    )
  )
}

approve_row <- function(post_id = NULL) {
  row <- resolve_row(post_id)
  id <- row$post_id[[1]]

  if (!identical(row$status[[1]], "approved")) {
    update_linkedin_status(id, "approved")
    append_linkedin_note(id, stamp_note("Approved"))
  }

  post_selected_linkedin(id)
}

reject_row <- function(post_id = NULL, note = NULL) {
  row <- resolve_row(post_id)
  id <- row$post_id[[1]]

  update_linkedin_status(id, "rejected")
  append_linkedin_note(id, stamp_note("Rejected", note))
  cli::cli_alert_success("Rejected LinkedIn draft: {id}")
}

edit_row <- function(post_id = NULL, text, approve = FALSE) {
  if (is.null(text) || !nzchar(text)) {
    cli::cli_abort("Edited LinkedIn text cannot be empty")
  }

  row <- resolve_row(post_id)
  id <- row$post_id[[1]]

  update_linkedin_fields(
    id,
    list(
      post_text = text,
      char_count = as.character(nchar(text, type = "chars")),
      approved_at = NA_character_
    )
  )
  append_linkedin_note(id, stamp_note("Edited"))
  cli::cli_alert_success("Updated LinkedIn draft text: {id}")

  if (approve) {
    update_linkedin_status(id, "approved")
    append_linkedin_note(id, stamp_note("Approved after edit"))
    post_selected_linkedin(id)
  }
}

switch(
  command,
  show = show_row(resolve_row(opts$post_id)),
  approve = approve_row(opts$post_id),
  reject = reject_row(opts$post_id, opts$note),
  edit = edit_row(opts$post_id, opts$text, approve = FALSE),
  `edit-and-approve` = edit_row(opts$post_id, opts$text, approve = TRUE),
  {
    usage()
    cli::cli_abort("Unknown command: {command}")
  }
)
