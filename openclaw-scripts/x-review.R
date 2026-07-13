#!/usr/bin/env Rscript
# ============================================================================
# x-review.R — Telegram-driven X thread approvals/editing
# 2026-07-13: Add inline review actions so Telegram, not the Sheet, drives
#             X thread approval while the Sheet remains the audit trail.
# ============================================================================

args <- commandArgs(trailingOnly = TRUE)

usage <- function() {
  cat(
    paste(
      "Usage:",
      "  x-review.R show [post_id]",
      "  x-review.R approve [post_id] [--tweets 1,2,3|all]",
      "  x-review.R post [post_id] [--tweets 1,2,3|all]",
      "  x-review.R reject [post_id] [--note text]",
      "  x-review.R edit [post_id] <tweet_number> --text text",
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
source("R/04_queue_write.R")
source("R/05_post_to_x.R")

command <- args[[1]]
rest <- args[-1]

parse_args <- function(tokens) {
  out <- list(post_id = NULL, tweets = NULL, text = NULL, note = NULL, tweet_number = NULL)
  i <- 1
  while (i <= length(tokens)) {
    token <- tokens[[i]]
    if (token %in% c("--tweets", "--text", "--note") && i == length(tokens)) {
      cli::cli_abort("{token} requires a value")
    }
    if (token == "--tweets") {
      out$tweets <- tokens[[i + 1]]
      i <- i + 2
    } else if (token == "--text") {
      out$text <- tokens[[i + 1]]
      i <- i + 2
    } else if (token == "--note") {
      out$note <- tokens[[i + 1]]
      i <- i + 2
    } else if (is.null(out$post_id)) {
      out$post_id <- token
      i <- i + 1
    } else if (is.null(out$tweet_number) && command == "edit") {
      out$tweet_number <- token
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

resolve_thread <- function(post_id = NULL, statuses = c("pending", "approved")) {
  rows <- if (is.null(post_id)) {
    latest_thread_rows(statuses)
  } else {
    get_thread_rows(post_id, statuses = statuses)
  }

  if (nrow(rows) == 0) {
    cli::cli_abort("No actionable X thread found{if (!is.null(post_id)) paste0(' for post ', post_id) else ''}.")
  }

  rows
}

normalize_tweets <- function(spec, rows) {
  all_nums <- rows |>
    dplyr::pull(tweet_number) |>
    as.numeric() |>
    sort()

  if (is.null(spec) || identical(tolower(spec), "all")) {
    return(all_nums)
  }

  selected <- spec |>
    strsplit(",", fixed = TRUE) |>
    unlist() |>
    trimws() |>
    as.numeric()

  if (any(is.na(selected))) {
    cli::cli_abort("Could not parse --tweets value: {spec}")
  }

  selected <- sort(unique(selected))
  missing <- setdiff(selected, all_nums)
  if (length(missing) > 0) {
    cli::cli_abort("Tweet number(s) not in thread: {toString(missing)}")
  }

  selected
}

show_thread <- function(rows) {
  body <- c(
    glue::glue("post_id: {rows$post_id[[1]]}"),
    glue::glue("title: {rows$title[[1]]}"),
    ""
  )

  for (i in seq_len(nrow(rows))) {
    row <- rows[i, ]
    body <- c(
      body,
      glue::glue("{row$tweet_number[[1]]}. [{row$status[[1]]}] {row$tweet_text[[1]]}"),
      ""
    )
  }

  cat(paste(body, collapse = "\n"))
}

approve_or_post <- function(post_id = NULL, tweet_spec = NULL, post_now = FALSE) {
  rows <- resolve_thread(post_id)
  selected <- normalize_tweets(tweet_spec, rows)
  selected_chr <- as.character(selected)

  for (i in seq_len(nrow(rows))) {
    row <- rows[i, ]
    num <- row$tweet_number[[1]]

    if (num %in% selected_chr) {
      update_queue_status(row$post_id[[1]], num, "approved")
      append_queue_note(row$post_id[[1]], num,
                        stamp_note(if (post_now) "Approved to post" else "Approved"))
    } else if (!identical(row$status[[1]], "posted")) {
      update_queue_status(row$post_id[[1]], num, "rejected")
      append_queue_note(row$post_id[[1]], num,
                        stamp_note("Held out of publish selection"))
    }
  }

  if (post_now) {
    post_selected_thread(rows$post_id[[1]])
  }
}

reject_thread <- function(post_id = NULL, note = NULL) {
  rows <- resolve_thread(post_id)

  for (i in seq_len(nrow(rows))) {
    row <- rows[i, ]
    update_queue_status(row$post_id[[1]], row$tweet_number[[1]], "rejected")
    append_queue_note(row$post_id[[1]], row$tweet_number[[1]],
                      stamp_note("Rejected", note))
  }

  cli::cli_alert_success("Rejected X thread: {rows$post_id[[1]]}")
}

edit_tweet <- function(post_id = NULL, tweet_number, text) {
  if (is.null(tweet_number)) {
    cli::cli_abort("edit requires a tweet_number")
  }
  if (is.null(text) || !nzchar(text)) {
    cli::cli_abort("Edited tweet text cannot be empty")
  }

  rows <- resolve_thread(post_id, statuses = c("pending", "approved", "rejected"))
  if (!(as.character(tweet_number) %in% rows$tweet_number)) {
    cli::cli_abort("Tweet number {tweet_number} not found in thread")
  }

  update_queue_fields(
    rows$post_id[[1]],
    tweet_number,
    list(
      tweet_text = text,
      char_count = as.character(nchar(text, type = "chars")),
      status = "pending",
      approved_at = NA_character_
    )
  )
  append_queue_note(rows$post_id[[1]], tweet_number, stamp_note("Edited"))
  cli::cli_alert_success("Updated tweet {tweet_number} in thread {rows$post_id[[1]]}")
}

switch(
  command,
  show = show_thread(resolve_thread(opts$post_id, statuses = c("pending", "approved", "rejected"))),
  approve = approve_or_post(opts$post_id, opts$tweets, post_now = FALSE),
  post = approve_or_post(opts$post_id, opts$tweets, post_now = TRUE),
  reject = reject_thread(opts$post_id, opts$note),
  edit = edit_tweet(opts$post_id, opts$tweet_number, opts$text),
  {
    usage()
    cli::cli_abort("Unknown command: {command}")
  }
)
