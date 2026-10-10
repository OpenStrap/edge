# 02 · Chart and graph audit (OpenStrap Edge, lib/ui2)

Code: `edge-main-check` worktree at `2b1c8510` (main, PR #569 merged). Read-only.
Renders: 33 gallery cases shot light + dark at 390 pt width with a throwaway test in
`/tmp/uxshots/shots_test.dart` (outputs `/tmp/uxshots/out/*.png`, contact sheets
`/tmp/uxshots/s1..s7.png`). Gallery fixtures are synthetic sine waves, so the renders
show chrome, colour, type and layout, not real data shapes. Lucide icons render as
empty squares in the harness (font not loaded); that is a harness artefact, not a bug.
Full screens (Home, Sleep, Health) were not rendered because they need live AppState;
their charts were audited from code.

Severity: **S1** = a typical user cannot read it or reads it wrong; **S2** = slows
reading or erodes trust; **S3** = polish.

## 0. Verdict up front

The chart layer is engineered for honesty, and it shows: gaps break lines, absence has
its own mark, axes are shared between painter and labels (`AxisSpec`), 1 Hz series are
min/max-decimated, every frame has a spoken summary. Almost none of the problems below
are correctness bugs.

The problem is the other half of the job. The charts answer "what was measured?" and
rarely answer "is this good, and what changed?". Specifically:

- Only one chart in the app draws the user's normal range (`driver_breakdown.dart:494`
  `_Band`). Every other trend, including the main metric-detail chart and the Health
  tab trend cards, states the range in a footnote or not at all.
- Most y axes auto-fit the data (`AxisSpec.of(vals)` with no floor or personal range),
  so a 3 bpm week fills the card top to bottom. The code bans the filled area for that
  reason (`charts.dart:388`), but the stroke alone still reads as a dramatic swing.
- Two charts out of roughly 45 take a touch (`Scrubber` in `metric_detail.dart:1348`
  and `sleep_detail.dart:968`). Everywhere else you can look but cannot read a value.
- Titles and units are written for the developer: `RMSSD, 22 of the last 30 nights`,
  `TRIMP`, `Banister training impulse`, `Deceleration capacity`, `ms² per Hz`,
  `Bin RMSSD`, `rel`, `shape only`, `SD1/SD2`.
- Footnotes are long and defensive (the `investigate` shape footnote is 70 words).
  They are the most-read text under the chart, and they mostly say what the chart
  cannot tell you.

## 1. Inventory

Shared painters, all in `lib/ui2/charts.dart` unless noted. Frame and cards in
`lib/ui2/grammar.dart`.

| Painter / widget | Def | Used at (file:line) |
|---|---|---|
| `ChartFrame` (title, unit, y ticks, x labels, legend, footnote) | grammar.dart:2063 | every framed chart below |
| `LineChart` | charts.dart:383 | health_screen:1306, metric_detail:1365/1382/1391, readiness_detail:348, driver_breakdown:502, day_timeline:940, investigate:649/654/659/718, beats:526, circadian:528, cycle:1107/1433, journal_compose:968, day_strain:290, summary:1690/2214, live_hr:169, TrendCard grammar:632, coach_figures:193 |
| `Bars` | :505 | metric_detail:1466 (wear), workout:269/365, circadian:481, day_steps:374+383, nutrition:457, cycle:1331, coach_figures:245 |
| `Ring` / `DashedRing` | :588 / :648 | home_screen:1056-1058 (3 dials), :2082 (steps mini), readiness_detail:227, metric_detail:1870, live:1768, devices (battery) |
| `MacroRing` | :692 | gallery only (`chart_macro_ring`) |
| `Hypnogram` | :744 | sleep_detail:1003, coach_figures:365 |
| `ZoneBar` | :858 | workout:1075, day_strain:351, zones:572, live:851, summary:1708, coach:406 |
| `Actogram` | :922 | circadian_detail:362 |
| `HeatMap` | :958 | month_grid:200, investigate:763, coach:544 (beats:593 uses its own `_RhythmStrip`, beats:449 its own `_NightBand`) |
| `Spectrum` | :1006 | gallery only (no screen uses it) |
| `Poincare` | :1060 | beats:357 |
| `NightStack` | :1141 | sleep_detail:1636, coach:294 |
| `DayLanes` | :1204 | day_timeline:921 |
| `RouteMap`, `Elevation`, `LapBars`, `IntervalLadder`, `BreathRing` | paint_activity.dart:51/113/190/272/233 | summary:1318/1502/1469/1388, live:1132/2042/2193, calm_breathing:1038 |
| `EcgLivePainter`, `EcgWaveformPainter` | ecg_widgets.dart:356/417 | ecg:951 |
| `Consistency` (segment strip) | grammar.dart:1596 | health:1119/1339, nutrition:337, wellness:626/820 |
| `ProgressCard`, `GoalTrajectory` | grammar.dart:400/1443 | nutrition:680 and others |
| `MetricRow` (direction glyph, no sparkline) | grammar.dart:1187 | health, wellness, nutrition, cycle, day_steps |

