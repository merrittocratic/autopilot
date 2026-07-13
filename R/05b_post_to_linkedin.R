# ============================================================================
# 05b_post_to_linkedin.R — Post approved LinkedIn drafts via Zernio API
# 2026-07-13: Add single-draft posting helper for Telegram approval flow
# 2026-07-11b: Drop firstComment — links live in post body per
#              substack-to-linkedin skill (explicit Merrittocracy call)
# 2026-07-11: Initial version — LinkedIn distribution channel
# ============================================================================
# Reads approved posts from the "linkedin" tab of the review queue and posts
# them to the personal LinkedIn profile through Zernio (zernio.com), which
# holds the LinkedIn OAuth connection. The Zernio HTTP call is isolated in
# post_linkedin_via_zernio() so the backend can be swapped (e.g. for the
# direct LinkedIn API) without touching queue logic.
#
# Zernio API reference: https://docs.zernio.com
#   POST /v1/posts               — create post (publishNow for immediate)
#   GET  /v1/accounts/health     — connection/token health per account
# Error contract: 403 ACCOUNT_DISCONNECTED (needs OAuth reconnect in Zernio
# dashboard), 409 duplicate content within 24h, 429 rate limited.
# ============================================================================

source(here::here("R", "00_config.R"))
source(here::here("R", "04b_queue_linkedin.R"))

# --- Connection health check --------------------------------------------------
# Advisory pre-flight: catches an expired LinkedIn connection BEFORE a posting
# attempt fails, and pings Telegram so the reconnect happens promptly. Zernio
# cannot refresh a dead LinkedIn token headlessly — a human has to redo the
# OAuth flow in their dashboard.

check_linkedin_health <- function() {
  resp <- tryCatch(
    request(glue("{ZERNIO_API_BASE}/accounts/health")) |>
      req_auth_bearer_token(get_zernio_api_key()) |>
      req_timeout(30) |>
      req_error(is_error = \(resp) FALSE) |>
      req_perform(),
    error = function(e) {
      cli_alert_warning("Zernio health check unreachable: {e$message}")
      NULL
    }
  )

  # Health endpoint trouble is advisory only — let the post attempt decide
  if (is.null(resp) || resp_status(resp) != 200) {
    if (!is.null(resp)) {
      cli_alert_warning("Zernio health check returned HTTP {resp_status(resp)}")
    }
    return(TRUE)
  }

  body       <- resp_body_json(resp)
  account_id <- get_zernio_linkedin_account_id()

  acct <- body$accounts |>
    keep(\(a) identical(a$accountId, account_id)) |>
    pluck(1, .default = NULL)

  if (is.null(acct)) {
    cli_alert_warning("LinkedIn account {account_id} not found in Zernio — check ZERNIO_LINKEDIN_ACCOUNT_ID")
    return(TRUE)
  }

  if (isTRUE(acct$needsReconnect) || isFALSE(acct$tokenValid)) {
    cli_alert_danger("LinkedIn connection needs reconnect in Zernio dashboard")
    notify_telegram(paste(
      "\u26A0\uFE0F LinkedIn connection expired.",
      "Reconnect it in the Zernio dashboard (zernio.com) —",
      "approved LinkedIn posts are on hold until then."
    ))
    log_event("linkedin_disconnected", "Zernio reports LinkedIn needs reconnect",
              list(status = acct$status))
    return(FALSE)
  }

  cli_alert_success("LinkedIn connection healthy")
  TRUE
}

# --- Zernio post call (the swappable backend) ----------------------------------

post_linkedin_via_zernio <- function(post_text, image_url = NA_character_) {
  body <- list(
    content    = post_text,
    publishNow = TRUE,
    platforms  = list(list(
      platform  = "linkedin",
      accountId = get_zernio_linkedin_account_id()
    ))
  )

  if (!is.na(image_url) && nzchar(image_url)) {
    body$mediaItems <- list(list(type = "image", url = image_url))
  }

  resp <- request(glue("{ZERNIO_API_BASE}/posts")) |>
    req_auth_bearer_token(get_zernio_api_key()) |>
    req_body_json(body) |>
    req_timeout(60) |>
    req_error(is_error = \(resp) FALSE) |>
    req_perform()

  status <- resp_status(resp)

  if (status %in% c(200, 201)) {
    zernio_id <- resp_body_json(resp)$post$`_id` %||% NA_character_
    cli_alert_success("LinkedIn post published (Zernio id: {zernio_id})")
    return(zernio_id)
  }

  err_body <- tryCatch(resp_body_string(resp), error = \(e) "")

  if (status == 403) {
    # ACCOUNT_DISCONNECTED — token died between health check and post
    cli_alert_danger("LinkedIn account disconnected — reconnect in Zernio dashboard")
    notify_telegram(paste(
      "\u26A0\uFE0F LinkedIn post failed: account disconnected.",
      "Reconnect in the Zernio dashboard (zernio.com)."
    ))
  } else if (status == 409) {
    cli_alert_warning("Zernio rejected as duplicate (same content within 24h)")
  } else if (status == 429) {
    cli_alert_warning("Zernio rate limited — will retry on next --post run")
  } else {
    cli_alert_danger("Zernio post failed (HTTP {status}): {str_trunc(err_body, 300)}")
  }

  log_event("linkedin_post_error", glue("Zernio HTTP {status}"),
            list(body = str_trunc(err_body, 500)))
  NULL
}

# --- Shared posting worker ------------------------------------------------------

post_linkedin_rows <- function(rows) {
  if (nrow(rows) == 0) {
    cli_alert_info("Nothing to post to LinkedIn")
    return(invisible(NULL))
  }

  if (!check_linkedin_health()) {
    cli_alert_warning("Skipping LinkedIn posting until connection is restored")
    return(invisible(NULL))
  }

  pwalk(
    rows |> select(post_id, title, post_text, image_url),
    \(post_id, title, post_text, image_url) {
      cli_h2("Posting to LinkedIn: {title}")

      zernio_id <- tryCatch(
        post_linkedin_via_zernio(post_text, image_url),
        error = function(e) {
          cli_alert_danger("LinkedIn post failed: {e$message}")
          log_event("linkedin_post_error", e$message, list(post_id = post_id))
          NULL
        }
      )

      if (!is.null(zernio_id)) {
        update_linkedin_status(post_id, "posted", linkedin_post_id = zernio_id)
        log_event("linkedin_posted", glue("Posted to LinkedIn: {title}"),
                  list(post_id = post_id, zernio_id = zernio_id))
      }
    }
  )
}

post_selected_linkedin <- function(post_id) {
  rows <- read_linkedin_rows("approved") |>
    filter(post_id == !!post_id)

  if (nrow(rows) == 0) {
    cli_alert_warning("No approved LinkedIn draft found for post {post_id}")
    return(invisible(NULL))
  }

  post_linkedin_rows(rows)
}

# --- Main: post all approved LinkedIn drafts -----------------------------------

post_approved_linkedin <- function() {
  cli_h1("Checking for approved LinkedIn posts")

  approved <- read_approved_linkedin()

  if (nrow(approved) == 0) {
    cli_alert_info("Nothing to post to LinkedIn")
    return(invisible(NULL))
  }

  post_linkedin_rows(approved)
}
