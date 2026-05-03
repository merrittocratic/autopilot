# ============================================================================
# 01_feed_check.R — Poll Substack RSS feed and detect new posts
# ============================================================================
# Reads the Substack RSS feed, compares against known post IDs in
# feed_state.json, and returns any new posts for processing.
# ============================================================================

source(here::here("R", "00_config.R"))

# --- Feed state management ---------------------------------------------------

read_feed_state <- function() {
  if (!file.exists(FEED_STATE_FILE)) {
    cli_alert_info("No feed state file found — initializing empty state")
    return(list(processed_ids = character(0), last_check = NULL))
  }
  fromJSON(FEED_STATE_FILE)
}

write_feed_state <- function(state) {
  ensure_dirs()
  write_json(state, FEED_STATE_FILE, auto_unbox = TRUE, pretty = TRUE)
}

mark_processed <- function(post_id) {
  state <- read_feed_state()
  state$processed_ids <- unique(c(state$processed_ids, post_id))
  state$last_check <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  write_feed_state(state)
  cli_alert_success("Marked post {post_id} as processed")
}

# --- RSS parsing -------------------------------------------------------------

fetch_feed <- function(feed_url = SUBSTACK_FEED_URL) {
  cli_h1("Checking Substack RSS feed")
  cli_alert_info("Fetching {feed_url}")

  resp <- tryCatch(
    request(feed_url) |>
      req_headers("User-Agent" = "Merrittocracy-Autopilot/1.0") |>
      req_timeout(30) |>
      req_perform(),
    error = function(e) {
      cli_alert_danger("Feed fetch failed: {e$message}")
      log_event("feed_error", "RSS fetch failed", list(error = e$message))
      return(NULL)
    }
  )

  if (is.null(resp)) return(NULL)

  cli_alert_success("Feed fetched ({resp_status(resp)})")
  resp_body_xml(resp)
}

parse_feed_items <- function(feed_xml) {
  if (is.null(feed_xml)) return(tibble())

  items <- xml_find_all(feed_xml, "//item")

  if (length(items) == 0) {
    cli_alert_warning("No items found in feed")
    return(tibble())
  }

  cli_alert_info("Found {length(items)} items in feed")

  tibble(
    title       = xml_text(xml_find_first(items, "title")),
    link        = xml_text(xml_find_first(items, "link")),
    guid        = xml_text(xml_find_first(items, "guid")),
    pub_date    = xml_text(xml_find_first(items, "pubDate")),
    description = xml_text(xml_find_first(items, "description")),
    # Substack puts the full HTML in content:encoded
    content     = xml_text(xml_find_first(
      items,
      "content:encoded",
      xml_ns(feed_xml)
    ))
  ) |>
    mutate(
      pub_date = as.POSIXct(strptime(sub(" GMT$", "", pub_date), "%a, %d %b %Y %H:%M:%S"), tz = "GMT"),
      # Use guid as the unique post ID — stable across title edits
      post_id = str_extract(guid, "[^/]+$") |> coalesce(guid)
    )
}

# --- New post detection ------------------------------------------------------

check_for_new_posts <- function(feed_url = SUBSTACK_FEED_URL) {
  state <- read_feed_state()
  feed_xml <- fetch_feed(feed_url)
  items <- parse_feed_items(feed_xml)

  if (nrow(items) == 0) {
    cli_alert_warning("No posts found in feed")
    return(tibble())
  }

  new_posts <- items |>
    filter(!post_id %in% state$processed_ids)

  if (nrow(new_posts) == 0) {
    cli_alert_info("No new posts since last check")
  } else {
    cli_alert_success("Found {nrow(new_posts)} new post(s):")
    walk(new_posts$title, \(t) cli_alert("  {t}"))
  }

  # Update last check time even if no new posts
  state$last_check <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  write_feed_state(state)

  log_event("feed_check", glue("Found {nrow(new_posts)} new posts"),
            list(total_items = nrow(items), new_items = nrow(new_posts)))

  new_posts
}

# --- Backfill utility --------------------------------------------------------
# Run once to mark existing posts as processed without generating threads

backfill_feed_state <- function(feed_url = SUBSTACK_FEED_URL) {
  cli_h1("Backfilling feed state")
  feed_xml <- fetch_feed(feed_url)
  items <- parse_feed_items(feed_xml)

  if (nrow(items) == 0) {
    cli_alert_warning("No posts to backfill")
    return(invisible(NULL))
  }

  state <- list(
    processed_ids = items$post_id,
    last_check = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
  write_feed_state(state)
  cli_alert_success("Backfilled {nrow(items)} posts into feed state")
  invisible(items)
}
