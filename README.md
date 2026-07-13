# Merrittocracy Autopilot

Distribution automation for the Merrittocracy sports analytics brand. Takes a published Substack post and produces reviewed, approval-gated social drafts — with Telegram as the day-to-day action layer and Google Sheets as the audit log.

## What This Does

```
Substack RSS → detect new post → extract content → Claude drafts thread
    → Google Sheet audit log → Telegram approval/edit → posts to X as reply chain
```

The automation handles the mechanical parts of distribution. The human handles voice and judgment.

## Architecture

| Script | Job |
|--------|-----|
| `00_config.R` | Constants, packages, paths, API key management |
| `01_feed_check.R` | Polls Substack RSS, detects new posts, manages feed state |
| `02_extract_content.R` | Extracts title, hook, images, data points from post HTML |
| `03_draft_thread.R` | Calls Claude API with Merrittocracy voice prompt, returns structured thread |
| `04_queue_write.R` | Writes draft thread to Google Sheet audit log / fallback queue |
| `05_post_to_x.R` | Posts approved threads to X as reply chains via API v2 |
| `06_log_run.R` | Pipeline diagnostics, log reading, history export |
| `run_distribution.R` | Main entry point with `--check`, `--post`, `--status`, `--backfill` modes |

The voice prompt lives in `prompts/thread_draft_system.md` — version-controlled separately so voice iteration doesn't require code changes.

## Setup

### 1. Install R packages

```r
install.packages(c(
  "tidyverse", "httr2", "rvest", "xml2", "jsonlite",
  "googlesheets4", "cli", "glue", "here", "base64enc"
))
```

### 2. Configure environment

```bash
cp .env.example .env
# Edit .env with your API keys
```

You need:
- **Anthropic API key** — for thread drafting
- **X Developer account** — apply at [developer.twitter.com](https://developer.twitter.com), create a project with Read+Write permissions for @Merrittocratic
- **Google account** — for the review queue sheet (uses OAuth, no API key needed)

### 3. Create the review queue

```r
source("R/04_queue_write.R")
setup_review_sheet()
# Copy the printed sheet ID into your .env file
```

### 4. Backfill existing posts

If you already have published Substack posts, mark them as processed so the pipeline doesn't try to generate threads for old content:

```r
Rscript run_distribution.R --backfill
```

### 5. Test the pipeline

```r
# Check pipeline status
Rscript run_distribution.R --status

# Manually trigger a feed check (will process any new posts)
Rscript run_distribution.R --check
```

### 6. Schedule on Mac Mini (when it arrives)

Copy the launchd plists and update the paths:

```bash
# Edit paths in both plist files first!
cp launchd/com.merrittocratic.autopilot.check.plist ~/Library/LaunchAgents/
cp launchd/com.merrittocratic.autopilot.post.plist ~/Library/LaunchAgents/

# Load the scheduled jobs
launchctl load ~/Library/LaunchAgents/com.merrittocratic.autopilot.check.plist
launchctl load ~/Library/LaunchAgents/com.merrittocratic.autopilot.post.plist

# Verify they're running
launchctl list | grep merrittocratic
```

The check job runs every 15 minutes. The post job runs every 5 minutes as a fallback path when approved items exist in the queue.

## Workflow

1. Publish a Substack post as normal
2. Within 15 minutes, the pipeline detects it, extracts content, and drafts a thread via Claude
3. Telegram sends the full thread inline with a `post thread <post_id> ...` / `skip thread <post_id>` / `edit thread <post_id> ...` action pattern
4. Earnest logs your decision to the Sheet and posts immediately when you approve
5. The sheet updates with tweet IDs and timestamps

Total human effort per post: ~30 seconds of review on your phone.

## LinkedIn Channel (via Zernio)

Each new Substack post also gets a LinkedIn draft: a single ~200-300 word
post for the professional audience (voice prompt:
`prompts/linkedin_post_system.md`), with the article link and the X profile
link in the post body. Body links trade some algorithmic reach for
click-through simplicity — that's a deliberate Merrittocracy call, not an
oversight. Drafts land in the `linkedin` tab of the same review sheet for
logging, but Telegram is the approval surface; approve/reject/edit there and
Earnest logs the result before publishing to the personal LinkedIn profile
through the [Zernio](https://zernio.com) API, which holds the LinkedIn OAuth
connection.

One-time setup:

1. Create a Zernio account (free tier: 2 connected accounts, full API access)
2. In the Zernio dashboard, connect the LinkedIn account (choose **personal
   profile**, not organization, during the OAuth step)
3. Settings -> API Keys -> create a key (`sk_...`) and put it in `.env` as
   `ZERNIO_API_KEY`
4. Copy the connected LinkedIn account's ID into `.env` as
   `ZERNIO_LINKEDIN_ACCOUNT_ID`

Operational note: Zernio cannot renew a dead LinkedIn token headlessly. If
the connection expires, the pipeline detects it (health check before every
posting run), holds approved posts, and pings Telegram — reconnect in the
Zernio dashboard and the next run resumes. Expect this occasionally
(LinkedIn tokens are short-lived by policy).

## Manual Override

You can always skip the automation and post manually. The pipeline only processes posts it hasn't seen before (tracked in `data/feed_state.json`), and it only posts threads/posts after an explicit approval action. If you want to draft manually, reject the automated draft in Telegram and write your own; the Sheet remains the log of what happened.

## Repo Structure

```
autopilot/
├── R/
│   ├── 00_config.R
│   ├── 01_feed_check.R
│   ├── 02_extract_content.R
│   ├── 03_draft_thread.R
│   ├── 03b_draft_linkedin.R
│   ├── 04_queue_write.R
│   ├── 04b_queue_linkedin.R
│   ├── 05_post_to_x.R
│   ├── 05b_post_to_linkedin.R
│   └── 06_log_run.R
├── prompts/
│   ├── thread_draft_system.md
│   └── linkedin_post_system.md
├── launchd/
│   ├── com.merrittocratic.autopilot.check.plist
│   └── com.merrittocratic.autopilot.post.plist
├── data/                    # git-ignored, machine-specific state
├── staging/                 # git-ignored, temp images and drafts
├── logs/                    # git-ignored, run logs
├── .env.example
├── .gitignore
├── README.md
└── run_distribution.R
```

---

*Part of the [Merrittocracy](https://themerrittocracy.substack.com) project. Code and methodology are public.*
