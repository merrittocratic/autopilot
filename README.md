# Merrittocracy Autopilot

Distribution automation for the Merrittocracy sports analytics brand. Takes a published Substack post and produces a reviewed, approved X thread — with a single human approval step in between.

## What This Does

```
Substack RSS → detect new post → extract content → Claude drafts thread
    → Google Sheet review queue → you approve → posts to X as reply chain
```

The automation handles the mechanical parts of distribution. The human handles voice and judgment.

## Architecture

| Script | Job |
|--------|-----|
| `00_config.R` | Constants, packages, paths, API key management |
| `01_feed_check.R` | Polls Substack RSS, detects new posts, manages feed state |
| `02_extract_content.R` | Extracts title, hook, images, data points from post HTML |
| `03_draft_thread.R` | Calls Claude API with Merrittocracy voice prompt, returns structured thread |
| `04_queue_write.R` | Writes draft thread to Google Sheet for review |
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

The check job runs every 15 minutes. The post job runs every 5 minutes but only does anything when approved items exist in the queue.

## Workflow

1. Publish a Substack post as normal
2. Within 15 minutes, the pipeline detects it, extracts content, and drafts a thread via Claude
3. Open the Google Sheet on your phone — review the draft, edit tweet text if needed, change status from "pending" to "approved"
4. Within 5 minutes, the pipeline picks up the approved thread and posts it to X as a reply chain
5. The sheet updates with tweet IDs and timestamps

Total human effort per post: ~30 seconds of review on your phone.

## Manual Override

You can always skip the automation and post manually. The pipeline only processes posts it hasn't seen before (tracked in `data/feed_state.json`), and it only posts threads marked "approved" in the sheet. If you want to draft a thread manually, just mark the automated draft as "rejected" in the notes column and write your own.

## Repo Structure

```
autopilot/
├── R/
│   ├── 00_config.R
│   ├── 01_feed_check.R
│   ├── 02_extract_content.R
│   ├── 03_draft_thread.R
│   ├── 04_queue_write.R
│   ├── 05_post_to_x.R
│   └── 06_log_run.R
├── prompts/
│   └── thread_draft_system.md
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
