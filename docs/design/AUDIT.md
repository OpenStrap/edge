# Volt overhaul — Phase 0 audit

Generated 2026-10-19 on branch `ui/volt-phase-0`, Flutter 3.41.6 (the CI pin).
No visual changes in this phase. Counts come from a scanner that strips
comments and string literals with the repo's own `test/support/dart_source.dart`
(the same primitive `ui2_tokens_test` uses), so a widget named in a comment is
not counted. "Outside" means outside `grammar.dart` and `theme.dart`, where the
brief's leak table draws the line.

`lib/ui2`: **78 files, 67,013 lines** (the brief says 77 / ~61k).

---

## 1. Font shortlist (§4.5)

Downloaded from each font's official GitHub repo into a scratch dir (not
`assets/`), checked with fontTools 4.x, then rendered with the app's real
numbers at `F.n64` / `F.display` / `F.body` through Flutter's own text engine.

| Check | Urbanist | Outfit | Plus Jakarta Sans |
|---|---|---|---|
| 1. `tnum` in GSUB | **no** (static and variable; Google Fonts build too) | yes | yes |
| Digit advances | proportional, 550–1194 units | tnum → all 590 | tnum → all 600 |
| 2. Latin Ext-A (ő ű ä é) | yes (13/128 of the block missing) | yes (29/128 missing) | yes (2/128 missing) |
| 2. Cyrillic | **none** | **none** | **none** |
| 2. Devanagari | none (expected) | none | none |
| 3. Static 400/500/600 | yes (+700) | yes (+700) | yes (+700) |
| Variable | `wght` 100–900 | `wght` 100–900 | `wght` 200–800 |
| OFL.txt | yes | yes | yes |
| Size per static weight | ~72 KB | ~73 KB | ~126 KB |

Specimens (open these):

- `build/design_snapshots/fonts/specimen_Urbanist.png`
- `build/design_snapshots/fonts/specimen_Outfit.png`
- `build/design_snapshots/fonts/specimen_Plus_Jakarta_Sans.png`

Each shows Char (left) and Cream (right), and a `1111 / 8888 / 4070` stack
that has to line up. Urbanist's does not: `1111` is visibly narrower than `8888`.

**The rule in §4.5 picks Outfit.** It says to take the first candidate that
passes test 1. Urbanist fails test 1, so the default doesn't apply.

- **Outfit (recommended).** Closest in shape to Urbanist and the mood board: round,
  geometric, with an open `a` and `g`. Its tabular `1` has a foot serif, which you
  can see in `1,174`. That's the price of real tabular figures.
- Plus Jakarta Sans also passes, but it sets wider. The specimen body text wraps
  to an extra line, which is a cost with Russian and Hindi in mind. It is also
  ~70% larger per file.
- Urbanist is only possible with the brief's fallback: fixed-width digit boxes
  inside `Numeral`. Then every `F.n*` number outside `Numeral` would re-flow,
  and that's most of them today.

**Cyrillic:** none of the three has it. Russian will fall back to the platform
font (Roboto / SF), so Russian text will not be in the brand face. That's
acceptable per the brief. The 3.1× Russian sweep has to be checked in Phase 1
once the family lands (`test/russian_gallery_layout_test.dart` exists).

---

## 2. Leak table (§2), re-counted

| Leak (lib/ui2, outside grammar/theme) | Brief | **Now** | Files | Fix (phase 4) |
|---|---|---|---|---|
| `TextButton` | 33 | **33** | 10 | `TextAction` |
| `showModalBottomSheet(` | 22 | **20** | 15 | `AppSheet.show()` |
| `AlertDialog(` | 13 | **12** | 8 | `AppDialog.show()` |
| `TextField(` | 38 | **14** (+2 `TextFormField`) | 12 (+1) | `AppField` |
| `Switch(` | 6 | **3** (+1 `SwitchListTile`) | 2 (+1) | `AppSwitch` |
| Icon `size:` literals | ~180, 14 values 12–54 | **165, 22 values 11–54** | 43 | `I.*` |
| raw `Container(` | 98 | **82** | 31 | review |
| raw pigment into a painter | ≥1 | **3** | 3 | pass a solved colour |
| `Image.asset(` | — | 2 | 2 | `Art` |
| `BackdropFilter(` | — | 0 | 0 | `Glass` |
| numeric `EdgeInsets` literal | — | ≥ 51 (single-line calls only) | | future ban §11 |

