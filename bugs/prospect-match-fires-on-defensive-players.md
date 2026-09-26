# Bug: Prospect match fires on defensive players, producing nonsensical drafts

**Filed:** 2026-09-26  
**Filed by:** Earnest  
**Severity:** Medium — bad drafts surfaced to Steve for approval, all skipped  
**Affected component:** x-monitor prospect match gate → draft generation

---

## What happened

David Bailey (DE, rookie pass rusher) triggered `prospect_match=true` three times in one week. All three drafts were skipped as bad. The drafts applied boom/bust fantasy framing — offensive skill position metrics — to a defensive lineman, which is meaningless.

| message_id | tweet | draft excerpt | verdict |
|---|---|---|---|
| #13726 | PFF: Most pressures among rookies through 2 weeks | "8 pressures in 2 weeks is legit rookie EDGE production. Baseline makes sense, but the burst is already showing up..." | skip |
| #13797 | PFF: Highest-graded rookies | "David Bailey's 9.5% boom rate and 23.6% bust rate scream baseline, not breakout." | skip |
| #13835 | PFF: Only rookies with 2+ sacks in first 2 weeks (last 5 years) | "9.5% boom and 23.6% bust is exactly what Baseline looks like. The flashes are real, but the weekly floor is still the issue." | skip |

## Root cause

The feature store (`data/feature-store/nfl_features.csv`) is **offense only**:

```
Positions: WR (148), RB (97), TE (82), QB (42)
Metrics: season_target_share, season_air_yards_share, rolling_epa_per_opp, epa_per_opp_pctile
```

There are no defensive players, no sacks, no pressures, no PFF grades, no DL/LB/DB metrics of any kind.

The prospect match gate fires on name/player_id regardless of position. When Bailey matches, the pipeline pulls his feature-store row — which contains boom/bust fantasy fields that are entirely inapplicable to a pass rusher — and hands them to the LLM. The LLM then applies offensive framing to a defensive player.

## Suggested fix

**Quick fix (one filter, low risk):** Gate `prospect_match=true` to skill positions only — QB, RB, WR, TE. If the matched player's position is DL, LB, DB, OL, or anything outside the skill set, set `prospect_match=false` and let the draft proceed without model data injection.

**Longer term:** If we ever add defensive features (PFF grades, pressure rates, sack rates), the gate can be relaxed for positions that have real data behind them.

## Notes

- No defensive metrics exist anywhere in the current feature store. Any defensive player match is guaranteed to produce bad output until that changes.
- Bailey specifically has been flagged as a monitoring target (`keywords` list in x-monitor.R includes "jaxson dart" and "cam skattebo" — Bailey may have been added implicitly through a Giants/NYG keyword). Worth checking whether he has an explicit entry or is matching via team/news keywords.
