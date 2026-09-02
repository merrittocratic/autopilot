#!/usr/bin/env Rscript
# ============================================================================
# x-fact-check.R -- Tier-2 drafted-reply fact-check gate
# ============================================================================
# 2026-09-02 -- Initial build, per SPEC-tier2-fact-check.md (approved by
#               Steve 2026-09-02). Follow-up to the 2026-08-31 fabrication
#               incident (8bd4ca7, bc2466e): those fixes stop bad *data*
#               from reaching a draft. This stops the draft step itself
#               from hallucinating content with no data behind it, via an
#               independent post-draft verification pass.
#
# This script does NOT touch Telegram and does NOT own the Tier-2 drafting
# flow. Per repo convention (see x-review.R, x-surfacing-log.R), the
# OpenClaw-side drafting flow (owned by Earnest) is responsible for calling
# this script at the trigger point -- wherever a Tier-2 draft is currently
# about to be queued for Telegram -- and for acting on its verdict before
# surfacing anything to Steve.
#
# Contract:
#   stdin (single JSON document):
#     {
#       "candidate":  { ...full x-monitor.R candidate JSON... },
#       "tweet_text": "the original tweet text",
#       "draft":      "the drafted reply text"
#     }
#
#   stdout (single JSON document):
#     {
#       "fact_check":    "passed" | "failed_skipped" | "failed_stripped" | "skipped_no_claims",
#       "draft":         "<draft to surface, possibly stripped, or null if failed_skipped>",
#       "failed_claims": ["claim -- why it failed", ...],
#       "notes":         "one-line rationale"
#     }
#
#   The caller is expected to:
#     - Surface `draft` to Telegram when fact_check is "passed", "failed_stripped",
#       or "skipped_no_claims".
#     - NOT surface anything when fact_check is "failed_skipped" (treat as SKIP).
#     - Append the `fact_check` value to the surfacing record when piping to
#       x-surfacing-log.R (accepts an optional `fact_check` field).
#
# Scope: Tier 2 only, per spec -- do not call this for Tier 1A/1B/1C drafts
# without re-checking cost/volume first (see SPEC-tier2-fact-check.md).
# ============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(stringr)
  library(glue)
  library(readr)
})

HOME_DIR      <- Sys.getenv("HOME")
ANTHROPIC_KEY <- Sys.getenv("ANTHROPIC_API_KEY")
MODEL_DATA    <- file.path(HOME_DIR, "nfl-draft-model", "data", "05_scored_2026.rds")
BOXSCORE_SLATE <- file.path(HOME_DIR, "boxscore-prophet", "output", "latest", "scored_slate.csv")
ANTHROPIC_URL <- "https://api.anthropic.com/v1/messages"
HAIKU_MODEL   <- "claude-haiku-4-5"

# --- Skip-if-no-claims gate --------------------------------------------------
# Cheap, no API call. Doesn't need to be perfect -- just needs to avoid
# spending a call on drafts with nothing to check (pure opinion/banter).
# Triggers on: a run of 2+ capitalized words (player/team names) OR any digit
# (stats, percentages, years).
has_verifiable_claims <- function(text) {
  if (!nzchar(str_trim(text))) return(FALSE)
  name_like <- str_detect(text, "\\b([A-Z][a-zA-Z'.-]*\\s+){1,3}[A-Z][a-zA-Z'.-]*\\b")
  digit_like <- str_detect(text, "\\d")
  name_like || digit_like
}

# --- Tool definitions ---------------------------------------------------------
QUERY_MODEL_DATA_TOOL <- list(
  name = "query_model_data",
  description = paste(
    "Look up a player by name in our own model data -- the NFL draft",
    "prospect model and the current-week veteran (QB/RB/WR/TE) slate.",
    "Returns matching row(s) if found, or a not-found message. Use this to",
    "re-confirm a claim against source data directly, not to look up facts",
    "our model doesn't cover."
  ),
  input_schema = list(
    type = "object",
    properties = list(
      player_name = list(
        type = "string",
        description = "Full player name as it would appear in our data, e.g. 'Justin Herbert'."
      )
    ),
    required = list("player_name")
  )
)

# Anthropic-hosted web search tool. max_uses caps it at one search; if the
# account/API version doesn't support this tool, call_haiku() falls back to
# a reduced tool set rather than failing the whole check.
WEB_SEARCH_TOOL <- list(
  type     = "web_search_20250305",
  name     = "web_search",
  max_uses = 1
)

