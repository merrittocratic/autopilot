# ============================================================================
# 03_draft_thread.R — Generate X thread draft via Claude API
# ============================================================================
# Takes extracted post content, sends it to Claude with the Merrittocracy
# voice prompt, and returns a structured thread ready for the review queue.
# ============================================================================

source(here::here("R", "00_config.R"))

# --- System prompt -----------------------------------------------------------

load_system_prompt <- function() {
  prompt_file <- file.path(PATH_PROMPTS, "thread_draft_system.md")
  if (!file.exists(prompt_file)) {
    cli_abort("System prompt not found at {prompt_file}")
  }
  read_file(prompt_file)
}

# --- Claude API call ---------------------------------------------------------

call_claude <- function(system_prompt, user_prompt, max_tokens = 2000) {
  api_key <- get_anthropic_key()

  cli_alert_info("Calling Claude API...")

  resp <- request("https://api.anthropic.com/v1/messages") |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version"  = "2023-06-01",
      "content-type"       = "application/json"
    ) |>
    req_body_json(list(
      model      = "claude-sonnet-4-5",
      max_tokens = max_tokens,
      system     = system_prompt,
      messages   = list(
        list(role = "user", content = user_prompt)
      )
    )) |>
    req_timeout(60) |>
    req_error(is_error = \(resp) FALSE) |>
    req_perform()

  if (resp_status(resp) != 200) {
    body <- resp_body_json(resp)
    cli_abort("Claude API error ({resp_status(resp)}): {body$error$message}")
  }

  body <- resp_body_json(resp)

  # Extract text from content blocks
  text <- body$content |>
    keep(\(block) block$type == "text") |>
    map_chr(\(block) block$text) |>
    paste(collapse = "\n")

  cli_alert_success("Claude response received ({nchar(text)} chars)")
  text
}

# --- Thread generation -------------------------------------------------------

draft_thread <- function(content_summary) {
  cli_h2("Drafting thread for: {content_summary$title}")

  system_prompt <- load_system_prompt()

  user_prompt <- glue("
Generate an X thread for this Substack post.

TITLE: {content_summary$title}
LINK: {content_summary$link}
WORD COUNT: {content_summary$word_count}

OPENING HOOK:
{content_summary$hook}

SECTION HEADERS:
{paste(content_summary$headers, collapse = '\\n')}

POST SKELETON (first sentence of each paragraph):
{content_summary$skeleton}

DATA POINTS FOUND:
{paste(content_summary$data_points, collapse = ', ')}

Return ONLY a JSON array of tweet objects. Each object has:
- \"tweet_number\": integer (1-based)
- \"text\": string (the tweet content, max 280 chars)
- \"has_image\": boolean (true if the key chart should attach here)
- \"is_link_tweet\": boolean (true for the tweet containing the Substack link)

Do NOT include any text outside the JSON array. No preamble, no explanation.
")

  raw_response <- call_claude(system_prompt, user_prompt)

  # Parse the JSON response
  thread <- parse_thread_response(raw_response, content_summary$link)
  thread
}

# --- Response parsing and validation -----------------------------------------

parse_thread_response <- function(raw_response, post_link) {
  # Strip markdown code fences if Claude wraps the JSON
  clean <- raw_response |>
    str_remove("^```json\\s*") |>
    str_remove("^```\\s*") |>
    str_remove("\\s*```$") |>
    str_trim()

  thread <- tryCatch(
    fromJSON(clean, simplifyDataFrame = TRUE),
    error = function(e) {
      cli_alert_danger("Failed to parse thread JSON: {e$message}")
      cli_alert_info("Raw response saved to staging/last_failed_response.txt")
      write_lines(raw_response, here::here("staging", "last_failed_response.txt"))
      return(NULL)
    }
  )

  if (is.null(thread)) return(NULL)

  # Validate structure
  thread <- as_tibble(thread)

  if (!"text" %in% names(thread)) {
    cli_abort("Thread response missing 'text' field")
  }

  # Ensure required columns exist with defaults
  if (!"tweet_number" %in% names(thread)) {
    thread$tweet_number <- seq_len(nrow(thread))
  }
  if (!"has_image" %in% names(thread)) {
    thread$has_image <- FALSE
  }
  if (!"is_link_tweet" %in% names(thread)) {
    thread$is_link_tweet <- FALSE
  }

  # Validate character counts
  thread <- thread |>
    mutate(
      char_count = nchar(text),
      over_limit = char_count > X_CHAR_LIMIT
    )

  if (any(thread$over_limit)) {
    over <- thread |> filter(over_limit)
    cli_alert_warning("{nrow(over)} tweet(s) over {X_CHAR_LIMIT} char limit:")
    walk2(over$tweet_number, over$char_count, \(n, c) {
      cli_alert_warning("  Tweet {n}: {c} chars")
    })
  }

  # Ensure the Substack link appears somewhere in the thread
  has_link <- any(str_detect(thread$text, fixed(post_link)) |
                    str_detect(thread$text, "substack"))
  if (!has_link) {
    cli_alert_warning("No Substack link found in thread — appending to last tweet")
    thread$text[nrow(thread)] <- paste(
      thread$text[nrow(thread)],
      glue("\n\n{post_link}")
    )
    thread$is_link_tweet[nrow(thread)] <- TRUE
    # Recompute char count
    thread$char_count[nrow(thread)] <- nchar(thread$text[nrow(thread)])
  }

  cli_alert_success("Thread drafted: {nrow(thread)} tweets")
  walk(seq_len(nrow(thread)), \(i) {
    row <- thread[i, ]
    icon <- case_when(
      row$has_image ~ "[IMG]",
      row$is_link_tweet ~ "[LINK]",
      TRUE ~ ""
    )
    cli_alert("  {i}/{nrow(thread)} ({row$char_count}c) {icon}: {str_trunc(row$text, 60)}")
  })

  thread
}