Same metric drawn more than one way:

| Metric | Renderings |
|---|---|
| HRV | TrendCard sparkline, no axis (health:1042); DeepDive 48 pt line, 2 ticks, titled "RMSSD" (health:1287); metric-detail 150 pt line, no band (metric_detail:1306); driver 110 pt line **with** band (driver_breakdown:470); NightStack lane, no ticks (sleep:1636); investigate "Shape of the night" grey min/max lines (investigate:628); beats half-hour bins (beats:430) |
| Resting HR | TrendCard (no axis), metric-detail (no band), driver (band), cycle-phase line (cycle:1408), home `SignalCard` number only |
| Readiness | Home ring (score/100, band colour); readiness_detail ring (same) + 0–100 line always green, no zones (readiness_detail:348) |
| Load | Home "Strain 14.2 of 21" ring; day_strain line "0–21" header over an auto axis; workout "DAILY LOAD · TRIMP" bars; workout "fitness" CTL number with "form" pill |
| Time in zones | ZoneBar at 8 pt (workout:1069), 10 pt (day_strain, zones, live, summary); legend "Z1 · 12m" in one place, "Zone 1" (hard-coded English) in others |

## 2. Per-chart findings, part A: the surfaces most users see

**A1. Home dials: Recovery / Strain / Sleep** · `home_screen.dart:1048` (`_Dial`), painters `Ring`/`DashedRing`. Render: `s4.png` rings, rings_calibrating.
- Type: three 360° progress rings, number and word under each. Recovery fill = score/100 coloured by band (`readinessBand`, :743: green for both "Good to go" and "Steady", orange "Take it easy", red "Rest today"). Strain fill = strain/21. Sleep fill = asleep/need.
- 3-second test: passes for Recovery (number, word, colour agree). Strain "14.2 of 21" fails: 21 is a ceiling nobody reaches, and the ring cannot say whether 14.2 is a lot *for you today*. Sleep reads "7h 45m of 7h 42m", fine.
- S2: Ring colour is the domain colour for Strain and Sleep but the *judgement* colour for Recovery. Same shape, two colour grammars side by side.
- S2: Two different bands ("Good to go", "Steady") share green, so the colour carries one bit fewer than the word.
- S3: Calibrating state (dashed ring, one dash per night needed) is a nice touch and reads correctly in the render.
- Compare: WHOOP uses the same three dials but colours *all* of them by meaning (recovery red/yellow/green; strain shows a target band on the ring). Oura shows one score per ring and a single word ("Optimal / Good / Fair / Pay attention").

**A2. Health tab TrendCards (Resting HR, HRV)** · `health_screen.dart:1042`, widget `TrendCard` grammar.dart:498, painter `LineChart` with no axis at grammar.dart:632. Render: `s3.png` trend*.
- Type: big number, delta with arrow, 64 pt sparkline of the last 30 days, auto-scaled with 14% padding.
- S1: The card says "vs your 14-day average" / "vs 14-day baseline" but the sparkline draws no baseline. A 2 bpm wobble fills the 64 pt box exactly like a 20 bpm swing. Users see a seismograph and cannot tell whether it is calm.
- S2: Value truncation risk. The gallery `trend` case renders "7h 4…" at full phone width (358 pt card) in both themes, because the value is the only `Flexible` child and the unit + delta keep their width. The in-app sleep card (health_screen:1067) passes an empty unit, so it probably fits at 1×, but the layout gives the headline number the lowest priority in the row; long locales or a long delta will cut it first.
- S2: The line is coloured by metric hue (RHR red) while the delta is coloured by judgement (green/orange). A red line next to a green "improvement" arrow reads as contradiction.
- S2: No x-axis cue. "30 days" lives only in code; the card's small print says the comparison window (14 days), not the drawn window.
- Compare: Garmin "HRV Status" draws the personal baseline as a shaded band behind the line; Apple Vitals shows a typical range per metric; Oura's trend views show your average as the reference.

