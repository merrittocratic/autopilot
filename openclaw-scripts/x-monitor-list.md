# X Monitoring List — Curated Follows

## Tier conventions

Each handle may carry an optional tier annotation:
- `[tier:1A]` — Strategic relationship targets (Cowherd, Lowe, Brugler, TheHerd).
  Lower keyword bar, surface anything substantive.
- `[tier:1B]` — High-audience opinion accounts. Surface on 1+ keyword
  match OR engagement velocity above baseline.
- `[tier:1C]` — Breaking news. Surface only with a strong analytical hook
  (player/team in model data, or concept Steve has published on).
- No annotation = tier 2 (current behavior: surface on 2+ keyword matches).

The parser in `x-monitor.R` extracts both the @handle and the tier from
each line. Edit this file to promote/demote accounts.

## Sports Talk / Cross-Sport

- @ColinCowherd [tier:1A] — The Herd, FS1. Strategic stretch-goal target.
- @TheHerd [tier:1A] — show account amplifying Cowherd's takes
- @BillSimmons [tier:2] — The Ringer founder, podcast-pipeline adjacent

## NFL (Draft-First, Analytics-Weighted)

### Breaking news / transactions
- @RapSheet [tier:2] — Ian Rapoport, NFL Network
- @TomPelissero — NFL Network
- @AdamSchefter [tier:1C] — ESPN
- @Dane_Brugler [tier:1A] — The Athletic, best draft reporter

### Draft analysis
- @DanielJeremiah [tier:1B] — NFL Network
- @Jordan_Reid — ESPN draft
- @McShayESPN — ESPN draft
- @bfd_nfl — Ben Fennell, film-heavy, underrated

### Analytics / modeling
- @PFF [tier:1B] — Pro Football Focus
- @PFF_College — college pipeline
- @NextGenStats — NFL official analytics
- @OverTheCap — contract analytics, roster construction

### Contrarian / narrative-checking
- @FO_ScottKacsmar — Football Outsiders, stats-grounded
- @baldylocks — Ben Baldwin, analytics-heavy
- @SharpFootball [tier:1B] — Warren Sharp, data-driven, contrarian

### Sports media
- @TheRingerNFL [tier:1B] — Ringer NFL coverage

## Golf

### Institutional / tour
- @PGATOUR
- @EuropeanTour

### Journalists / reporters
- @Alan_Shipnuck — investigative golf journalist
- @BobHarig — ESPN Golf
- @DougFergusonAP — AP wire
- @JasonSobelTAN — The Action Network, betting-aware

### Longer-form / analytical
- @NoLayingUp [tier:1B] — best independent golf media
- @sean_zak — Golf Digest
- @bushtopher — Christopher Powers, Golf Digest
- @ShaneRyanGolf — freelance, literary and data-curious

### Analytics-adjacent
- @datagolf — DataGolf, strokes gained analytics

## NBA (Playoff-Ready)

### Breaking news
- @wojespn [tier:1C] — Adrian Wojnarowski, ESPN
- @ShamsCharania [tier:1C] — The Athletic
- @ChrisBHaynes — TNT/Bleacher Report

### Beat / analysis
- @ZachLowe_NBA [tier:1A] — ESPN, best analytical narrative writer
- @TimBontemps — ESPN
- @TheSteinLine — Marc Stein, independent

### Draft / prospect
- @Jonathan_Givony — ESPN NBA draft
- @Mike_Schmitz — ESPN, draft film

### Analytics
- @bencfredrickson — Ben Frederickson
- @cleaning_glass — Ben Taylor, efficiency metrics
- @KirkGoldsberry — spatial analytics, visualization
- @Seth_Partnow — former Bucks analytics director

### Sports media
- @TheRinger [tier:1B] — Ringer flagship account

## Polling Notes
- NFL draft news clusters around combine, pro day windows, and draft week — high frequency during those periods
- NBA is more continuous during playoffs
- Tier-1A/1C accounts are polled on a faster cadence (see x-monitor cron schedule)

## Rules
- API replies capped at 3/day (engaged accounts only — see x-engaged-accounts.md)
- Total surfaced candidates soft-capped at 8/day across all tiers
- No race, no politics (SKIP_KEYWORDS enforced in x-monitor.R)
- Drafts do NOT attach Substack links; the take stands alone
- All replies through Telegram for Steve's approval before posting
