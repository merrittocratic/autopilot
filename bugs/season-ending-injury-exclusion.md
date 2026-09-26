# Bug: Season-ending injured players appear on boards as movers

**Filed:** 2026-09-26  
**Filed by:** Earnest  
**Severity:** Medium — misleading output, not a data corruption issue  
**Affected component:** news_overrides pipeline → scored_slate → boards.md movers

---

## What happened

Jaxson Dart is out for the season (MCL surgery, confirmed 2026-09-23). He appeared in the W03 rescore as the largest mover down on the boards: **QB -29 (13% vs 43%)**. A player with a season-ending injury shouldn't appear at all.

## Root cause

The news_overrides schema only supports two flag types: `role_change_down` and `role_change_up`. There is no `exclude`, `out_for_season`, or `out` type that removes a player from the slate entirely.

What actually happened in the W03 overrides:

| gsis_id | player | flag_type | reason | published_utc |
|---|---|---|---|---|
| 00-0040691 | Jaxson Dart | `role_change_down` | "Dart sidelined with sprained MCL, Winston taking over" | 2026-09-22 |
| 00-0031503 | Jameis Winston | `role_change_up` | "Dart's season-ending surgery creates clear QB1 opportunity" | 2026-09-23 |

The Sept 22 MCL news fired a `role_change_down` for Dart. The Sept 23 season-ending surgery news was captured — but only as a benefit to Winston. Dart's own record was never updated to reflect the surgery. Result: p(start) pushed from 43% → 13% instead of 0%, and he scores and surfaces as a mover.

## Relevant files

- `data/news_overrides_2026_w03.csv` — Dart has one entry (role_change_down, 0.95)
- `output/latest/scored_slate.csv` — Dart row: `role_change_down`, p_start=0.133
- `output/latest/start_board.csv` — Dart at QB rank 32

## Suggested fix

Add an `exclude` flag type (or `out_for_season`) to the news_overrides schema. When a player has this flag:
1. Set p(start) = 0 and p(boom) = 0
2. Drop the player from `start_board.csv` and `boom_board.csv`
3. Suppress from boards.md movers entirely

The LLM news ingestion should be prompted to distinguish season-ending injuries from week-to-week status changes and emit `exclude` accordingly.

**Short-term workaround:** Earnest can manually remove affected players from the ECR file before each rescore. Not scalable, but stops bad data from surfacing while the fix is in progress.