**A3. Metric detail main chart** · `metric_detail.dart:1306` (`ChartFrame` height 150, `Scrubber`, `LineChart`). Windows 1/7/30/182/365 days (`_windows` :683).
- Type: line with dots (≤40 points), 3 y ticks auto-fit to data, 2 x labels ("29 days ago", "Today"), dotted algorithm-version marks, scrub with readout below (`_picked` :1551).
- S1: No normal-range band, though this screen is the canonical home of each metric and the app already computes baseline + spread (`driver_breakdown` draws it). Without it the user cannot answer "is today normal?" from the chart.
- S2: Auto-fit axis. `AxisSpec.of(vals)` with `floor` only for `%`. A 55→58 bpm month gets ticks 54/56/58 and fills the card. Honest numbers, misleading picture.
- S2: x labels are only the two ends. For 182/365-day windows the user has no month anchors.
- S2: Device-filter dimming draws a grey full series under a coloured partial series. Two lines, one meaning; needs the caption to decode.
- S3: Dotted version-break marks plus a 30-word footnote. Correct, but most people will read the mark as "something happened to me here".
- Good: the only trend chart with scrub, a screen-reader slider and a readout.

**A4. Wear bars under metric detail** · `metric_detail.dart:1454`, `Bars` 56 pt, "Worn · h a day", axis 0–24.
- S3: Fine as a provenance strip. Grey ink (`p.ink3`) keeps it secondary. Footnote is long (wear count + "the line above is not carried across one").

**A5. Readiness detail: ring + history** · `readiness_detail.dart:225` (150 pt ring) and :332 (`LineChart` 120 pt, fixed 0–100 axis).
- S1: The history line is always green (`p.on(C.green)`) even across days that were "Rest today". The ring two cards up is red on those days. Same score, two colours, one screen.
- S2: No zone bands on the 0–100 axis, so the green/orange/red thresholds the ring uses (and recently re-cut, see :713-729 comments) are invisible on the trend.
- S2: No tap/scrub, so a past day's score cannot be read.
- Good: fixed 0–100 axis, so days are comparable.
- Compare: WHOOP's recovery trend colours each bar/point by its own band; Oura's readiness trend uses coloured bars with the score on tap.

**A6. Driver breakdown** · `driver_breakdown.dart:470` (`_chart`, 110 pt line with `_Band`). Render: `s7.png` driver_breakdown.
- Best chart in the app for a non-expert: line, dots, a shaded "usual range" band, footnote with the range in words.
- S2: The surrounding rows are jargon-heavy: "47% weight · bigger than measurement noise", "relative, uncalibrated", "+3.1 / −6.2" with no unit or scale. The numbers are contribution points; nothing says so.
- S3: Band colour is `p.wash(metric colour)`; on light theme it is faint enough to miss at a glance.

**A7. HRV deep-dive preview** · `health_screen.dart:1287` (`_hrvPreview`, 48 pt line, 2 ticks).
- S1 (jargon): title "RMSSD, 22 of the last 30 nights", inside a card titled "Heart rate variability" with subtitle "Time, frequency and non-linear". Three names for one thing on one card.
- S2: 48 pt tall with two tick labels is a sparkline wearing an axis. It sits right below the HRV TrendCard, which already draws the same 30 nights. Same data twice, two scales, one scroll.

**A8. Sleep: hypnogram** · `sleep_detail.dart:865` (`ChartFrame` 132 pt) + `_hypnogram` :964 (`Scrubber` over `Hypnogram` runs). Render: `s2.png` chart_hypnogram.
- Type: four lanes (Awake, REM, Light, Deep top to bottom), colour per stage, risers between runs, 3 clock labels, legend below, scrub.
- S1: No lane labels on the y side. The reader must match lane position → colour → legend row under the chart. WHOOP, Oura, Apple and Garmin all print the stage names at the left of each lane.
- S2: Light theme colours turn muddy after contrast solving (`P.on`): Awake renders brown, Light renders slate grey-blue (render s2, left column). In dark theme they are orange and sky. A user switching theme sees a different chart; and the four hues are unordered (orange, teal, sky, blue), where most sleep apps use an ordered ramp so deeper sleep simply reads darker.
- S2: Stage names are hard-coded English (`SleepStageX.label`, charts.dart:736), and the legend filter in sleep_detail:878 matches on that English string. Non-English users get an English key.
- S2: Unit chip says "stage". Meaningless next to a hypnogram; drop it or show total time per stage there.
- S3: The instruction "Tap or drag the chart for any moment" lives in a caption below; the scrub cursor has no tooltip bubble on the chart itself, so the readout is out of the eye line.
- Good: awake-wins column precedence, runs instead of picket fences, gaps left blank.

