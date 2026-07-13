# ============================================================================
# 05_post_to_x.R — Post approved threads to X via API v2
# 2026-07-13: Add single-thread posting helper for Telegram approval flow
# 2026-04-18: Fix OAuth — drop manual HMAC signing; use httr v1 Token1.0$new()
#             which has battle-tested OAuth 1.0a support with pre-obtained tokens
# ============================================================================
# Reads approved threads from the review queue, posts them as reply chains,
# and updates the queue with posted status and tweet IDs.
# ============================================================================

source(here::here("R", "00_config.R"))
source(here::here("R", "04_queue_write.R"))

library(httr)  # v1 — used only here for OAuth 1.0a signing; httr2 has no equivalent

# --- OAuth 1.0a token for X API ---------------------------------------------
# X API v2 posting requires OAuth 1.0a (user context) for tweet creation.
# httr::Token1.0$new() accepts pre-obtained access tokens directly — no browser
# flow needed.

build_x_auth <- function() {
  api_key       <- get_x_api_key()
  api_secret    <- get_x_api_secret()
  access_token  <- get_x_access_token()
  access_secret <- get_x_access_secret()

  if (any(c(api_key, api_secret, access_token, access_secret) == "")) {
    cli_abort("X API credentials incomplete. Check .env file.")
  }

  Token1.0$new(
    endpoint = oauth_endpoint(
      request   = "https://api.twitter.com/oauth/request_token",
      authorize = "https://api.twitter.com/oauth/authenticate",
      access    = "https://api.twitter.com/oauth/access_token"
    ),
    app = oauth_app("x", key = api_key, secret = api_secret),
    params = list(as_header = TRUE),
    credentials = list(
      oauth_token        = access_token,
      oauth_token_secret = access_secret
    ),
    private_key = NULL
  )
}

# --- Media upload (X API v1.1 — still required for images) -------------------

upload_image_to_x <- function(image_path, token) {
  if (is.na(image_path) || !file.exists(image_path)) {
    return(NA_character_)
  }

  cli_alert_info("Uploading image: {basename(image_path)}")

  resp <- httr::POST(
    "https://upload.twitter.com/1.1/media/upload.json",
    config  = httr::config(token = token),
    body    = list(media_data = base64enc::base64encode(image_path)),
    encode  = "multipart",
    timeout(60)
  )

  if (httr::status_code(resp) != 200) {
    cli_alert_warning(
      "Image upload failed ({httr::status_code(resp)}): {httr::content(resp, 'text', encoding = 'UTF-8')}"
    )
    return(NA_character_)
  }

  media_id <- httr::content(resp)$media_id_string
  cli_alert_success("Image uploaded: media_id={media_id}")
  media_id
}

# --- Tweet posting -----------------------------------------------------------

post_tweet <- function(text, reply_to = NULL, media_ids = NULL, token) {
  body <- list(text = text)

  if (!is.null(reply_to)) {
    body$reply <- list(in_reply_to_tweet_id = reply_to)
  }

  if (!is.null(media_ids)) {
    body$media <- list(media_ids = as.list(media_ids))
  }

  resp <- httr::POST(
    "https://api.twitter.com/2/tweets",
    config      = httr::config(token = token),
    body        = jsonlite::toJSON(body, auto_unbox = TRUE),
    httr::add_headers("Content-Type" = "application/json"),
    timeout(30)
  )

  if (httr::status_code(resp) != 201) {
    err <- httr::content(resp, "text", encoding = "UTF-8")
    cli_alert_danger("Tweet post failed ({httr::status_code(resp)}): {err}")
    return(NULL)
  }

  tweet_id <- httr::content(resp)$data$id
  cli_alert_success("Tweet posted: {tweet_id}")
  tweet_id
}

# --- Thread posting ----------------------------------------------------------

post_thread <- function(thread_df, token) {
  cli_h2("Posting thread: {thread_df$title[1]}")

  thread_df <- thread_df |> arrange(tweet_number)

  reply_to   <- NULL
  posted_ids <- character(0)

  for (i in seq_len(nrow(thread_df))) {
    row <- thread_df[i, ]
    cli_alert_info("Posting tweet {i}/{nrow(thread_df)}...")

    # Handle image attachment
    media_ids <- NULL
    if (isTRUE(as.logical(row$has_image)) && !is.na(row$image_path)) {
      media_id <- upload_image_to_x(row$image_path, token)
      if (!is.na(media_id)) {
        media_ids <- media_id
      }
    }

    # Use tweet_text column (from queue) rather than text (from draft)
    tweet_text <- if ("tweet_text" %in% names(row)) row$tweet_text else row$text

    tweet_id <- post_tweet(
      text      = tweet_text,
      reply_to  = reply_to,
      media_ids = media_ids,
      token     = token
    )

    if (is.null(tweet_id)) {
      cli_alert_danger("Thread posting aborted at tweet {i}")
      log_event("post_error", glue("Thread aborted at tweet {i}"),
                list(post_id = row$post_id, tweet_number = i))
      break
    }

    update_queue_status(row$post_id, row$tweet_number, "posted",
                        tweet_id = tweet_id)

    posted_ids <- c(posted_ids, tweet_id)
    reply_to   <- tweet_id  # next tweet replies to this one

    # Rate limit courtesy — 1 second between tweets
    if (i < nrow(thread_df)) Sys.sleep(1)
  }

  log_event("thread_posted", glue("Posted {length(posted_ids)}/{nrow(thread_df)} tweets"),
            list(post_id = thread_df$post_id[1], tweet_ids = posted_ids))

  posted_ids
}

# --- Shared posting worker ---------------------------------------------------

post_thread_rows <- function(rows) {
  if (nrow(rows) == 0) {
    cli_alert_info("Nothing to post")
    return(invisible(NULL))
  }

  token <- build_x_auth()

  rows |>
    group_split(post_id) |>
    walk(\(thread_df) {
      tryCatch(
        post_thread(thread_df, token),
        error = function(e) {
          cli_alert_danger("Failed to post thread: {e$message}")
          log_event("post_error", e$message,
                    list(post_id = thread_df$post_id[1]))
        }
      )
    })
}

post_selected_thread <- function(post_id) {
  rows <- read_queue_rows("approved") |>
    filter(post_id == !!post_id)

  if (nrow(rows) == 0) {
    cli_alert_warning("No approved thread found for post {post_id}")
    return(invisible(NULL))
  }

  post_thread_rows(rows)
}

# --- Main: post all approved threads -----------------------------------------

post_approved_threads <- function() {
  cli_h1("Checking for approved threads")

  approved <- read_approved_threads()

  if (nrow(approved) == 0) {
    cli_alert_info("Nothing to post")
    return(invisible(NULL))
  }

  post_thread_rows(approved)
}
