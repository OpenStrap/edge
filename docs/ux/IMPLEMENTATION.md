# UX redesign: what was built

Branch `ux/redesign`, cut from edge main at `80c75a5d` (after the multi-device merge, #579).
Not merged. The plan it follows is `docs/ux/PLAN.html`; the research behind it is in
`01_user_feedback.md` to `04_competitor_benchmark.md` in this folder.

No step changed compute or derivation. `test/whoop_freeze_golden_test.dart` passes under
TZ=UTC, Asia/Kolkata and America/New_York at the head of the branch.

Full suite under TZ=UTC on a macOS host: 6018 passed, 23 skipped, 1 failed. The failure is
`health_workout_export_delete_gate_test.dart` ("a failed delete does not write a duplicate"):
the test assumes a non-Apple host, and `HealthExporter.isApple` is true on macOS. Neither the
test nor `lib/health` changed on this branch. `flutter analyze` is clean.

## What each step changed

Steps ran in the order below. Each has a first commit and a review follow-up.

**Words (plan phase 4)**: `1c68e045`, `d2593080`
- One name per score. "Recovery" for the 0-100 score everywhere (detail screen, cards,
  findings, notifications, coach prompts). "Strain" for the daily score. "Training load"
  only for the fitness and fatigue trend. The daily TRIMP chart is now "Heart effort by day".
  A vendor's own "Readiness score" keeps its name.
- Wellness "Recovery" sub-tab became "Sleep plan". "Autonomic tension" became "Stress level".
- Jargon out of everyday copy: RMSSD/SDNN/PRV, derived, baseline, percentile, chronotype,
  MET, Calibrating. Method names stay on the method sheet and in Nerd stats.
- Recovery breakdown and sleep rows are plain questions ("Did you sleep enough?").
- About 90 strings over 150 characters cut. The coach size error says what to do, no SQL.
- New guard: `test/copy_jargon_guard_test.dart`.

**Charts (plan phase 3)**: `60fb8484`, `bfbd9599`, `7b58fd0e`, `1607a8a0`
- `lib/ui2/trend.dart`: the usual-range band (pipeline baseline for resting HR, HRV and
  breathing; the ring's Steady band for Recovery), an axis scaled to the band, and a verdict
  line (word, arrow, difference from usual). Under 14 days there is no band, and one line
  says when it arrives.
- Health trend cards, metric detail and Recovery history use it. Recovery history is daily
  bars in the ring's band colours. Press and hold reads a value. The overnight chart shares
  the stage chart's cursor. Month-grid cells read below, usual or above with a legend and a
  bar so direction is not colour-only.
- Hypnogram lanes named and totalled. One `ZoneRows` component (zone, bpm range, bar,
  minutes) replaces the thin zone strip everywhere. Strain axis fixed to 0-21.
- An Advanced charts screen (from Health and HRV detail) holds the research charts.
- Semantics on every touched chart. New tests: `ui2_trend_reading_test.dart`,
  `ui2_advanced_charts_test.dart`; ru at 1.0/1.3/3.1x on a 360 pt phone.

**Corrections (plan phase 2)**: `0db14ef0`
- Detected items read "Not a nap", "Not a workout", "Change sport"; a night read "Not sleep".
  A night with nothing found offers "I was asleep". All reuse existing overrides that
  reanalysis already replays. `corrections_persist_test.dart` pins that they survive
  re-detection and a restart.

**Structure (plan phase 5 and part of phase 1)**: `f387f539`
- Four tabs: Today, Sleep, Activity, Health. Profile avatar on every tab, replacing the gear.
- Today: pull to refresh asks the band to sync, with a visible sync card; one card for all
  missing readings; "Back to today"; a coach chip shown before setup; a "Your first weeks"
  card whose counts come from the analytics gates (Strain from day 4, Recovery from night 15).
- Sleep tab holds the Sleep screen, sleep plan, naps, alarm and body clock.
- Activity holds workouts, steps and Nutrition. Health holds Mind, Habits, Medication, Cycle.
- Settings grouped Band / App / Data / Privacy / Advanced. Export is one row on Profile.
- Onboarding offers cycle tracking, on by default for a female profile.
- Notification tab numbers remapped; the saved tab index migrates from the five-tab layout.
- New test: `ux_four_tab_structure_test.dart`.

**Final consistency pass** (this commit): de, es, fr, hi and zh still called the detail
screen and wearable row "Readiness" in their own words while their ring said "Recovery".
They now use each locale's ring word.

## Screenshots

In the app: Profile, Settings, tap Version 7 times to turn on developer mode, then
Developer, Component gallery. Every reusable component renders there with fixture data.

Headless renders for the chart audit used a throwaway test that imports `galleryCases()`
from `lib/ui2/profile/gallery.dart` and writes PNGs with `--update-goldens`
(see `02_chart_audit.md` section 7). It lived in `/tmp/uxshots` and is not in the repo.
Gallery fixtures are synthetic, so check Today, Sleep and Health on a real device too.

## Left from the plan

- Phase 1: the recovery-states work (provisional and final scores, no early pins, an
  "Updated 2 to 28" note). It touches derivation and lives on its own branch.
- Phase 1: one consistent empty state across every card was not done as its own step.
- Real-device review of Today, Sleep and Health.

## Open owner decisions

- Trade dress. Today still shows three rings with a "Why?" panel under them, the layout
  named in the 17 March 2026 suit against Bevel. This branch kept the existing look, and the
  phase 4 naming settled on "Recovery" and "Strain", the same words WHOOP uses. Decide whether
  to redesign the ring trio or rename; check with a lawyer.
- Discord and Reddit feedback was not mined. Export it and check it against the ranking in
  `PLAN.html` before merging.