**A9. Sleep: overnight signals stack** · `sleep_detail.dart:1622` (`NightStack`, 44 pt per lane). Render: `s2.png` chart_night_stack.
- Type: up to four stacked lines (HR, HRV, breathing, skin temp) on a shared night clock.
- S1: Each lane gets its own `AxisSpec` (sleep_detail:1585) but the frame is given no `yAxis`, so **no lane prints a single number**. Every lane is auto-fit to its own min/max, so a flat 52–55 bpm night and a 48–80 bpm night draw the same height of wiggle.
- S1: Lanes are identified only by legend colour at the bottom ("Heart rate (bpm)", "Skin temp (rel)"). In light theme red (HR) and solved orange (temp, renders brown) are close; in the render they are hard to tell apart without reading the order.
- S2: Same title as the hypnogram card two sections up: "Through the night". Unit chip is a concatenation: "bpm · ms · br/min · rel".
- S2: No scrub, and it does not follow the hypnogram's scrub, though both share the onset→wake clock. "Why was I awake at 3:10?" is the question this stack exists to answer.
- Compare: Oura's sleep page shows lowest HR and HRV as separate full-width cards with a labelled curve and the night average; Garmin's sleep HR uses one chart with a labelled axis.

**A10. Day timeline heart rate** · `day_timeline.dart:880` (`dayGraphCard`, 200 pt, `DayLanes` + `LineChart`).
- Type: 24 h HR line over shaded sleep bands, workout blocks on top edge, a 16 pt movement strip at the bottom, grey ground for unrecorded stretches. Legend of up to four keys.
- S2: Four encodings in one 200 pt box (line, background tint, top blocks, bottom bars) plus a grey "Not recorded" ground. Dense but learnable; the legend swatch for "Not recorded" is `p.card2`, close to the card colour, so the key is near-invisible.
- S2: ~1440 points and no scrub. This is the chart where "what was my HR at 3 pm?" is most natural; it is not answerable.
- S3: Auto-fit HR axis; fine here because HR range across a day is wide.

**A11. Strain through the day** · `activity/day_strain.dart:276` (170 pt line).
- S1: Unit chip says "0–21" while the y axis is auto-fit (`AxisSpec.of(curve, floor: 0)`), e.g. 0–15. The header promises one scale and the ticks show another.
- S2: ALL-CAPS title ("STRAIN THROUGH THE DAY") while most cards use sentence case.
- Compare: WHOOP shows day strain as a single number with an optimal-strain target band, and the intraday curve is secondary.

## 3. Per-chart findings, part B: workouts, activity, deep dives

**B1. Time in zones (ZoneBar), six call sites** · charts.dart:858; workout_screen:1066 (8 pt), day_strain:334, zones:560, live:841, summary:1697 (10 pt). Render: `s2.png` chart_zones.
- Type: one stacked horizontal bar, bands step up in height toward zone 5 as a second channel.
- S1: At 8–10 pt tall the height-step channel is 5–6 pt vs 8–10 pt. Zone 4 and 5 measure 1.34:1 against each other (charts.dart:878 comment) and zone 5 is often a sliver. The colour carries the reading and fails for red/green colour-blind users (zones 3 green, 5 red).
- S2: Legend wording differs by screen: workout prints "Z1 · 12m"; the shared `ZoneBar.legend` prints "Zone 1" in hard-coded English. Neither says what a zone is (bpm range or % max HR); that is only in `zonesWhy` footnotes on some screens.
- Compare: WHOOP, Garmin and Apple Workout all use a five-row horizontal bar list: one row per zone, bpm range on the left, minutes on the right. Readable at any size, needs no legend.

**B2. Workout: Daily load (TRIMP) and Mechanical load bars** · workout_screen:342 and :247 (88 pt, 7 bars, weekday letters).
- S1 (jargon): "DAILY LOAD · TRIMP", footnote "Banister training impulse — minutes weighted by heart-rate reserve", headline "fitness" with a "form" pill (CTL/TSB). The home screen calls the same idea Strain (0–21). A user meets two load scales and three terms.
- S2: Auto axis with `floor: 0`; fine. No "typical day" line, so a tall bar is unanchored.
- S2: Mechanical load footnote says the number is "worthless across exercises". If it is, it should not be a chart.

**B3. Activity summary: route** · summary.dart:1291 (200 pt), live.dart:1115 (150 pt); `RouteMap` paint_activity.dart:51. Render: `s7.png` activity_route.
- S2: Pace coloured red (slow) → green (fast). The classic deuteranopia pair; the line also has no base map, so the shape floats on a blank card.
- S3: ALL-CAPS title "ROUTE".

**B4. Elevation** · summary.dart:1490, `Elevation` paint_activity:113. Render `s6.png`.
- Good: labelled axis (0/250/500 m), distance on x, filled area against a real zero. Reads well. S3: the high-point dot is unexplained.

**B5. Laps (swim)** · summary.dart:1449 (150 pt), live.dart:2029; `LapBars` paint_activity:190. Render `s6.png`.
- S1: Bars have no lap numbers and no times. Unit chip "seconds per lap" / "50 m, fastest first" but no bar carries a number, and "fastest first" means the order is not lap order, which is the first thing a swimmer assumes.
- Compare: Garmin and Apple list laps as rows with the time printed per lap; a bar is optional decoration.

