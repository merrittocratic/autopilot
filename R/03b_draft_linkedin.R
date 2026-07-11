# ============================================================================
# 03b_draft_linkedin.R — Generate LinkedIn post draft via Claude API
# 2026-07-11b: Port substack-to-linkedin skill — links in post body (explicit
#              Merrittocracy call, no first-comment pattern), ~200-300 words,
#              model flags surface in a notes field
# 2026-07-11: Initial version — LinkedIn distribution channel (posts via Zernio)
# ============================================================================
# Takes a richer extracted content summary than the X thread drafter so the
# model has enough grounded source material to avoid splicing stats from one
# section onto another. Both links (article URL + X profile) live in the post
# body per prompts/linkedin_post_system.md. Reuses call_claude() from
# 03_draft_thread.R.
# ============================================================================

source(here::here("R", "00_config.R"))
source(here::here("R", "03_draft_thread.R"))

X_PROFILE_URL <- "x.com/Merrittocratic"

# --- System prompt -----------------------------------------------------------

load_linkedin_prompt <- function() {
  prompt_file <- file.path(PATH_PROMPTS, "linkedin_post_system.md")
  if (!file.exists(prompt_file)) {
    cli_abort("LinkedIn system prompt not found at {prompt_file}")
  }
  read_file(prompt_file)
}

# --- LinkedIn post generation ------------------------------------------------

draft_linkedin_post <- function(content_summary) {
  cli_h2("Drafting LinkedIn post for: {content_summary$title}")

  system_prompt <- load_linkedin_prompt()

  paragraphs_block <- paste(
    sprintf("P%02d. %s", seq_along(content_summary$paragraphs), content_summary$paragraphs),
    collapse = "\n\n"
  )

  data_points <- if (length(content_summary$data_points) > 0) {
    paste(content_summary$data_points, collapse = ", ")
  } else {
    "[none explicitly extracted]"
  }

  user_prompt <- glue("
Generate a LinkedIn recommendation for this Substack piece.

ARTICLE IS THE ONLY SOURCE OF TRUTH.
Do not import outside facts. Do not remap a stat from one player, team, or example onto another.
If this piece is not a strong LinkedIn fit, return a skip recommendation instead of forcing a draft.

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
{data_points}

FULL ARTICLE TEXT:
{content_summary$full_text}

PARAGRAPH-BY-PARAGRAPH SOURCE:
{paragraphs_block}

Return ONLY a JSON object with \"recommendation\", \"post_text\", and \"notes\" fields.
- recommendation: \"post\" or \"skip\"
- post_text: LinkedIn post string when recommendation is \"post\", otherwise null
- notes: reviewer-facing explanation or null
No text outside the JSON object.
")

  raw_response <- call_claude(system_prompt, user_prompt, max_tokens = 2500)

  parse_linkedin_response(raw_response, content_summary$link)
}

# --- Response parsing and validation -----------------------------------------

parse_linkedin_response <- function(raw_response, post_link) {
  clean <- raw_response |>
    str_remove("^```json\\s*") |>
    str_remove("^```\\s*") |>
    str_remove("\\s*```$") |>
    str_trim()

  parsed <- tryCatch(
    fromJSON(clean, simplifyDataFrame = FALSE),
    error = function(e) {
      cli_alert_danger("Failed to parse LinkedIn JSON: {e$message}")
      cli_alert_info("Raw response saved to staging/last_failed_linkedin.txt")
      write_lines(raw_response, here::here("staging", "last_failed_linkedin.txt"))
      NULL
    }
  )

  if (is.null(parsed)) return(NULL)

  recommendation <- parsed$recommendation %||% "post"
  recommendation <- str_to_lower(str_trim(as.character(recommendation)))
  if (!recommendation %in% c("post", "skip")) recommendation <- "post"

  notes <- parsed$notes
  if (is.null(notes) || !nzchar(str_trim(notes %||% ""))) notes <- NA_character_

  if (recommendation == "skip") {
    if (!is.na(notes)) cli_alert_info("LinkedIn skip flag: {notes}")
    cli_alert_info("LinkedIn draft skipped by recommendation")
    return(tibble(
      recommendation = "skip",
      post_text  = NA_character_,
      char_count = NA_integer_,
      word_count = NA_integer_,
      notes      = as.character(notes)
    ))
  }

  if (is.null(parsed$post_text) || !nzchar(str_trim(parsed$post_text %||% ""))) {
    cli_alert_danger("LinkedIn response missing 'post_text' field")
    return(NULL)
  }

  post_text <- str_trim(parsed$post_text)

  # Normalize the sign-off block so both links are always present and always
  # ordered X first, then Substack, per the LinkedIn skill.
  if (!str_detect(post_text, fixed(post_link)) ||
      !str_detect(post_text, fixed(X_PROFILE_URL))) {
    cli_alert_warning("Sign-off links incomplete — normalizing")
  }
  post_text <- post_text |>
    str_remove_all(fixed(post_link)) |>
    str_remove_all(fixed(X_PROFILE_URL)) |>
    str_trim() |>
    paste0("\n\n", X_PROFILE_URL, "\n", post_link)

  char_count <- nchar(post_text)
  word_count <- str_count(post_text, "\\S+")

  if (char_count > LINKEDIN_CHAR_LIMIT) {
    cli_alert_warning("LinkedIn post over limit: {char_count}/{LINKEDIN_CHAR_LIMIT} chars")
  }
  # Skill target is ~200-300 words; the notes field should explain deliberate
  # departures, so only warn when it's silent about being outside the band
  if ((word_count < 150 || word_count > 350) && is.na(notes)) {
    cli_alert_warning("LinkedIn post is {word_count} words (target 200-300) with no explanatory note")
  }

  if (!is.na(notes)) cli_alert_info("Model flag: {notes}")
  cli_alert_success("LinkedIn post drafted ({word_count} words, {char_count} chars)")
  cli_alert("  Hook: {str_trunc(post_text, 100)}")

  tibble(
    recommendation = "post",
    post_text  = post_text,
    char_count = char_count,
    word_count = word_count,
    notes      = as.character(notes)
  )
}
