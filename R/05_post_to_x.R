# ============================================================================
# 05_post_to_x.R — Post approved threads to X via API v2
# ============================================================================
# Reads approved threads from the review queue, posts them as reply chains,
# and updates the queue with posted status and tweet IDs.
# ============================================================================

source(here::here("R", "00_config.R"))
source(here::here("R", "04_queue_write.R"))

# --- OAuth 1.0a signature for X API v2 --------------------------------------
# X API v2 posting requires OAuth 1.0a (user context) for tweet creation

build_x_auth <- function() {
  # These four credentials come from the X Developer Portal app settings
  api_key        <- get_x_api_key()
  api_secret     <- get_x_api_secret()
  access_token   <- get_x_access_token()
  access_secret  <- get_x_access_secret()

  if (any(c(api_key, api_secret, access_token, access_secret) == "")) {
    cli_abort("X API credentials incomplete. Check .env file.")
  }

  # httr2 OAuth 1.0a signing
  list(
    api_key        = api_key,
    api_secret     = api_secret,
    access_token   = access_token,
    access_secret  = access_secret
  )
}

# --- Media upload (X API v1.1 — still required for images) -------------------

upload_image_to_x <- function(image_path, auth) {
  if (is.na(image_path) || !file.exists(image_path)) {
    return(NA_character_)
  }

  cli_alert_info("Uploading image: {basename(image_path)}")

  # Media upload uses v1.1 endpoint with multipart form data
  resp <- request("https://upload.twitter.com/1.1/media/upload.json") |>
    req_oauth_auth_code(
      client = oauth_client(
        id     = auth$api_key,
        secret = auth$api_secret,
        token_url = "https://api.twitter.com/oauth/access_token",
        name   = "merrittocracy-autopilot"
      )
    ) |>
    req_body_multipart(
      media_data = base64enc::base64encode(image_path)
    ) |>
    req_timeout(60) |>
    req_error(is_error = \(resp) FALSE) |>
    req_perform()

  if (resp_status(resp) != 200) {
    cli_alert_warning("Image upload failed ({resp_status(resp)})")
    return(NA_character_)
  }

  media_id <- resp_body_json(resp)$media_id_string
  cli_alert_success("Image uploaded: media_id={media_id}")
  media_id
}

# --- Tweet posting -----------------------------------------------------------

post_tweet <- function(text, reply_to = NULL, media_ids = NULL, auth) {
  body <- list(text = text)

  if (!is.null(reply_to)) {
    body$reply <- list(in_reply_to_tweet_id = reply_to)
  }

  if (!is.null(media_ids)) {
    body$media <- list(media_ids = as.list(media_ids))
  }

  resp <- request("https://api.twitter.com/2/tweets") |>
    req_headers(
      "Content-Type" = "application/json"
    ) |>
    req_body_json(body) |>
    req_oauth_auth_code(
      client = oauth_client(
        id     = auth$api_key,
        secret = auth$api_secret,
        token_url = "https://api.twitter.com/oauth/access_token",
        name   = "merrittocracy-autopilot"
      )
    ) |>
    req_timeout(30) |>
    req_error(is_error = \(resp) FALSE) |>
    req_perform()

  if (resp_status(resp) != 201) {
    body <- resp_body_json(resp)
    cli_alert_danger("Tweet post failed ({resp_status(resp)}): {body$detail %||% 'unknown error'}")
    return(NULL)
  }

  result <- resp_body_json(resp)
  tweet_id <- result$data$id
  cli_alert_success("Tweet posted: {tweet_id}")
  tweet_id
}

# --- Thread posting ----------------------------------------------------------

post_thread <- function(thread_df, auth) {
  cli_h2("Posting thread: {thread_df$title[1]}")

  # Sort by tweet number

  thread_df <- thread_df |> arrange(tweet_number)

  reply_to <- NULL
  posted_ids <- character(0)

  for (i in seq_len(nrow(thread_df))) {
    row <- thread_df[i, ]
    cli_alert_info("Posting tweet {i}/{nrow(thread_df)}...")

    # Handle image attachment
    media_ids <- NULL
    if (row$has_image && !is.na(row$image_path)) {
      media_id <- upload_image_to_x(row$image_path, auth)
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
      auth      = auth
    )

    if (is.null(tweet_id)) {
      cli_alert_danger("Thread posting aborted at tweet {i}")
      log_event("post_error", glue("Thread aborted at tweet {i}"),
                list(post_id = row$post_id, tweet_number = i))
      break
    }

    # Update queue status
    update_queue_status(row$post_id, row$tweet_number, "posted",
                        tweet_id = tweet_id)

    posted_ids <- c(posted_ids, tweet_id)
    reply_to <- tweet_id  # next tweet replies to this one

    # Rate limit courtesy — 1 second between tweets
    if (i < nrow(thread_df)) Sys.sleep(1)
  }

  log_event("thread_posted", glue("Posted {length(posted_ids)}/{nrow(thread_df)} tweets"),
            list(post_id = thread_df$post_id[1], tweet_ids = posted_ids))

  posted_ids
}

# --- Main: post all approved threads -----------------------------------------

post_approved_threads <- function() {
  cli_h1("Checking for approved threads")

  approved <- read_approved_threads()

  if (nrow(approved) == 0) {
    cli_alert_info("Nothing to post")
    return(invisible(NULL))
  }

  auth <- build_x_auth()

  # Group by post_id and post each thread
  approved |>
    group_split(post_id) |>
    walk(\(thread_df) {
      tryCatch(
        post_thread(thread_df, auth),
        error = function(e) {
          cli_alert_danger("Failed to post thread: {e$message}")
          log_event("post_error", e$message,
                    list(post_id = thread_df$post_id[1]))
        }
      )
    })
}