**B6. Interval ladder** · summary.dart:1371, `IntervalLadder` paint_activity:272. Render `s6.png`.
- S2: Unit "share of the hardest round" with no y ticks. Work orange/brown, rest blue; readable shape, unreadable values.

**B7. Activity HR and other traces** · summary.dart:1680 and :2202.
- S3: x labels "Start" + duration; :2207 hard-codes English 'Start' and `toUpperCase()` titles. Otherwise a standard labelled line.

**B8. Live HR card** · live_hr.dart:169 (56 pt, raw `C.red`). Render `s6.png` live_hr_card.
- S2: Auto-scaled to the last 30 readings, so a 64–71 bpm wobble fills the box. Raw pigment rather than `p.on(C.red)` (every other chart is contrast-solved). Caption is hard-coded English.

**B9. Steps by hour** · day_steps.dart:353 (150 pt, two `Bars` stacked in a `Stack`).
- S2: Band and phone bars are *overlaid* on the same slots, not stacked or side by side. Where both counted, the teal phone bar paints over the green band bar and hides it. Green vs teal is also a weak pair.
- S3: ALL-CAPS title "WHEN THEY WERE COUNTED".

**B10. Circadian: actogram** · circadian_detail.dart:340 (190 pt, noon→noon rows). Render `s5.png` chart_actogram.
- S1: An actogram is a research plot. The y axis runs noon → midnight → noon, opacity encodes "share of that hour asleep". Most users will not decode it.
- S2: Legend swatch uses raw `C.indigo` (:356) while the painter uses `p.on(C.indigo)`. Key and mark can differ.
- Compare: WHOOP, Oura and Apple show sleep consistency as one floating bar per night (bedtime to wake) against a clock axis, sometimes with a shaded target window. Same data, readable.

**B11. Circadian: "When you are still" bars and "How today is likely to run"** · circadian:460 (unit "ms"), :508 (unit "shape only", no y axis).
- S1 (jargon): "Beat-to-beat variability while still", hourly bars in "ms" with a 55-word footnote ending "Not a stress score — sitting up, a warm room or a coffee move it just as much." The chart warns users off the only reading they would try. "shape only" as a unit, with footnote "No scale — the shape is the whole output." A chart that admits it has no scale should be a sentence ("You're usually most alert around 10:00 and 18:00").

**B12. Investigate: "Shape of the night"** · investigate.dart:628 (130 pt; three `LineChart`s: lo, hi grey, mid green).
- S1: Legend "Bin RMSSD" and "Sampling range"; footnote of ~70 words explaining that the grey pair is "the estimator's own sampling spread, not a range you were in". Two grey lines bracketing a green one will be read as a normal range by anyone who skips the footnote, which is everyone.
- S2: The uncertainty is drawn as two lines instead of a filled ribbon; a ribbon is the convention and halves the ink.

**B13. Investigate / Beats: deceleration capacity** · investigate.dart:695, beats.dart:510 ("Your own nights, in order", grey `p.ink2` line).
- S1 (jargon): "Deceleration capacity" is a cardiology research metric. No band, grey line, nothing says which direction is better.

**B14. Beats: Poincaré scatter** · beats.dart:341 (260 pt square). Painter charts.dart:1060.
- S1 for a consumer, fine for an expert. Footnote leans on "SD1" and "SD2". Y tick labels print on the left, but there are no x tick labels; the footnote has to say the left labels "read across the bottom too". The square is centred inside a wider frame, so the left tick gutter sits away from the plot's left edge.

**B15. Beats: RMSSD half-hour bins** · beats.dart:429 (`_NightBand`, 150 pt).
- S2: Title "RMSSD in half-hour bins"; footnote explains that the bar is confidence, "not a range your body passed through". Same confidence-vs-range confusion as B12, drawn a third way (bars with a mark instead of lines or a ribbon).

**B16. Rhythm screen strips** · investigate.dart:746 (`HeatMap`, unit "one square per day"), beats.dart:593 (`_RhythmStrip`).
- S2: Two different painters for the same "screened / fired / not screened" days. In beats the "Not screened" legend dot is a filled `p.line` swatch while the mark is an outlined square, and "Screen did not fire" (the good outcome) is drawn in grey, while "fired" is orange. Grey reads as "no data" in the rest of the app.
- Note for the owner: this is an irregular-rhythm screen. Any chart for it needs a plain-language header ("No irregular rhythm flagged on 27 of 28 days checked") before any grid.

