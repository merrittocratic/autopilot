# ============================================================================
# 02_extract_content.R — Extract structured content from Substack post HTML
# 2026-04-18: Add fetch_hero_image() — og:image from post page as image_paths[1]
# ============================================================================
# Takes the raw HTML content from the RSS feed and extracts:
#   - Title and subtitle
#   - Opening hook (first 1-2 paragraphs)
#   - Section headers and their content
#   - Image URLs (downloaded locally for X posting)
#   - Key data points (numbers, percentages, ranges)
# ============================================================================

source(here::here("R", "00_config.R"))

# --- Content extraction ------------------------------------------------------

extract_post_content <- function(post_row) {
  cli_h2("Extracting content: {post_row$title}")

  html <- read_html(post_row$content)

  # --- Text extraction ---
  paragraphs <- html |>
    html_elements("p") |>
    html_text2() |>
    str_squish() |>
    discard(\(x) x == "" | nchar(x) < 10)

  headers <- html |>
    html_elements("h1, h2, h3") |>
    html_text2() |>
    str_squish()

  # Opening hook: first two substantive paragraphs
  hook <- paragraphs[1:min(2, length(paragraphs))] |>
    paste(collapse = "\n\n")

  # --- Image extraction ---
  image_urls <- html |>
    html_elements("img") |>
    html_attr("src") |>
    discard(is.na) |>
    # Filter out tiny tracking pixels and Substack UI elements
    keep(\(url) {
      !str_detect(url, "pixel|tracking|badge|button|avatar|favicon") &
        !str_detect(url, "width=[0-9]{1,2}[^0-9]")
    })

  cli_alert_info("Found {length(paragraphs)} paragraphs, {length(headers)} headers, {length(image_urls)} images")

  # --- Build structured output ---
  content <- list(
    title      = post_row$title,
    link       = post_row$link,
    post_id    = post_row$post_id,
    pub_date   = post_row$pub_date,
    hook       = hook,
    headers    = headers,
    paragraphs = paragraphs,
    image_urls = image_urls,
    full_text  = paste(paragraphs, collapse = "\n\n"),
    # Word count for the LLM prompt — helps calibrate thread length
    word_count = sum(str_count(paragraphs, "\\S+"))
  )

  cli_alert_success("Extracted {content$word_count} words")
  content
}

# --- Hero image (og:image) ---------------------------------------------------
# Fetches the post page and extracts the cover image from the og:image meta tag.
# Substack always populates this from the cover image set in the editor UI.
# Returns the local path, or NA if unavailable.

fetch_hero_image <- function(post_url, post_dir) {
  tryCatch({
    page_html <- request(post_url) |>
      req_headers("User-Agent" = "Merrittocracy-Autopilot/1.0") |>
      req_timeout(30) |>
      req_perform() |>
      resp_body_string() |>
      read_html()

    og_url <- page_html |>
      html_element("meta[property='og:image']") |>
      html_attr("content")

    if (is.na(og_url) || og_url == "") {
      cli_alert_info("No og:image found on post page")
      return(NA_character_)
    }

    ext <- str_extract(og_url, "\\.(png|jpg|jpeg|webp)") |> coalesce(".jpg")
    local_path <- file.path(post_dir, glue("hero{ext}"))

    request(og_url) |>
      req_headers("User-Agent" = "Merrittocracy-Autopilot/1.0") |>
      req_timeout(30) |>
      req_perform(path = local_path)

    cli_alert_success("Hero image downloaded: {basename(local_path)}")
    local_path

  }, error = function(e) {
    cli_alert_warning("Failed to fetch hero image: {e$message}")
    NA_character_
  })
}

# --- Image downloading -------------------------------------------------------

download_post_images <- function(content, max_images = 4) {
  ensure_dirs()

  # Create post-specific image folder
  post_dir <- file.path(PATH_IMAGES, content$post_id)
  if (!dir.exists(post_dir)) dir.create(post_dir, recursive = TRUE)

  # Hero image first — from og:image on the post page
  hero_path <- fetch_hero_image(content$link, post_dir)

  if (length(content$image_urls) == 0 && is.na(hero_path)) {
    cli_alert_info("No images to download")
    return(character(0))
  }

  # In-body images (up to max_images; hero already occupies slot 1)
  urls <- head(content$image_urls, max_images)
  body_paths <- character(0)

  if (length(urls) > 0) {
    cli_alert_info("Downloading {length(urls)} in-body image(s)")

    body_paths <- map_chr(seq_along(urls), \(i) {
      url <- urls[i]
      ext <- str_extract(url, "\\.(png|jpg|jpeg|gif|webp)") |> coalesce(".png")
      filename <- glue("image_{str_pad(i, 2, pad = '0')}{ext}")
      local_path <- file.path(post_dir, filename)

      tryCatch({
        request(url) |>
          req_headers("User-Agent" = "Merrittocracy-Autopilot/1.0") |>
          req_timeout(30) |>
          req_perform(path = local_path)
        cli_alert_success("  Downloaded: {filename}")
        local_path
      }, error = function(e) {
        cli_alert_warning("  Failed to download image {i}: {e$message}")
        NA_character_
      })
    }) |>
      discard(is.na)
  }

  # Hero goes first so tweet 1 gets the cover image
  discard(c(hero_path, body_paths), is.na)
}

# --- Content summary for thread drafting -------------------------------------
# Produces a condensed version of the post suitable for the LLM prompt
# without sending the entire 2,000-word post

summarize_for_thread <- function(content) {
  list(
    title      = content$title,
    link       = content$link,
    hook       = content$hook,
    headers    = content$headers,
    word_count = content$word_count,
    # First sentence of each paragraph — gives the LLM the argument skeleton
    skeleton   = map_chr(content$paragraphs, \(p) {
      sentences <- str_split(p, "(?<=[.!?])\\s+")[[1]]
      sentences[1]
    }) |>
      paste(collapse = " | "),
    # Extract any percentages or number ranges — the data points
    data_points = str_extract_all(
      content$full_text,
      "[0-9]+\\.?[0-9]*\\s*[–-]\\s*[0-9]+\\.?[0-9]*%|[0-9]+\\.?[0-9]*%"
    )[[1]] |>
      unique()
  )
}