The brief's higher numbers for `TextField` and `Switch` probably counted comments
and doc mentions as well. The scanner here counts only code.

**Raw pigment into a painter** (`C.*` straight into a painter, not through
`p.on` / `p.fill`):

- `lib/ui2/screens/home_screen.dart:2203`: `Ring(steps/goal, C.green, …)`, the steps mini-ring (the one the brief named)
- `lib/ui2/screens/nutrition_screen.dart:500`: `Bars(vals, C.domFood, …)`
- `lib/ui2/profile/gallery.dart:244`: `LineChart(_series, C.purple)`, a gallery sparkline

Also: `readinessBand()` (`home_screen.dart:751`) returns raw `C.green / C.orange
/ C.red / C.n400`. Its callers have to solve it. Check each one in Phase 3 when
the ramp changes.

### Raw Material / Cupertino widgets (outside grammar/theme)

| Widget | Sites | Files | Covered by the brief? |
|---|---|---|---|
| `Divider` | 60 | 24 | **no.** Hairline colour/inset will drift from Volt's `p.line` |
| `SnackBar` (ScaffoldMessenger) | 41 | 14 | **no.** Default Material snackbar styling |
| `CircularProgressIndicator` | 36 | 28 | **no** |
| `TextButton` | 33 | 10 | yes |
| `showModalBottomSheet` | 20 | 15 | yes |
| `TextField` | 14 | 12 | yes |
| `showDialog` | 13 | 9 | yes (with AlertDialog) |
| `AlertDialog` | 12 | 8 | yes |
| `showTimePicker` | 11 | 9 | **no.** Material picker takes the seed colour |
| `showDatePicker` | 4 | 4 | **no** |
| `Switch` | 3 | 2 | yes |
| `LinearProgressIndicator` | 3 | 3 | no |
| `TextFormField` | 2 | 1 | treat with `TextField` |
| `DropdownButton` | 2 | 2 | no |
| `ListTile` | 2 | 2 | no |
| `AppBar` | 2 | 1 | no |
| `RefreshIndicator` | 2 | 2 | no |
| `SimpleDialog` | 1 | 1 | no |
| `showDateRangePicker` | 1 | 1 | no |
| `SwitchListTile` | 1 | 1 | treat with `Switch` |
| `RangeSlider` | 1 | 1 | no |
| `Tooltip` | 1 | 1 | no |
| `Material` | 1 | 1 | no |

The uncovered ones mostly re-skin through `ThemeData` (`colorScheme`,
`dividerTheme`, `snackBarTheme`, `progressIndicatorTheme`, `timePickerTheme`,
`datePickerTheme`) in `buildTheme`. That's one place in theme.dart, not 180
call-site edits. **Proposal: add those sub-themes in Phase 1** so the pickers and
snackbars don't stay Material-green. Every site is listed in the appendix.

### Component usage (outside grammar/theme): what re-skins for free

`Surface` 223 · `StatusCard` 213 · `Pressable` 120 · `Section` 98 ·
`BigButton` 53 · `ChartFrame` 47 · `Pill` 46 · `NavBar` 35 · `MetricRow` 29 ·
`SubTabs` 13 · `SignalCard` 9 · `ActionCard` 9 · `Ring` 8 · `Consistency` 8 ·
`InsightCard` 6 · `ProfileAvatar` 6 · `ScreenTitle` 5 · `TrendCard` 5 ·
`Observation` 5 · `DeepDiveCard` 4 · `ProgressCard` 2 · `Recommendation` 2 ·
`DashedRing` 2.

---

## 3. Icon size literals