**B17. Cycle screen** · cycle_screen.dart:1089 (per-phase median line, "Day 1 … Day N"), :1307 (days between starts, `Bars` + median rule), :1407 (RHR by cycle day).
- S3: Reasonable. Footnotes carry "Middle of N cycles at each day" and MDC (minimal detectable change) notes; "Descriptive only." is honest. MDC wording leaks statistics jargon.

**B18. Nutrition energy bars** · nutrition_screen.dart:426 (120 pt `Bars`, raw `C.domFood` not `p.on`); `MacroRing` charts.dart:692.
- S2: Bars use raw pigment (contrast not solved, unlike other bars). No goal line on the bars. `MacroRing` is gallery-only today (no screen calls it); its gallery case renders a ring with no number inside and "of 140 g" only in the header, so fix that before anything ships it.

**B19. Journal weight trend** · journal_compose.dart:952 (140 pt, 7 days, 2 x labels). S3: fine.

**B20. Month grid** · month_grid.dart:200 (`HeatMap`, one 22 pt row per metric, opacity = value "against your own range").
- S1: Darker means "higher", not "better". For resting HR higher is worse, for HRV higher is better; both rows use the same light→dark ramp in their own hue. A user scanning the grid will read dark as good everywhere. No legend.
- Compare: Oura's and WHOOP's calendars colour each day by the *judgement* (score band), not the raw value.

**B21. Consistency strip** · grammar.dart:1596 (N segments, first `have` filled).
- S2: "18 of 24 days" fills the first 18 segments left to right. It looks like a timeline but is a count, so the user cannot see *which* days are missing (the recent ones? one week?). Either draw real days or draw a single progress bar.

**B22. Coach figures** · coach_figures.dart:157-544. LLM-specified charts reuse the same painters. Render `s7.png` coach_fig_line shows a 2-week HRV line with a gap and a thin grid; inherits every issue of A3 (no band). S3.

**B23. ECG waveform** · ecg_widgets.dart:417. One-second grid lines and a midline only.
- S2: Not the clinical 25 mm/s, 10 mm/mV small/large grid users recognise from Apple/Withings/Kardia ECG PDFs. Fine for a preview; expect complaints if shared with a clinician.

**B24. Spectrum (LF/HF)** · charts.dart:1006. Gallery-only, no screen uses it. No x axis (frequency) and no y ticks. Keep it out of the product or delete it.

## 4. Cross-cutting problems

**X1. No "normal for you" on the picture (S1).** The app computes baseline and spread
per metric (driver_breakdown, `metricDetailPercentileTodayBand`, the "usual range"
footnotes) and draws it in exactly one chart (`_Band`, driver_breakdown.dart). The
gallery `chart_line` render is the clearest case: a footnote says "Your usual range is
52–64 bpm" under a line with no band. Every wearable users compare against draws this
band or an average line: Garmin HRV Status (shaded baseline band), Apple Vitals (typical
range per metric), WHOOP Health Monitor (each vital against your own range), Oura trends
(your average as a reference). Competitor descriptions here are from product knowledge,
not fresh screenshots.

**X2. Auto-fit y axes make calm look dramatic (S1).** `AxisSpec.of(data)` rounds to nice
ticks but still hugs the data. With no band and no anchor, a 3-unit week uses the full
height. Affected: metric_detail, TrendCard sparklines (no axis at all, 14% padding),
NightStack lanes, live HR, driver lines (mitigated by the band), journal weight.

**X3. Judgement colour is missing or inconsistent (S1).** Recovery is coloured by band on
the ring and plain green on its own history. TrendCard colours the line by metric hue
and the delta by judgement. Month grid shades by raw value. Users learn "green = good"
from the home ring and then find green lines on bad days.

**X4. Almost nothing is tappable (S1).** 2 of ~45 charts scrub (metric detail,
hypnogram). Day timeline HR (1440 points), readiness history, night stack, workout bars,
laps, steps, zone bars: look only. Mobile users expect press-and-hold to read a value;
on a 350 pt chart it is the only way to read one.

**X5. Developer vocabulary in titles, units and legends (S1).** RMSSD, TRIMP, Banister,
CTL "fitness", TSB "form", Deceleration capacity, SD1/SD2, Bin RMSSD, Sampling range,
ms² per Hz, "rel", "shape only", "share of the hardest round", "one square per day",
"screened / not screened", MDC. The honesty copy is right; it belongs one tap down,
not in the chart's header.

**X6. Footnotes do the chart's job (S2).** Many frames end with 30–70 words of caveats
(investigate:639, circadian:470, workout tonnage, metric_detail algo break). People do not
read them, and the ones who do learn mostly what the chart cannot tell them. A chart that
needs a paragraph to be read correctly should be redrawn or replaced by a sentence.