# Executes the query_model_data tool locally. Best-effort -- any read
# failure (file missing, bad format) degrades to "no match" rather than
# erroring the whole check.
execute_query_model_data <- function(player_name) {
  results <- list()

  draft_rows <- tryCatch({
    md <- readRDS(MODEL_DATA)
    md[str_detect(str_to_lower(md$player_name), fixed(str_to_lower(player_name))), , drop = FALSE]
  }, error = function(e) NULL)
  if (!is.null(draft_rows) && nrow(draft_rows) > 0) {
    results$draft_prospect <- as.list(draft_rows[1, ])
  }

  veteran_rows <- tryCatch({
    vs <- read_csv(BOXSCORE_SLATE, show_col_types = FALSE)
    vs[str_detect(str_to_lower(vs$player_name), fixed(str_to_lower(player_name))), , drop = FALSE]
  }, error = function(e) NULL)
  if (!is.null(veteran_rows) && nrow(veteran_rows) > 0) {
    results$veteran <- as.list(veteran_rows[1, ])
  }

  if (length(results) == 0) {
    return("No matching player found in draft-prospect or veteran model data.")
  }
  toJSON(results, auto_unbox = TRUE, na = "null")
}

# --- Claude API plumbing ------------------------------------------------------
# Progressively degrades the tool set on failure (e.g. web_search not
# enabled on this account/API version) rather than failing the whole check
# outright. The final fallback (no tools) still produces a grounding
# verdict, just without the option to look anything up.
call_haiku <- function(messages, tools) {
  attempt <- function(use_tools) {
    body <- list(model = HAIKU_MODEL, max_tokens = 1024, messages = messages)
    if (!is.null(use_tools) && length(use_tools) > 0) body$tools <- use_tools
    resp <- tryCatch(
      POST(
        ANTHROPIC_URL,
        add_headers(
          "x-api-key"         = ANTHROPIC_KEY,
          "anthropic-version" = "2023-06-01",
          "content-type"      = "application/json"
        ),
        body   = toJSON(body, auto_unbox = TRUE),
        encode = "raw",
        timeout(30)
      ),
      error = function(e) NULL
    )
    if (is.null(resp) || status_code(resp) != 200) return(NULL)
    tryCatch(content(resp, as = "parsed", simplifyVector = FALSE), error = function(e) NULL)
  }

  if (!is.null(tools) && length(tools) > 0) {
    r <- attempt(tools)
    if (!is.null(r)) return(r)
    # Fall back: drop the hosted web_search tool, keep the custom tool.
    custom_only <- Filter(function(t) is.null(t$type), tools)
    if (length(custom_only) > 0) {
      r <- attempt(custom_only)
      if (!is.null(r)) return(r)
    }
  }
  attempt(NULL)
}

extract_text <- function(resp) {
  if (is.null(resp) || is.null(resp$content)) return("")
  text_blocks <- Filter(function(b) identical(b$type, "text"), resp$content)
  if (length(text_blocks) == 0) return("")
  text_blocks[[length(text_blocks)]]$text %||% ""
}

parse_final_json <- function(text) {
  cleaned <- str_trim(text)
  cleaned <- str_remove(cleaned, "^```(json)?\\s*")
  cleaned <- str_remove(cleaned, "\\s*```$")
  fromJSON(cleaned, simplifyVector = FALSE)
}

extract_model_fields <- function(candidate) {
  keys <- names(candidate)
  # Exclude prospect_match/veteran_match -- those are booleans about whether
  # a match happened, not grounding data the draft can cite.
  keys <- keys[(str_starts(keys, "prospect_") | str_starts(keys, "veteran_")) &
                 !str_ends(keys, "_match")]
  keys <- Filter(function(k) {
    v <- candidate[[k]]
    !is.null(v) && !(length(v) == 1 && is.na(v))
  }, keys)
  if (length(keys) == 0) {
    return("(none -- no prospect or veteran match was found for this candidate)")
  }
  paste(
    sprintf("- %s: %s", keys, vapply(keys, function(k) as.character(candidate[[k]]), character(1))),
    collapse = "\n"
  )
}