165 `Icon(… size: <number>)` sites across 43 files (grammar.dart included,
since it's in scope for `I.*` too). There are 22 distinct values, so the brief's
five-step `I` ramp (16/20/24/32/48) has to absorb these:

| size | sites | → proposed `I.*` |
|---|---|---|
| 11, 12, 13, 14, 15 | 1, 7, 5, 6, 12 | `I.sm` 16 (inline-with-caption icons; check that 11–13 don't grow a row) |
| 16, 17, 18 | 31, 23, 34 | `I.sm` 16 / `I.md` 20 (decide per role: inline vs leading) |
| 19, 20, 22 | 4, 21, 7 | `I.md` 20 |
| 24, 25, 26, 28 | 3, 1, 1, 1 | `I.lg` 24 |
| 30, 36, 38, 40 | 1 each | `I.xl` 32 |
| 44, 46, 54 | 2, 1, 1 | `I.hero` 48 |

Three more `Icon`s pass a non-literal size. All sites are in the appendix.

---

## 4. Screens whose hero will change (§6)

The current hero is what you see first today. Data stays the same in every case.

| Screen | Current hero | Volt hero | Notes |
|---|---|---|---|
| `screens/home_screen.dart` (Today) | `RingTrio`: 3 rings, icon inside, numeral **under** the ring, raw domain hues | `RingTrio` restyled (numeral inside, 12 px stroke) **or** `ScallopBadge` + small rings (D5) | the steps mini-ring uses raw `C.green`; "At a glance" → `AuroraTile` grid |
| `screens/readiness_detail.dart` | `Ring` + `F.n48` | big `Numeral` / scallop | readiness ramp: see open item O3 |
| `screens/sleep_tab.dart` → `sleep_detail.dart` (Sleep) | `F.n48` total + `Hypnogram` | `F.n64` total + lavender aurora glow; day-switcher pill | hypnogram → lavender ramp |
| `screens/workout_screen.dart` (Activity) | `StartCard` (cream mascot) + `F.n34` | `StartCard` on sky aurora with `art_workout`, volt play button | mascot removed in Phase 6 |
| `screens/start_card.dart` | `Image.asset` mascot, two grounds | `Art` slot | header comments about CREAM mascots must go |
| `screens/wellness_screen.dart` | `StartCard` (wellness mascot) | `StartCard` + `art_wellness` | |
| `activity/live.dart` | `F.n48` ×4, `Ring`, `BreathRing` | `F.n64` HR + coral live line, full-bleed Char | don't touch `Motion.tick` |
| `activity/poster.dart` | `F.n48` | palette only, same layout | |
| `screens/health_screen.dart` (Health) | `ScreenTitle` + `SubTabs`, no single hero | grouped `MetricRow` list | |
| `screens/metric_detail.dart` | `F.n48` + `LiveHrCard`, 6 `Ring`s | big `Numeral` + coral `Pill('LIVE')`, 3-up normal range | |
| `screens/calm_breathing.dart` | `BreathRing` + `F.t1` | sage aurora + `BreathRing` | phase stays caller-owned |
| `screens/nutrition_screen.dart` | `ScreenTitle` + `F.n34` | amber aurora | `Bars(C.domFood)` raw pigment |
| `profile/profile.dart`, `profile/devices.dart` | `NavBar` + lists | `RoundIconButton` header, grouped lists, device art | |
| `onboarding/welcome.dart` | `F.display` headline | Char canvas, `StepPath`, `Glass` pills, `art_band_hero`, volt circle CTA | onboarding is always Char |
| `onboarding/pairing.dart`, `profile_setup.dart` | `F.t1` | as above, step-aware | |
| `onboarding/splash.dart` | none | Char | |
| `pairing/device_picker.dart` | `NavBar` | device art per family | |

Hero widgets nobody pumps today: `HomeScreen`, `SleepTab`, `WorkoutScreen`,
`HealthScreen` and `StartCard` are all on `_notComponents`, so the snapshot
harness can't see them until Phase 5 adds the tab roots with fixtures.

---

## 5. Open items for the human

> **Resolved 2026-10-19:** O1 Outfit · O2 images moved to `refs/` · O3 coral < 26 / amber 26–37 / volt ≥ 37 · O4, O5, O7 accepted as proposed (recorded as D3a, D6–D9 in DESIGN_OVERHAUL.md §12).

- **O1 — Font.** Outfit per the §4.5 rule (Urbanist fails `tnum`). Or say
  "Urbanist anyway" and Phase 1 builds the fixed-width digit fallback into
  `Numeral`.
- **O2 — Refs folder.** The brief points at `docs/design/refs/`, but the five
  mood-board images are loose in `docs/design/` with generated names
  (`1792435995808_image.png` …). Move/rename them, or the brief needs updating.
  I didn't move them.
- **O3 — Readiness ramp thresholds (§5.5).** The brief's example ramp is coral
  < 34 → amber 34–66 → volt ≥ 67. The code has **four** bands with different
  cut-offs (`lib/compute/findings.dart`): Rest < 26, Take it easy 26–37,
  Steady 37–61, Good ≥ 61. Today they're coloured red / orange / green / green.
  Per "use the same thresholds the code uses", Phase 3 would map **coral < 26,
  amber 26–37, volt ≥ 37**. Confirm.
- **O4 — `zone_contrast_test.dart` guards the legacy palette.** It imports
  `lib/theme/tokens.dart` and checks `AppColors.zoneOnDark` on
  `AppColors.night/nightAlt`, not ui2's `ZoneRows.pigment`
  (`charts.dart:948`). The HR-zone re-solve in §5.5 isn't covered by that test,
  and Phase 7's deletion of `tokens.dart` will break it. Proposal: in Phase 3,
  point the test at `ZoneRows.pigment` through `P`. That's an "update the
  expected palette" change, not a weakened threshold.
- **O5 — Uncovered Material widgets.** `Divider` 60, `SnackBar` 41,
  `CircularProgressIndicator` 36 and the date/time pickers aren't in the leak
  plan. I'd propose `ThemeData` sub-themes in Phase 1 (no call-site churn) rather
  than new components.
- **O7 — `ui2_tokens_test` fails on Windows (pre-existing, not a regression).**
  Four of its rules (`fontSize:`, `Color(0x…)`, `Duration(`, raw gesture)
  compare the allow-list `lib/ui2/theme.dart` against `lib/ui2\theme.dart`,
  so the allow-list never matches on Windows and every token definition is
  reported. CI runs Linux and passes. Fix (one line, doesn't loosen
  anything): normalise `\` → `/` in `rel` at `ui2_tokens_test.dart:122`.
  Every phase is run on this Windows machine and has to end green, so
  proposal: fix it at the start of Phase 1.
- **O6 — Light mode (D4).** Default stays "Cream". There's nothing to decide
  unless you want to change that.

### Data notes (not fixed, out of scope)

None found in Phase 0. The gallery fixtures render without errors in all four
variants (`errors.txt` is empty everywhere).

---

## 6. Verification harness

`test/design_snapshots_test.dart` (tag `snapshots`, declared in
`dart_test.yaml`) is skipped unless `SNAPSHOTS=1`. It pumps every
`galleryCases()` entry on a 390×844 phone at 2× pixel ratio in dark + light at
1.0× and 2.0× text, loads every font in `FontManifest.json` (Manrope, also
registered as `.SF Pro Text`, plus the Lucide icon font), and writes:

```
build/design_snapshots/<SNAPSHOTS_LABEL|latest>/<dark|light>_<1.0|2.0>x/<case>.png
```

```bash
SNAPSHOTS=1 SNAPSHOTS_LABEL=before flutter test test/design_snapshots_test.dart
```

`SNAPSHOTS_ONLY=<regex>` re-shoots a subset. Errors raised while pumping go to
`errors.txt` per variant and don't fail the run (`ui2_component_sweep_test` is
the overflow gate). The "before" set is 159 cases × 4 variants = 636 PNGs, ~38
MB, about 1 minute of rendering.

---

## Appendix — every site


### TextButton (33)

- `lib/ui2/onboarding/welcome.dart`: 233, 236, 608
- `lib/ui2/profile/devices.dart`: 2063, 2066, 2116, 2119, 2170, 2173
- `lib/ui2/profile/settings.dart`: 413, 437, 440, 476, 479
- `lib/ui2/screens/coach.dart`: 279, 283
- `lib/ui2/screens/ecg.dart`: 807, 811
- `lib/ui2/screens/health_screen.dart`: 1767, 1770
- `lib/ui2/screens/home_screen.dart`: 1894
- `lib/ui2/screens/journal_compose.dart`: 812, 819, 826
- `lib/ui2/screens/sleep_detail.dart`: 565, 575, 769, 844, 848, 855, 863
- `lib/ui2/screens/wellness_screen.dart`: 1092, 1099

### showModalBottomSheet( (20)

- `lib/ui2/activity/exercise_picker.dart`: 19
- `lib/ui2/activity/zones.dart`: 220
- `lib/ui2/profile/devices.dart`: 1295, 1317, 2561
- `lib/ui2/profile/profile.dart`: 211
- `lib/ui2/profile/wearable_numbers.dart`: 510, 905
- `lib/ui2/screens/coach.dart`: 332
- `lib/ui2/screens/custom_journal_field_sheet.dart`: 25
- `lib/ui2/screens/cycle_screen.dart`: 276
- `lib/ui2/screens/ecg.dart`: 129
- `lib/ui2/screens/journal_compose.dart`: 187
- `lib/ui2/screens/log_food.dart`: 61, 784
- `lib/ui2/screens/log_workout.dart`: 268
- `lib/ui2/screens/nutrition_screen.dart`: 533
- `lib/ui2/screens/scan_barcode.dart`: 20
- `lib/ui2/screens/wellness_screen.dart`: 930, 1256

### AlertDialog( (12)

- `lib/ui2/onboarding/welcome.dart`: 194
- `lib/ui2/profile/devices.dart`: 2054, 2097, 2163
- `lib/ui2/profile/settings.dart`: 392, 424, 453
- `lib/ui2/screens/coach.dart`: 254
- `lib/ui2/screens/ecg.dart`: 796
- `lib/ui2/screens/health_screen.dart`: 1727
- `lib/ui2/screens/journal_compose.dart`: 784
- `lib/ui2/screens/wellness_screen.dart`: 1083

### TextField( (14)

- `lib/ui2/activity/exercise_picker.dart`: 160
- `lib/ui2/activity/picker.dart`: 105
- `lib/ui2/onboarding/profile_setup.dart`: 293
- `lib/ui2/onboarding/welcome.dart`: 209, 219
- `lib/ui2/pairing/device_picker.dart`: 446
- `lib/ui2/profile/devices.dart`: 2102
- `lib/ui2/profile/pair_sensor.dart`: 537
- `lib/ui2/profile/report_issue.dart`: 206
- `lib/ui2/profile/settings.dart`: 1694
- `lib/ui2/screens/coach.dart`: 639
- `lib/ui2/screens/journal_compose.dart`: 648, 1172
- `lib/ui2/screens/log_workout.dart`: 502

### TextFormField( (2)

- `lib/ui2/screens/health_screen.dart`: 1750, 1758

### Switch( / Switch.adaptive( (3)

- `lib/ui2/profile/report_issue.dart`: 290, 301
- `lib/ui2/profile/wearable_numbers.dart`: 887

### Container( (82)

- `lib/ui2/activity/exercise_picker.dart`: 146, 263
- `lib/ui2/activity/live.dart`: 649, 677, 757, 780, 1119, 1516, 1518, 1582, 1626, 1727, 1964, 1997, 2170, 2222, 2324, 2577
- `lib/ui2/activity/picker.dart`: 90, 342, 347
- `lib/ui2/activity/poster.dart`: 170, 560
- `lib/ui2/activity/setup.dart`: 140, 375
- `lib/ui2/activity/summary.dart`: 870, 1359, 1452, 1761, 2053, 2148
- `lib/ui2/activity/zones.dart`: 449
- `lib/ui2/app_shell.dart`: 174
- `lib/ui2/charts.dart`: 1044, 1050
- `lib/ui2/nudges.dart`: 124
- `lib/ui2/onboarding/profile_setup.dart`: 257
- `lib/ui2/pairing/device_picker.dart`: 435
- `lib/ui2/profile/band_notifications.dart`: 257
- `lib/ui2/profile/devices.dart`: 1591, 1619, 2256
- `lib/ui2/profile/profile.dart`: 74, 172
- `lib/ui2/profile/settings.dart`: 247, 301, 1591
- `lib/ui2/screens/calm_breathing.dart`: 721
- `lib/ui2/screens/coach.dart`: 626, 662, 696, 1086
- `lib/ui2/screens/cycle_screen.dart`: 1334
- `lib/ui2/screens/ecg.dart`: 485
- `lib/ui2/screens/health_screen.dart`: 1532
- `lib/ui2/screens/home_screen.dart`: 2417, 2511
- `lib/ui2/screens/journal_compose.dart`: 597, 634, 740, 1083, 1092, 1129, 1186
- `lib/ui2/screens/log_food.dart`: 473, 938
- `lib/ui2/screens/metric_detail.dart`: 2062, 2111, 2162
- `lib/ui2/screens/month_grid.dart`: 175
- `lib/ui2/screens/nutrition_screen.dart`: 872, 1049
- `lib/ui2/screens/sleep_detail.dart`: 1445
- `lib/ui2/screens/start_card.dart`: 100, 142
- `lib/ui2/screens/wellness_screen.dart`: 1288, 1322, 1440
- `lib/ui2/screens/workout_screen.dart`: 207, 439, 967, 1027

### Image.asset( (2)

- `lib/ui2/profile/settings.dart`: 310
- `lib/ui2/screens/start_card.dart`: 158

### BackdropFilter( (0)


### Divider (60)

- `lib/ui2/activity/exercise_picker.dart`: 223, 228
- `lib/ui2/activity/live.dart`: 1661, 2365
- `lib/ui2/activity/picker.dart`: 150, 230, 237
- `lib/ui2/activity/setup.dart`: 174, 186, 213, 223
- `lib/ui2/activity/share.dart`: 298
- `lib/ui2/activity/summary.dart`: 689, 1850, 2003
- `lib/ui2/activity/zones.dart`: 446
- `lib/ui2/pairing/device_picker.dart`: 383, 514
- `lib/ui2/profile/devices.dart`: 2310, 2319, 2332, 2350, 2401, 2412, 2438, 2446, 2457, 2467, 2479, 2490
- `lib/ui2/profile/gallery.dart`: 1074, 1080, 2034, 2039, 2043, 2290, 2357
- `lib/ui2/profile/pair_sensor.dart`: 489
- `lib/ui2/profile/profile.dart`: 132
- `lib/ui2/screens/circadian_detail.dart`: 696
- `lib/ui2/screens/cycle_screen.dart`: 739
- `lib/ui2/screens/driver_breakdown.dart`: 329
- `lib/ui2/screens/ecg.dart`: 200
- `lib/ui2/screens/findings_log.dart`: 95
- `lib/ui2/screens/health_screen.dart`: 890, 1217, 1364, 1474, 1638
- `lib/ui2/screens/home_screen.dart`: 871, 880, 2348
- `lib/ui2/screens/metric_detail.dart`: 1739
- `lib/ui2/screens/naps.dart`: 287
- `lib/ui2/screens/readiness_detail.dart`: 484, 523
- `lib/ui2/screens/sleep_detail.dart`: 1517
- `lib/ui2/screens/workout_screen.dart`: 487, 1105, 1118

### SnackBar (41)

- `lib/ui2/activity/share.dart`: 124
- `lib/ui2/activity/summary.dart`: 966, 982
- `lib/ui2/activity/zones.dart`: 287, 298
- `lib/ui2/profile/alarm.dart`: 433
- `lib/ui2/profile/devices.dart`: 1860, 1902, 1912, 1915, 1933, 1936, 1954, 1957, 1974, 1977, 1991, 1994, 2010, 2015, 2032, 2035, 2142, 2146
- `lib/ui2/profile/gallery.dart`: 2002
- `lib/ui2/profile/report_issue.dart`: 182, 354
- `lib/ui2/profile/settings.dart`: 137, 492, 503
- `lib/ui2/screens/health_screen.dart`: 1619, 1690, 1804, 1816
- `lib/ui2/screens/journal_compose.dart`: 122, 138
- `lib/ui2/screens/log_food.dart`: 692
- `lib/ui2/screens/log_workout.dart`: 603
- `lib/ui2/screens/metric_detail.dart`: 1842
- `lib/ui2/screens/wellness_screen.dart`: 732, 758

### CircularProgressIndicator (36)

- `lib/ui2/activity/day_strain.dart`: 227
- `lib/ui2/activity/zones.dart`: 318
- `lib/ui2/onboarding/pairing.dart`: 223
- `lib/ui2/onboarding/welcome.dart`: 630
- `lib/ui2/pairing/device_picker.dart`: 509
- `lib/ui2/profile/data.dart`: 454
- `lib/ui2/profile/devices.dart`: 360
- `lib/ui2/profile/phone_import.dart`: 363
- `lib/ui2/profile/wearable_numbers.dart`: 886
- `lib/ui2/screens/beats.dart`: 263
- `lib/ui2/screens/circadian_detail.dart`: 340
- `lib/ui2/screens/coach.dart`: 451
- `lib/ui2/screens/cycle_screen.dart`: 344
- `lib/ui2/screens/day_steps.dart`: 305
- `lib/ui2/screens/day_timeline.dart`: 921
- `lib/ui2/screens/detected_activities.dart`: 153
- `lib/ui2/screens/ecg.dart`: 635
- `lib/ui2/screens/health_screen.dart`: 657, 1117, 1308, 1433
- `lib/ui2/screens/home_screen.dart`: 1653, 1754
- `lib/ui2/screens/investigate.dart`: 289
- `lib/ui2/screens/journal_compose.dart`: 255, 911, 1198
- `lib/ui2/screens/metric_detail.dart`: 918
- `lib/ui2/screens/naps.dart`: 248
- `lib/ui2/screens/nutrition_screen.dart`: 247
- `lib/ui2/screens/readiness_detail.dart`: 175
- `lib/ui2/screens/sleep_detail.dart`: 531
- `lib/ui2/screens/wellness_screen.dart`: 243, 285, 1601
- `lib/ui2/screens/what_changed.dart`: 160

### showDialog (13)

- `lib/ui2/onboarding/welcome.dart`: 144
- `lib/ui2/profile/alarm.dart`: 385
- `lib/ui2/profile/devices.dart`: 2052, 2095, 2161
- `lib/ui2/profile/settings.dart`: 390, 422, 451
- `lib/ui2/screens/coach.dart`: 252
- `lib/ui2/screens/ecg.dart`: 794
- `lib/ui2/screens/health_screen.dart`: 1724
- `lib/ui2/screens/journal_compose.dart`: 782
- `lib/ui2/screens/wellness_screen.dart`: 1079

### showTimePicker (11)

- `lib/ui2/profile/alarm.dart`: 368
- `lib/ui2/profile/settings.dart`: 1310
- `lib/ui2/screens/detected_activities.dart`: 395
- `lib/ui2/screens/journal_compose.dart`: 163
- `lib/ui2/screens/log_food.dart`: 245
- `lib/ui2/screens/log_workout.dart`: 235
- `lib/ui2/screens/naps.dart`: 197, 203
- `lib/ui2/screens/sleep_detail.dart`: 909, 915
- `lib/ui2/screens/wellness_screen.dart`: 1277

### showDatePicker (4)

- `lib/ui2/screens/detected_activities.dart`: 388
- `lib/ui2/screens/log_food.dart`: 235
- `lib/ui2/screens/log_workout.dart`: 218
- `lib/ui2/screens/metric_detail.dart`: 2014

### LinearProgressIndicator (3)

- `lib/ui2/activity/live.dart`: 2550
- `lib/ui2/paint_activity.dart`: 283
- `lib/ui2/screens/ecg.dart`: 571

### DropdownButton (2)

- `lib/ui2/screens/coach.dart`: 1096
- `lib/ui2/screens/health_screen.dart`: 1737

### ListTile (2)

- `lib/ui2/profile/devices.dart`: 395
- `lib/ui2/profile/profile.dart`: 220

### AppBar (2)

- `lib/ui2/screens/ecg.dart`: 166, 857

### RefreshIndicator (2)

- `lib/ui2/screens/home_screen.dart`: 2104
- `lib/ui2/screens/sleep_detail.dart`: 400

### SimpleDialog (1)

- `lib/ui2/profile/alarm.dart`: 387

### showDateRangePicker (1)

- `lib/ui2/profile/data.dart`: 138

### SwitchListTile (1)

- `lib/ui2/onboarding/profile_setup.dart`: 218

### RangeSlider (1)

- `lib/ui2/screens/day_timeline.dart`: 1175

### Tooltip (1)

- `lib/ui2/activity/exercise_picker.dart`: 333

### Material (1)

- `lib/ui2/onboarding/splash.dart`: 81

### Icon size literals (165)

- `lib/ui2/activity/exercise_picker.dart`: 141, 152, 208, 322, 344
- `lib/ui2/activity/live.dart`: 581, 600, 654, 681, 829, 1136, 1528, 1552, 1561, 1568, 1819, 1972, 2188
- `lib/ui2/activity/picker.dart`: 96, 189, 204, 288, 301, 305, 324, 352
- `lib/ui2/activity/poster.dart`: 378, 494, 568
- `lib/ui2/activity/setup.dart`: 145, 308, 319, 353
- `lib/ui2/activity/summary.dart`: 1053, 1065, 1083, 1461, 1766
- `lib/ui2/app_shell.dart`: 233
- `lib/ui2/grammar.dart`: 370, 462, 478, 619, 729, 810, 871, 917, 1121, 1402, 1435, 1462, 1561, 1627, 1684, 2085, 2151, 2706, 2751
- `lib/ui2/live_hr.dart`: 118
- `lib/ui2/nudges.dart`: 108, 148
- `lib/ui2/onboarding/pairing.dart`: 205
- `lib/ui2/onboarding/splash.dart`: 85
- `lib/ui2/onboarding/welcome.dart`: 584, 610, 739
- `lib/ui2/pairing/device_picker.dart`: 393, 440, 498
- `lib/ui2/profile/band_notifications.dart`: 263
- `lib/ui2/profile/devices.dart`: 1596, 1638, 1686, 2262
- `lib/ui2/profile/gestures.dart`: 161
- `lib/ui2/profile/profile.dart`: 82, 114, 178, 223
- `lib/ui2/profile/settings.dart`: 253
- `lib/ui2/screens/ai_briefing.dart`: 241
- `lib/ui2/screens/calm_breathing.dart`: 553, 778, 873
- `lib/ui2/screens/coach.dart`: 438, 544, 589, 669, 766, 793, 1037, 1184
- `lib/ui2/screens/cycle_screen.dart`: 651, 766
- `lib/ui2/screens/day_timeline.dart`: 1268, 1337
- `lib/ui2/screens/detected_activities.dart`: 223, 238
- `lib/ui2/screens/driver_breakdown.dart`: 417
- `lib/ui2/screens/ecg.dart`: 254, 278, 287, 417, 920, 932
- `lib/ui2/screens/findings_log.dart`: 143
- `lib/ui2/screens/health_screen.dart`: 1577, 1666
- `lib/ui2/screens/home_screen.dart`: 279, 898, 1237, 1259, 1861, 2422, 2462, 2516
- `lib/ui2/screens/journal_compose.dart`: 306, 356, 470, 601
- `lib/ui2/screens/log_food.dart`: 461, 580, 942, 965
- `lib/ui2/screens/metric_detail.dart`: 1639, 1902, 1919, 2058, 2115, 2124
- `lib/ui2/screens/naps.dart`: 377
- `lib/ui2/screens/nutrition_screen.dart`: 233, 633, 876, 904, 995, 1057
- `lib/ui2/screens/rough_night.dart`: 450, 471, 490
- `lib/ui2/screens/scan_barcode.dart`: 65
- `lib/ui2/screens/sleep_detail.dart`: 710, 798, 1795
- `lib/ui2/screens/start_card.dart`: 147
- `lib/ui2/screens/wellness_screen.dart`: 626, 1187, 1293, 1301, 1395, 1447, 1474, 1510
- `lib/ui2/screens/what_changed.dart`: 258
- `lib/ui2/screens/workout_screen.dart`: 215, 444, 724, 746, 747, 972, 1032, 1056, 1091, 1124
- `lib/ui2/trend.dart`: 196

### Numeric EdgeInsets literals (51)

- `lib/ui2/activity/live.dart`: 620, 1728, 2579
- `lib/ui2/activity/picker.dart`: 125
- `lib/ui2/activity/setup.dart`: 135, 367
- `lib/ui2/activity/share.dart`: 238
- `lib/ui2/activity/summary.dart`: 509, 1077
- `lib/ui2/app_shell.dart`: 219
- `lib/ui2/charts.dart`: 983
- `lib/ui2/pairing/device_picker.dart`: 335
- `lib/ui2/profile/alarm.dart`: 269
- `lib/ui2/profile/band_notifications.dart`: 137
- `lib/ui2/profile/data.dart`: 331
- `lib/ui2/profile/devices.dart`: 364, 1423, 2253, 2567
- `lib/ui2/profile/gallery.dart`: 2346, 2442
- `lib/ui2/profile/gestures.dart`: 85
- `lib/ui2/profile/pair_sensor.dart`: 402
- `lib/ui2/profile/phone_import.dart`: 204
- `lib/ui2/profile/profile.dart`: 352
- `lib/ui2/profile/report_issue.dart`: 254
- `lib/ui2/profile/settings.dart`: 302, 640, 999, 1574, 1773
- `lib/ui2/profile/wearable_numbers.dart`: 1065
- `lib/ui2/screens/coach.dart`: 341, 445
- `lib/ui2/screens/day_timeline.dart`: 1336
- `lib/ui2/screens/home_screen.dart`: 84
- `lib/ui2/screens/journal_compose.dart`: 257, 1152, 1164, 1168, 1208
- `lib/ui2/screens/log_workout.dart`: 401, 528
- `lib/ui2/screens/metric_detail.dart`: 1963, 2195
- `lib/ui2/screens/nutrition_screen.dart`: 240
- `lib/ui2/screens/wellness_screen.dart`: 277, 940, 1264
- `lib/ui2/screens/what_changed.dart`: 257
- `lib/ui2/screens/workout_screen.dart`: 101