**X7. Same metric, many drawings (S2).** HRV appears in seven forms (table in §1), three
of which disagree on whether to show an axis and one of which shows a band. Load appears
as Strain 0–21, TRIMP, CTL "fitness" and kg lifted. Two different "screened days"
painters. Two cards on the sleep page share the title "Through the night".

**X8. Colour after contrast solving loses identity in light theme (S2).** `P.on` solves
every mark to the card for contrast, which is correct for WCAG non-text 3:1, but it pushes
orange to brown, sky to slate, blueSoft to grey (renders s2, s5, s6 left columns). Light
and dark themes look like different apps; red/brown and green/teal pairs collapse.
Five charts still use raw pigment (`live_hr`, nutrition bars, actogram legend, route
pace pair is red/green). Hard-coded English in chart chrome: `SleepStage.label`,
`ZoneBar.legend`, `Spectrum.legend`, summary.dart:2207 'Start', live_hr caption.

**X9. Tiny charts with axes, big charts without (S2).** 48 pt HRV preview has ticks;
8–10 pt zone bars carry a five-colour channel; 44 pt night lanes carry no ticks;
the 64 pt TrendCard sparkline has no axis but sits under a precise number.

**X10. Title case drift (S3).** ALL CAPS on activity/workout charts (`ROUTE`, `LAPS`,
`HEART RATE`, `TIME IN ZONES`, `DAILY LOAD`, `STRAIN THROUGH THE DAY`,
`WHEN THEY WERE COUNTED`, `g.$1.toUpperCase()`), sentence case elsewhere.

What is already right and should be kept: gaps break lines (rule 3), absence has its
own outline mark, `AxisSpec` shared between painter and ticks, min/max decimation,
spoken summaries on every `ChartFrame`, reduced-motion support, 2× text tested.

## 5. Redesign recommendation per chart

One shared building block first, because most fixes reuse it:

