#!/usr/bin/env Rscript
# ============================================================================
# voice-sample-refresh.R -- cache recent article excerpts for reply-draft
# voice calibration
# ============================================================================
# Pools the 5 most recently published articles across ALL content/published
# topic folders (recency-pooled, not topic-matched -- 2026-09-19 chat) and
# writes a fixed-length excerpt from each to a single cached text file that
# the reply-draft prompts read as {voice_sample}.
#
# CACHING IS THE ENTIRE POINT OF THIS SCRIPT -- read this before changing
# anything. gpt-5.4-mini (the model behind x-monitor-fast/slow/rss-check,
# per Earnest) auto-caches a stable PREFIX above ~1024 tokens, at a 50-90%
# discount, for up to 24h. For that to actually fire:
#   1. voice_sample.txt's CONTENT must be 100% deterministic given the same
#      article pool -- no timestamps, no run-time-dependent text, no random
#      ordering. Same 5 articles in -> byte-identical file out, every time.
#   2. The file is only rewritten when the actual selected article set
#      changes (a new piece publishes) -- not on every cron tick -- so the
#      prefix Earnest pastes into gpt-5.4-mini calls stays byte-identical
#      across an entire day's (or more) worth of reply drafts.
#   3. Earnest must paste this file's content VERBATIM, unmodified, as an
#      early/stable part of the assembled prompt (see the "Voice
#      calibration" section added to each prompts/x_reply_tier_*.md) --
#      never re-wrapped, dated, or reformatted per-call. Any per-call
#      variation in this block defeats caching for that call AND breaks
#      the shared-prefix match for every other call that day.
# Any change to this script must preserve determinism and idempotency.
#
# 2026-09-19 -- initial version.
# ============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(jsonlite)
  library(cli)
  library(digest)
})

HOME_DIR    <- Sys.getenv("HOME")
AUTOPILOT   <- file.path(HOME_DIR, "autopilot")
CONTENT_DIR <- file.path(HOME_DIR, "content", "published")

OUT_DIR       <- file.path(AUTOPILOT, "data", "voice-sample")
VOICE_SAMPLE  <- file.path(OUT_DIR, "voice_sample.txt")
MANIFEST_PATH <- file.path(OUT_DIR, "manifest.json")
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

N_ARTICLES         <- 5    # pooled across all topics, most recent first
EXCERPT_WORD_TARGET <- 350  # per article -- see 2026-09-19 chat: excerpts,
                             # not full articles (register mismatch, signal
                             # dilution, one-bad-piece-dominates risk)

# --- Discover + sort articles deterministically ------------------------------
# Filenames are "YYYY-MM-DD title.md" (confirmed against all 51 current
# files) -- parse the date from the filename, not mtime, since mtime can
# change on checkout/copy without the content or its recency actually
# changing. Falls back to mtime only if a file doesn't match the pattern.
# Tiebreak on filename (not file order from the OS) so sort is reproducible.

discover_articles <- function() {
  if (!dir.exists(CONTENT_DIR)) return(tibble())

  files <- list.files(CONTENT_DIR, pattern = "\\.md$", recursive = TRUE, full.names = TRUE)
  if (length(files) == 0) return(tibble())

  parsed_date <- vapply(files, function(f) {
    m <- regmatches(basename(f), regexpr("^\\d{4}-\\d{2}-\\d{2}", basename(f)))
    if (length(m) == 1 && nchar(m) == 10) m else format(file.info(f)$mtime, "%Y-%m-%d")
  }, character(1))

  tibble(file = files, date = parsed_date) |>
    arrange(desc(date), desc(basename(file)))
}

# --- Deterministic excerpt extraction ----------------------------------------
# Strip the H1 title line, bare "---" dividers, and "#"-prefixes on
# subheadings (kept as their own paragraph -- these are often voice-y
# themselves, e.g. "Tenacious D", "Not My Problem" -- just without the
# literal "##" characters bleeding into flowing text). Paragraphs
# (one per non-blank line, matching this content's own convention) are
# accumulated whole, in order, stopping once EXCERPT_WORD_TARGET is
# reached -- never truncated mid-paragraph or mid-sentence. Pure text
# processing, no LLM call, no randomness -- same file in, same excerpt out.

extract_excerpt <- function(path) {
  lines <- readLines(path, warn = FALSE)

  title_line <- which(grepl("^#\\s+", lines))[1]
  title <- if (!is.na(title_line)) {
    sub("^#\\s+", "", lines[title_line])
  } else {
    tools::file_path_sans_ext(sub("^\\d{4}-\\d{2}-\\d{2}\\s+", "", basename(path)))
  }

  body_lines <- lines
  if (!is.na(title_line)) body_lines <- body_lines[-title_line]
  body_lines <- body_lines[!grepl("^\\s*---\\s*$", body_lines)]
  body_lines <- sub("^#+\\s+", "", body_lines)          # de-hash subheadings
  body_lines <- trimws(body_lines)
  paragraphs <- body_lines[nzchar(body_lines)]            # drop blank lines

  if (length(paragraphs) == 0) return(list(title = title, excerpt = ""))

  word_counts   <- lengths(strsplit(paragraphs, "\\s+"))
  cum_words     <- cumsum(word_counts)
  # Always keep at least the first paragraph, even if it alone exceeds the
  # target -- an empty excerpt is worse than one slightly-long paragraph.
  keep_n <- max(1, sum(cum_words <= EXCERPT_WORD_TARGET))
  if (keep_n < length(paragraphs) && cum_words[keep_n] < EXCERPT_WORD_TARGET) {
    keep_n <- keep_n + 1   # include the paragraph that crosses the threshold
  }

  list(title = title, excerpt = paste(paragraphs[seq_len(keep_n)], collapse = "\n\n"))
}

# --- Main ---------------------------------------------------------------------

cli_h1("Voice sample refresh")

articles <- discover_articles()
if (nrow(articles) == 0) {
  cli_alert_warning("No articles found under {CONTENT_DIR} -- leaving any existing voice_sample.txt untouched")
  quit(save = "no")
}

selected <- articles |> slice_head(n = N_ARTICLES)
cli_alert_info("Selected {nrow(selected)} most recent article(s): {paste(basename(selected$file), collapse = ', ')}")

pieces <- map(selected$file, extract_excerpt)
blocks <- map_chr(pieces, ~ glue::glue("### {.x$title}\n\n{.x$excerpt}"))
candidate_text <- paste(blocks, collapse = "\n\n---\n\n")
candidate_hash <- digest(candidate_text, algo = "sha256")

previous <- tryCatch(fromJSON(MANIFEST_PATH, simplifyVector = FALSE), error = function(e) NULL)

if (!is.null(previous) && identical(previous$content_hash, candidate_hash) && file.exists(VOICE_SAMPLE)) {
  cli_alert_info("Selected article set unchanged -- voice_sample.txt left as-is (no cache-breaking rewrite)")
  quit(save = "no")
}

writeLines(candidate_text, VOICE_SAMPLE)

manifest <- list(
  generated_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  content_hash  = candidate_hash,
  n_articles    = nrow(selected),
  excerpt_words = EXCERPT_WORD_TARGET,
  articles      = map2(selected$file, selected$date, ~ list(file = basename(.x), date = .y))
)
write(toJSON(manifest, auto_unbox = TRUE, pretty = TRUE), MANIFEST_PATH)

cli_alert_success("{VOICE_SAMPLE} rewritten -- article set changed")
