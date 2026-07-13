#!/usr/bin/env Rscript
# ============================================================================
# run_distribution.R — Main orchestration script
# 2026-07-13: Log all LinkedIn drafts and route approvals through Telegram
# 2026-07-11: Add LinkedIn channel — draft in --check, Zernio post in --post
# ============================================================================
# This is the entry point called by launchd (or manually).
#
# Two modes:
#   --check    Poll RSS feed, extract content, draft thread, queue for review
#   --post     Post any approved threads from the review queue
#   --status   Print pipeline status summary
#   --backfill Mark all current feed items as processed (run once on setup)
#
# Usage:
#   Rscript run_distribution.R --check
#   Rscript run_distribution.R --post
#   Rscript run_distribution.R --status
#   Rscript run_distribution.R --backfill
# ============================================================================

# --- Parse args --------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args) > 0) args[1] else "--status"

# --- Load environment --------------------------------------------------------

# Set working directory to project root (important for launchd context)
if (requireNamespace("here", quietly = TRUE)) {
  setwd(here::here())
}

# Load .env before anything else
source("R/00_config.R")
load_env()
ensure_dirs()

# --- Mode dispatch -----------------------------------------------------------

if (mode == "--check") {
  # ---- FEED CHECK MODE ----
  cli_h1("Autopilot — Feed Check")
  source("R/01_feed_check.R")
  source("R/02_extract_content.R")
  source("R/03_draft_thread.R")
  source("R/03b_draft_linkedin.R")
  source("R/04_queue_write.R")
  source("R/04b_queue_linkedin.R")

  new_posts <- check_for_new_posts()

  if (nrow(new_posts) > 0) {
    # Process each new post
    walk(seq_len(nrow(new_posts)), \(i) {
      post <- new_posts[i, ]
      cli_h1("Processing: {post$title}")

      # Extract content
      content <- extract_post_content(post)

      # Download images
      image_paths <- download_post_images(content)

      # Build summary for LLM
      summary <- summarize_for_thread(content)

      # Draft thread via Claude
      thread <- draft_thread(summary)

      if (!is.null(thread)) {
        # Write to review queue
        write_to_queue(thread, content, image_paths)

        # Mark as processed so we don't re-draft
        mark_processed(post$post_id)

        cli_alert_success("Post queued for review: {post$title}")

        # Notify Steve on Telegram with full tweet text so he can review inline
        # Note: x-monitor.R keywords are synced separately by keyword-sync.sh (daily at 6:15am)
        tweet_lines <- paste0(thread$tweet_number, ". ", thread$text)
        tweet_body  <- paste(tweet_lines, collapse = "\n\n")
        notify_telegram(glue(
          "\U0001F4DD *{post$title}*\n\n",
          "{tweet_body}\n\n",
          "Reply with numbers to post, e.g. \"post 1 and 5\" or \"skip all\"."
        ))
      } else {
        cli_alert_danger("Thread drafting failed for: {post$title}")
        log_event("draft_error", "Thread drafting failed",
                  list(post_id = post$post_id, title = post$title))
      }

      # LinkedIn draft — independent of the X flow; a failure here must never
      # block the thread pipeline, so everything is wrapped
      tryCatch({
        li_post <- draft_linkedin_post(summary)

        if (!is.null(li_post) && identical(li_post$recommendation[[1]], "post")) {
          hero_url <- fetch_hero_image_url(content$link)
          write_to_linkedin_queue(
            li_post,
            content,
            image_url = hero_url,
            initial_status = "pending"
          )

          flag_line <- if (!is.na(li_post$notes[[1]]) && nzchar(li_post$notes[[1]])) {
            glue("\nFlag: {li_post$notes[[1]]}\n")
          } else ""
          notify_telegram(glue(
            "\U0001F4BC *LinkedIn draft: {post$title}*\n",
            "ID: `{post$post_id}`\n\n",
            "{li_post$post_text[[1]]}\n",
            "{flag_line}\n",
            "Reply `post linkedin {post$post_id}` to publish, `skip linkedin {post$post_id}` to reject, or `edit linkedin {post$post_id}: ...` with your changes."
          ))
        } else if (!is.null(li_post) && identical(li_post$recommendation[[1]], "skip")) {
          cli_alert_info("LinkedIn held for: {post$title}")
          hero_url <- fetch_hero_image_url(content$link)
          write_to_linkedin_queue(
            li_post,
            content,
            image_url = hero_url,
            initial_status = "skip_recommended"
          )
          log_event("linkedin_skip", "LinkedIn held by recommendation",
                    list(post_id = post$post_id, title = post$title,
                         notes = li_post$notes[[1]] %||% NA_character_))
          notify_telegram(glue(
            "\U0001F6AB *LinkedIn draft held: {post$title}*\n",
            "ID: `{post$post_id}`\n\n",
            "{li_post$post_text[[1]]}\n\n",
            "Reason: {coalesce(li_post$notes[[1]], 'No LinkedIn angle strong enough to queue safely.')}\n\n",
            "Reply `post linkedin {post$post_id}` to publish anyway, `skip linkedin {post$post_id}` to log the pass, or `edit linkedin {post$post_id}: ...` with a rewrite."
          ))
        } else {
          cli_alert_danger("LinkedIn drafting failed for: {post$title}")
          log_event("linkedin_draft_error", "LinkedIn drafting failed",
                    list(post_id = post$post_id, title = post$title))
        }
      }, error = function(e) {
        cli_alert_danger("LinkedIn stage error: {e$message}")
        log_event("linkedin_draft_error", e$message,
                  list(post_id = post$post_id, title = post$title))
      })
    })
  }

  cli_alert_success("Feed check complete")

} else if (mode == "--post") {
  # ---- POST MODE ----
  cli_h1("Autopilot — Post Approved Threads")
  source("R/05_post_to_x.R")
  post_approved_threads()

  # LinkedIn (via Zernio) — after X, and isolated so one channel's failure
  # never blocks the other
  tryCatch({
    source("R/05b_post_to_linkedin.R")
    post_approved_linkedin()
  }, error = function(e) {
    cli_alert_danger("LinkedIn posting stage error: {e$message}")
    log_event("linkedin_post_error", e$message)
  })

} else if (mode == "--backfill") {
  # ---- BACKFILL MODE ----
  source("R/01_feed_check.R")
  backfill_feed_state()

} else if (mode == "--status") {
  # ---- STATUS MODE ----
  source("R/06_log_run.R")
  pipeline_status()

} else {
  cli_alert_danger("Unknown mode: {mode}")
  cli_alert_info("Valid modes: --check, --post, --status, --backfill")
}