**`PersonalBand` overlay + `ReadingHeader`.** A band painter (reuse `_Band` from
driver_breakdown.dart) that every trend `ChartFrame` accepts as `band: (lo, hi)`, plus a
header row above the plot: big value, word judgement ("Normal for you" / "Below your
usual" / "Higher than usual"), arrow, and "vs 30-day usual". Axis rule: y range =
max(data range, band ± 1 band-width), so a calm week sits calmly inside the band.

| # | Chart | Replace with |
|---|---|---|
| A1 | Home dials | Keep three dials. Colour all three by meaning: Recovery by band (split "Steady" to its own hue, e.g. teal), Strain with a shaded "target for today" arc on the ring, Sleep by % of need (≥90 % green, 70–90 amber, <70 red). Word under every ring, not only Recovery. |
| A2 | Health TrendCards | Number + judgement word + arrow + **7-day** sparkline drawn over a grey personal band, endpoint dot coloured by judgement, line itself neutral ink. Value gets layout priority (unit and delta wrap under it). |
| A3 | Metric detail | Same header as A2. 150 pt line over the personal band, y range from the band rule, month labels for ≥182 d, press-and-hold tooltip *on* the chart (value, date, "in your range"). Move version marks behind an info button. Default window 30 d. |
| A4 | Wear strip | Keep. Shorten footnote to "Worn 24 of 30 days". |
| A5 | Readiness detail | Replace the green line with 30 bars coloured by band (WHOOP/Oura pattern), fixed 0–100, faint band thresholds at the cut points, tap a bar for that day's drivers. |
| A6 | Driver breakdown | Keep the chart. Replace "+3.1 / 47% weight / measurement noise" with a three-state chip per driver ("helping", "holding you back", "no effect") and the plain sentence already there ("3 bpm below your usual 57"). Weights go behind "How is this calculated?". |
| A7 | HRV preview | Delete. The TrendCard above it already shows 30 nights; the deep-dive card becomes a single row "Heart rate variability · deep dive ›". |
| A8 | Hypnogram | Stage names on the left of each lane; ordered colour ramp (deep darkest, awake lightest/warm); totals per stage on the right of each lane ("Deep 1h 12m"). Tooltip bubble on the cursor. Localise stage names. |
| A9 | Night stack | Split into small multiples, one per signal, each 64 pt with its own min/max ticks and night average printed at right ("HR 52 avg · low 47"). All share the hypnogram's scrub cursor. Rename card "Heart and breathing overnight". |
| A10 | Day timeline | Add press-and-hold readout. Drop the "Not recorded" grey from the legend and hatch unrecorded stretches instead. |
| A11 | Strain through the day | Fix axis to 0–21 to match the header, or drop the "0–21" chip. Lead with the day's strain number and a target band; make the curve secondary. |
| B1 | Zone bars | Five horizontal rows: "Zone 3 · 128–145 bpm ······ 22 min". Bar length = minutes. No legend needed. Same component on all six screens. |
| B2 | Workout load | Rename to "Training load" with one scale across the app (pick Strain or a 0–100 load). Bars per day with a dashed "your usual day" line. "Fitness/form" become a sentence ("You've trained more than usual this week"). Drop the mechanical-load chart or make it a number per exercise. |
| B3 | Route | Colour-blind-safe pace ramp (light → dark single hue, or blue→orange). Optional static map tile later. |
| B5 | Laps | A list: lap number, time, small bar. Lap order, fastest marked. |
| B6 | Interval ladder | Print work/rest seconds above each bar or switch to a list. |
| B8 | Live HR | Fixed axis around the current zone or print the current zone name; use `p.on`. Localise caption. |
| B9 | Steps by hour | Stack band + phone (or show the merged series with a single colour and the split in a tooltip). |
| B10 | Actogram | Replace with sleep-window bars: one vertical bar per night from bedtime to wake on a clock axis (18:00 → 12:00), a shaded "your usual window", and "Bedtime varied by ±42 min this week" as the headline. Keep the actogram behind "Advanced". |
| B11 | Stillness / forecast | Replace both with sentences plus at most a single labelled curve: "You're usually most alert 09:00–12:00". |
| B12–B15 | HRV research charts | Move Shape-of-night, DC, Poincaré, half-hour RMSSD behind an "Advanced HRV" screen. Draw confidence as a filled ribbon, never as two lines. Lead each with one sentence in plain words. |
| B16 | Rhythm screen | Headline sentence + one strip painter (merge `_RhythmStrip` into `HeatMap`), "clear" days in green-neutral not grey, legend swatches matching the marks. |
| B18 | Nutrition bars | `p.on` ink, dashed goal line. |
| B20 | Month grid | Colour cells by judgement (in range / below / above usual), shared legend at top, invert the ramp for lower-is-better metrics. |
| B21 | Consistency | Real calendar dots (which days) or a single bar; not a count drawn as a timeline. |
| B23 | ECG | Standard 25 mm/s, 10 mm/mV small/large grid on the saved reading and its export. |
| B24 | Spectrum | Delete (unused). |

## 6. Priorities

Top 10 chart problems, by user impact:

1. No personal normal-range band on any trend except driver breakdown (X1; A2, A3, A5, A9).
2. Auto-fit y axes and axis-less sparklines turn small changes into big swings (X2).
3. Night stack lanes print no numbers and are auto-scaled per lane (A9).
4. Readiness history is always green while the ring shows the band colour (A5, X3).
5. Hypnogram has no lane labels; light-theme stage colours are muddy and unordered (A8).
6. Only 2 of ~45 charts respond to touch; day HR, readiness, laps, zones cannot be read (X4).
7. Jargon in titles/units/legends: RMSSD, TRIMP, CTL/TSB, DC, SD1/SD2, "rel", "shape only" (X5).
8. Zone bars are 8–10 pt stacked colour strips that fail colour-blind users and define no zones (B1).
9. Actogram, stillness and forecast charts are research plots in the main flow (B10, B11).
10. Month grid shades by raw value, so "dark" means good for HRV and bad for resting HR (B20).

Five highest-impact changes:

1. Ship `PersonalBand` + `ReadingHeader` and apply them to TrendCard, metric detail, readiness history and night-stack lanes. One component, four screens, answers "is this normal?".
2. Colour by judgement, not by metric: readiness bars by band, sparkline endpoints by judgement, month grid by in/below/above range. Lines stay neutral.
3. Press-and-hold tooltip on every time-series chart via the existing `Scrubber`, starting with day timeline HR, readiness history and the night stack (shared cursor with the hypnogram).
4. Hypnogram and zones rebuilt as labelled rows: stage names and totals per lane; five zone rows with bpm range and minutes.
5. Move research charts (Poincaré, DC, shape-of-night, half-hour RMSSD, actogram, spectrum) behind an "Advanced" screen; rewrite the remaining titles in plain words; cap footnotes at one sentence.

## 7. Reproduce the renders

```
cd ~/Documents/openstrap/.worktrees/edge-main-check
CASES=chart_line,chart_hypnogram,trend ~/flutter-sdks/flutter/bin/flutter test --no-pub \
  --update-goldens /tmp/uxshots/shots_test.dart   # writes /tmp/uxshots/out/*.png
python3 /tmp/uxshots/sheet.py /tmp/uxshots/out /tmp/uxshots/sheet.png chart_line,trend
```
The test lives only in /tmp and imports `galleryCases()`; the repo is untouched
(`git status` clean after the run).
