#!/usr/bin/env Rscript
# ============================================================================
# run_distribution.R — Main orchestration script
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
  source("R/04_queue_write.R")

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

        # Auto-update x-monitor.R keywords for this article
        article_url  <- post$post_id
        article_slug <- sub(".*/p/", "", article_url)
        keyword_script <- path.expand(
          "~/autopilot/openclaw-scripts/update-monitor-keywords.sh"
        )
        if (file.exists(keyword_script)) {
          cli_alert_info("Updating x-monitor keywords for: {article_slug}")
          kw_result <- system2(
            "bash",
            args = c(shQuote(keyword_script),
                     shQuote(article_url),
                     shQuote(article_slug)),
            stdout = TRUE, stderr = TRUE
          )
          cli_alert_success("Keyword update: {paste(kw_result, collapse = ' | ')}")
        } else {
          cli_alert_warning("update-monitor-keywords.sh not found — skipping keyword update")
        }

        # Notify Steve on Telegram
        notify_telegram(glue(
          "\U0001F4DD *New article drafted:* {post$title}\n",
          "Tweet thread ({nrow(thread)} tweets) is in the queue, ready for your review.",
          "\n\nReply with the tweet numbers you want to post (e.g. \"post 1 and 5\")."
        ))
      } else {
        cli_alert_danger("Thread drafting failed for: {post$title}")
        log_event("draft_error", "Thread drafting failed",
                  list(post_id = post$post_id, title = post$title))
      }
    })
  }

  cli_alert_success("Feed check complete")

} else if (mode == "--post") {
  # ---- POST MODE ----
  cli_h1("Autopilot — Post Approved Threads")
  source("R/05_post_to_x.R")
  post_approved_threads()

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