# --- One verification round-trip ----------------------------------------------
# Exactly one additional lookup is possible, structurally: if the first
# call requests the custom tool, the follow-up call that carries the tool
# result back is made with tools = NULL, so a second lookup can't happen.
# The hosted web_search tool is capped via max_uses = 1 on the request itself.
check_once <- function(draft, tweet_text, model_fields_text) {
  prompt <- glue(
    "You are a fact-checking gate for automated sports-analytics X replies. ",
    "You will be shown a drafted reply, the tweet it responds to, and the ",
    "structured model data (if any) that was available to the drafting step.\n\n",
    "Verify every player name, team, stat, or specific factual claim in the ",
    "draft traces to (a) the literal tweet text below, or (b) one of the ",
    "structured data fields below. These are the ONLY facts available to ",
    "ground the draft -- if a claim isn't traceable to one of these two ",
    "sources, it is UNVERIFIED, even if it sounds plausible or you believe ",
    "it to be true from general knowledge.\n\n",
    "If a claim is a real-world fact not covered by the tweet or the ",
    "structured data (e.g. current injury status, a trade that has already ",
    "happened), you may use the query_model_data tool (one lookup) or the ",
    "web_search tool (one search) to check it -- not both, and only once ",
    "total. If you can't resolve a claim with at most one lookup, treat it ",
    "as unverifiable and fail it.\n\n",
    "Tweet text: {tweet_text}\n\n",
    "Drafted reply: {draft}\n\n",
    "Structured data available to the drafter:\n{model_fields_text}\n\n",
    "Respond with ONLY valid JSON (no markdown fences), in this exact shape:\n",
    '{{"pass": true|false, "failed_claims": ["claim -- why it fails"], ',
    '"stripped_draft": "draft text with only the failed claim(s) removed, ',
    'preserving voice and the rest of the reply, or null if not applicable", ',
    '"notes": "one sentence"}}'
  )

  messages <- list(list(role = "user", content = prompt))
  resp1 <- call_haiku(messages, tools = list(QUERY_MODEL_DATA_TOOL, WEB_SEARCH_TOOL))

  if (is.null(resp1)) {
    return(list(
      pass = FALSE,
      failed_claims = list("fact-check API call failed"),
      stripped_draft = NULL,
      notes = "API error -- treated as unverifiable"
    ))
  }

  tool_blocks <- Filter(function(b) identical(b$type, "tool_use"), resp1$content %||% list())
  query_block <- Filter(function(b) identical(b$name, "query_model_data"), tool_blocks)

  if (length(query_block) > 0) {
    tb <- query_block[[1]]
    lookup_result <- execute_query_model_data(tb$input$player_name %||% "")
    messages2 <- c(
      messages,
      list(list(role = "assistant", content = resp1$content)),
      list(list(role = "user", content = list(list(
        type = "tool_result", tool_use_id = tb$id, content = lookup_result
      ))))
    )
    resp2 <- call_haiku(messages2, tools = NULL)
    final_text <- extract_text(resp2)
  } else {
    final_text <- extract_text(resp1)
  }

  parsed <- tryCatch(parse_final_json(final_text), error = function(e) NULL)
  if (is.null(parsed)) {
    return(list(
      pass = FALSE,
      failed_claims = list("could not parse fact-check response"),
      stripped_draft = NULL,
      notes = "parse error -- treated as unverifiable"
    ))
  }
  parsed
}

# --- Top-level gate, with one strip-and-retry ---------------------------------
run_fact_check <- function(draft, tweet_text, candidate, allow_retry = TRUE) {
  if (!has_verifiable_claims(draft)) {
    return(list(fact_check = "skipped_no_claims", draft = draft, failed_claims = list(), notes = "No verifiable claims detected"))
  }

  model_fields_text <- extract_model_fields(candidate)
  result <- check_once(draft, tweet_text, model_fields_text)

  if (isTRUE(result$pass)) {
    return(list(fact_check = "passed", draft = draft, failed_claims = list(), notes = result$notes %||% ""))
  }

  failed   <- result$failed_claims %||% list("unspecified claim failed")
  stripped <- result$stripped_draft

  if (allow_retry && !is.null(stripped) && nzchar(str_trim(as.character(stripped)))) {
    retry <- run_fact_check(as.character(stripped), tweet_text, candidate, allow_retry = FALSE)
    # "skipped_no_claims" counts as a retry success too -- if stripping the
    # failed claim left nothing else that needs verifying, the remainder is
    # safe to surface, not a second failure.
    if (retry$fact_check %in% c("passed", "skipped_no_claims")) {
      return(list(fact_check = "failed_stripped", draft = stripped, failed_claims = failed, notes = result$notes %||% ""))
    }
  }

  list(fact_check = "failed_skipped", draft = NULL, failed_claims = failed, notes = result$notes %||% "")
}

# --- Entry point ---------------------------------------------------------------
input <- tryCatch(
  jsonlite::fromJSON(file("stdin"), simplifyVector = FALSE),
  error = function(e) stop("Failed to parse stdin JSON: ", e$message)
)

candidate  <- input$candidate %||% list()
tweet_text <- input$tweet_text %||% ""
draft      <- input$draft %||% ""

if (!nzchar(str_trim(draft)) || identical(str_trim(draft), "SKIP")) {
  cat(toJSON(list(
    fact_check = "skipped_no_claims", draft = draft,
    failed_claims = list(), notes = "Empty or SKIP draft -- nothing to check"
  ), auto_unbox = TRUE))
  quit(save = "no")
}

result <- tryCatch(
  run_fact_check(draft, tweet_text, candidate),
  error = function(e) list(
    fact_check = "failed_skipped", draft = NULL,
    failed_claims = list(glue("fact-check error: {e$message}")),
    notes = "Unhandled error -- treated as unverifiable"
  )
)

cat(toJSON(result, auto_unbox = TRUE, na = "null"))
