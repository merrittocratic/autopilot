# ============================================================================
# 00_config.R — Constants, packages, and path configuration
# ============================================================================
# Merrittocracy Autopilot
# Distribution automation for Substack → X pipeline
# ============================================================================

# --- Packages ----------------------------------------------------------------

suppressPackageStartupMessages({
  library(tidyverse)
  library(httr2)
  library(rvest)
  library(xml2)
  library(jsonlite)
  library(googlesheets4)
  library(cli)
  library(glue)
})

# --- Environment variables ---------------------------------------------------
# Loaded from .env file in project root (never committed to git)
# Use Sys.setenv() or a .Renviron file as fallback

load_env <- function(env_file = here::here(".env")) {
  if (!file.exists(env_file)) {
    # No .env file needed when secrets are injected via autopilot-env.sh
    return(invisible(FALSE))
  }
  lines <- readLines(env_file, warn = FALSE)
  lines <- lines[!grepl("^#|^\\s*$", lines)]  # drop comments and blanks
  for (line in lines) {
    parts <- strsplit(line, "=", fixed = TRUE)[[1]]
    if (length(parts) >= 2) {
      key <- trimws(parts[1])
      val <- trimws(paste(parts[-1], collapse = "="))
      # Strip surrounding quotes if present
      val <- gsub("^['\"]|['\"]$", "", val)
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
  cli_alert_success(".env loaded")
  invisible(TRUE)
}

# --- Google Sheets auth (service account) ------------------------------------

GOOGLE_SA_KEY <- here::here(".secrets", "google-service-account.json")

if (file.exists(GOOGLE_SA_KEY)) {
  gs4_auth(path = GOOGLE_SA_KEY)
  cli_alert_success("Google Sheets authenticated via service account")
} else {
  cli_alert_warning("Google service account key not found at {GOOGLE_SA_KEY}")
  cli_alert_info("Google Sheets operations will fail")
}

# --- Constants ---------------------------------------------------------------

SUBSTACK_FEED_URL <- "https://themerrittocracy.substack.com/feed"
SUBSTACK_BASE_URL <- "https://themerrittocracy.substack.com"

# Paths (relative to project root via here::here())
PATH_DATA       <- here::here("data")
PATH_STAGING    <- here::here("staging")
PATH_IMAGES     <- here::here("staging", "images")
PATH_PROMPTS    <- here::here("prompts")
PATH_LOGS       <- here::here("logs")

# Feed state file — tracks which posts we've already processed
FEED_STATE_FILE <- file.path(PATH_DATA, "feed_state.json")

# Google Sheet ID for the review queue (set after creating the sheet)
REVIEW_SHEET_ID <- Sys.getenv("REVIEW_SHEET_ID", unset = "")

# API keys (loaded from .env)
get_anthropic_key <- function() {
  key <- Sys.getenv("ANTHROPIC_API_KEY", unset = "")
  if (key == "") cli_abort("ANTHROPIC_API_KEY not set. Check your .env file.")
  key
}

get_x_bearer_token <- function() {
  key <- Sys.getenv("X_BEARER_TOKEN", unset = "")
  if (key == "") cli_abort("X_BEARER_TOKEN not set. Check your .env file.")
  key
}

get_x_api_key <- function() Sys.getenv("X_API_KEY", unset = "")
get_x_api_secret <- function() Sys.getenv("X_API_SECRET", unset = "")
get_x_access_token <- function() Sys.getenv("X_ACCESS_TOKEN", unset = "")
get_x_access_secret <- function() Sys.getenv("X_ACCESS_SECRET", unset = "")

# --- Thread defaults ---------------------------------------------------------

# Max characters per tweet (X limit)
X_CHAR_LIMIT <- 280

# Target thread length
THREAD_MIN_TWEETS <- 3
THREAD_MAX_TWEETS <- 6

# --- Scheduling defaults -----------------------------------------------------

# How often to check RSS feed (minutes) — used in launchd plist
FEED_CHECK_INTERVAL <- 15

# How often to check review queue for approved posts (minutes)
QUEUE_CHECK_INTERVAL <- 5

# --- Ensure directories exist ------------------------------------------------

ensure_dirs <- function() {
  dirs <- c(PATH_DATA, PATH_STAGING, PATH_IMAGES, PATH_LOGS)
  walk(dirs, \(d) {
    if (!dir.exists(d)) {
      dir.create(d, recursive = TRUE)
      cli_alert_info("Created directory: {d}")
    }
  })
}

# --- Telegram notification --------------------------------------------------

notify_telegram <- function(message, chat_id = "8676616323") {
  bot_token <- Sys.getenv("TELEGRAM_BOT_TOKEN", unset = "")
  if (bot_token == "") {
    cli_alert_warning("TELEGRAM_BOT_TOKEN not set — skipping notification")
    return(invisible(NULL))
  }

  # Use req_error(..., is_error = FALSE) so httr2 returns a response object
  # on 4xx/5xx instead of throwing, letting us inspect the status and retry.
  send_msg <- function(parse_mode = "Markdown") {
    body <- list(chat_id = chat_id, text = message)
    if (!is.null(parse_mode)) body$parse_mode <- parse_mode
    tryCatch(
      request(glue("https://api.telegram.org/bot{bot_token}/sendMessage")) |>
        req_body_json(body) |>
        req_error(is_error = function(resp) FALSE) |>
        req_perform(),
      error = function(e) {
        cli_alert_warning("Telegram request error: {e$message}")
        NULL
      }
    )
  }

  resp <- send_msg("Markdown")

  # 400 on Markdown usually means a bare * or _ in dynamic content (e.g. article
  # titles like "Who the F* is..."). Retry as plain text.
  if (!is.null(resp) && resp_status(resp) == 400) {
    cli_alert_warning("Telegram Markdown parse error — retrying as plain text")
    resp <- send_msg(NULL)
  }

  if (!is.null(resp) && resp_status(resp) == 200) {
    cli_alert_success("Telegram notification sent")
  } else if (!is.null(resp)) {
    cli_alert_warning("Telegram notification failed (HTTP {resp_status(resp)})")
  }

  invisible(resp)
}

# --- Logging helper ----------------------------------------------------------

log_event <- function(event_type, message, details = list()) {
  log_file <- file.path(PATH_LOGS, glue("{Sys.Date()}_autopilot.log"))
  entry <- list(
    timestamp  = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    event_type = event_type,
    message    = message,
    details    = details
  )
  write_lines(
    toJSON(entry, auto_unbox = TRUE),
    log_file,
    append = TRUE
  )
}
