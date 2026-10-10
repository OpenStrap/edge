# Health Age Estimate: progress

Last updated: 2026-10-10.

## Current status

Documentation, initial literature review, and a static audit of the actual fork are complete. No application code, age model, participant recruitment, data collection, hardware testing, or user validation has been completed. The source audit below establishes candidate data paths; per-user completeness and runtime behavior remain unverified.

The [module overview](README.md) defines the intended experience and v0 boundary. [Research notes](research.md) collect public WHOOP inputs, initial literature, and unresolved questions.

## Decisions made

- Use the independent name **Health Age Estimate** and label it experimental.
- Prefer transparent, locally processed factor summaries over unsupported precision.
- Start v0 with available factors and data coverage. Defer numerical health/fitness age and age difference until a defensible model is validated.
- Show actual age only when supplied; do not infer it from physiological signals.
- Keep missing data unavailable and identify provenance, observation dates, and measurement limitations.
- Distinguish data coverage from confidence in an age model. Do not assign an age-confidence percentage in v0.
- Use WHOOP's public materials as background, without claiming affiliation or reproduction of its proprietary algorithm.
- Keep this contribution documentation-only. Do not modify application code or the root README. The user subsequently authorized documentation commits on the fork branch; the initial notes and this audit are stored remotely.

## Next steps

1. Validate the audited data paths against real WHOOP 4.0 exports and inspect the pinned analytics implementations before making measurement-validity claims.
2. Define exact-date read contracts, aggregation windows, eligible-day coverage rules, zone-source handling, and duplicate-session policy for a small factor-summary prototype.
3. Expand the evidence review and obtain separate authorization before implementing any app or analytics changes.
4. Run the pilot below after a prototype exists. Revisit numerical age only if an independent model and prespecified validation criteria can be justified; otherwise retain factor summaries.

## Validation plan with real WHOOP users

This is a proposed feasibility and usability pilot, not clinical validation. Target 5–10 consenting adults with varied activity levels and wear consistency, including WHOOP 4.0 users where supported. A small convenience sample cannot establish population-wide age accuracy.

### Collection and comparison

- Ask participants to voluntarily share only the minimum de-identified observations needed for comparison. Do not request account credentials, full birth dates, or unrelated health records.
- Before collection, explain the purpose, fields, storage, access, retention/deletion schedule, and withdrawal process. Keep raw participant records out of the public repository; publish only consented aggregate findings.
- Compare local summaries with participant-provided official-app summaries for matching dates, timezones, units, and aggregation windows. Record metric definitions, device/model, app versions, missing days, and manual inputs so differences are interpretable.
- Include normal wear, interrupted wear, missing factors, and stale manual measurements when present. Do not ask participants to change medication, exercise, or sleep for the pilot.
- Record official Healthspan output only if a participant has access and chooses to share it. It is an optional comparator, not ground truth or a target to reverse-engineer.

### Evaluation and acceptance

- Check provenance and coverage: every displayed factor must trace to an available input; absent factors must remain unavailable. Report observed discrepancies and their likely causes rather than hiding them in a combined score.
- Check reproducibility: the same inputs and prototype version must produce the same summaries. Inspect sensitivity to incomplete days, timezone boundaries, and outliers before interpreting trends.
- Check comprehension: ask each participant to explain the experimental label, missing-data indicators, and the distinction between coverage and confidence. Record misunderstandings and revise wording before wider release.
- Check the v0 boundary: numerical health age, age difference, and age-estimate confidence must remain unavailable. No fabricated values or unsupported year adjustments may appear.
- Report participant count, data completeness, comparison limitations, discrepancies, and unresolved issues. Set metric-specific agreement tolerances after definitions are audited and before evaluating the pilot; do not retrofit tolerances to observed results.

Any later numerical age model needs a separate validation design with independent reference data, prespecified calibration and uncertainty criteria, and subgroup evaluation. Matching WHOOP output or finding a prototype understandable does not establish a valid health-age estimate.

## App data availability audit

Audited on 2026-10-10 at [source commit `6d686b0`](https://github.com/namahsea/edge/tree/6d686b083e15efb6852bd10703c3f09917ef0825). All reads and writes target the fork `namahsea/edge`, branch `feature/health-age-docs`. Source files were read remotely into memory; no clone or source archive was saved locally. This was static source inspection, not a Flutter build, hardware test, or real-user validation. Implementation capability does not mean a particular user has populated data.

### Structure and storage

- `lib/ble/` receives band data; `lib/compute/substrate.dart` provides the decoded time-series substrate and sleep segmentation seam. `lib/compute/derivation_engine.dart` coordinates derivation, versioning, and persistence; `onehz_pipeline.dart` assembles per-day metrics; `crossday_pipeline.dart` handles longitudinal metrics.
- `lib/data/db.dart` owns SQLite: `decoded_onehz` / `decoded_rr` hold retained raw signals; `day_result` holds versioned JSON bundles and window metadata; `metric_series` holds nullable date/key/value scalars with companion version stamps. `sessions`, `strength_set`, `live_coverage`, and `imported_workout` store activity and step inputs.
- `lib/data/local_repository.dart` / `local_repository_impl.dart` expose app read shapes; `lib/models/metric.dart` / `payloads.dart` provide metric representations. Prefer existing envelopes and explicit dates over bare scalar pivots when provenance or absence matters.
- `lib/state/app_state.dart` persists profile data in SharedPreferences under `local_profile_json`. `lib/ui2/` consumes these interfaces; its screens were inspected only, not edited.
- `pubspec.yaml` pins the separate protocol and analytics packages to full SHAs. At this source revision, analytics is `ad6384746d36a2e6b7b964658d308e40de403c8a` and protocol is `89080bcfac7767b3a871fd3a7d9307f5f30dad26`. The dependency implementations were not independently audited. Per `AGENTS.md`, new metric algorithms belong in analytics; edge owns orchestration, storage, and presentation.

### Metrics found and limitations

Paths below are relative to the audited source commit; names identify executable storage/read/call sites, not evidence of clinical validity.

| Requested input | Finding and inspected paths | Feasibility and limitations |
| --- | --- | --- |
| Sleep duration | `compute/substrate.dart`, `compute/onehz_pipeline.dart`: sleep accounting includes `tst_sec`, in-bed and unobserved seconds; `tst_min` is an indexed scalar. `data/local_repository_impl.dart`: `getDaySleep`, `getDaySleepV2`, `sleepWindows`. All paths in this table are under `lib/`. | Available when sleep is scored. Reuse the existing segmentation and window; do not treat in-bed time as sleep or incomplete nights as complete. |
| Sleep consistency | `compute/crossday_pipeline.dart`: `_crossDaySri` builds minute sleep/wake validity grids and calls `ana.phillipsSri`; output is `regularity`. | Existing Phillips Sleep Regularity Index is a candidate, distinct from WHOOP's consistency metric. Missing dates/epochs are invalid rather than imputed. Reuse existing eligibility gates. |
| Steps | `data/db.dart`: `live_coverage`, `resolvedStepsForDay`; `data/local_repository_impl.dart`: `getDaySteps`; `compute/derivation_engine.dart`: assembled `steps` envelope; `health/phone_pedometer.dart`. | Conditional availability through measured band/phone windows, plus a calibrated on-chip-counter fallback. The counter modulus map currently lists gen5, not gen4. WHOOP 4.0 support must therefore be assessed through actual band-window or phone coverage, not assumed from gen5. |
| HR zones | `compute/hr_max.dart`: `trainingZones`; `compute/onehz_pipeline.dart`: `zones`, `zone_timeline`; `data/db.dart`: `sessions.zone_min_json`; `data/local_repository_impl.dart`: `getZones`, session rebins. | Zone time exists when HR and zone anchors are available. Sources include manual boundaries, observed HRmax, Karvonen reserve, and age-estimated Tanaka. Preserve the source; grouped zones 1–3 and 4–5 are possible summaries, not equivalent to WHOOP classifications. Day zones cover waking HR; session zones describe workouts. Do not add overlapping day/session totals. |
| Workouts | `data/db.dart`: `sessions` stores type, timestamps, status, duration, source, device family, and nullable derived fields. `data/activity_store.dart` manages suggestions and confirmation; `health/health_workout_import.dart` imports source-labelled records into `imported_workout`. | Completed recorded workouts are available. Pending suggestions are not completed sessions. Imported workouts have no HR series through this importer and are deliberately excluded from local training-load baselines; do not invent zone time or load from their duration. |
| Resting heart rate | `compute/onehz_pipeline.dart`: `nocturnalRhr(sleepHr, tsSec: sleepTs)`, persisted under `clinical.resting_hr`; `rhr` is a scalar series key. Profile can separately contain `resting_hr`. | Nocturnal RHR is available only with a scored sleep window and usable HR. No sleep means absence, not waking-HR substitution. Distinguish measured nightly RHR from any manual anchor used elsewhere. |
| VO₂ max | `data/local_repository_impl.dart`: `_submaxVo2maxFromSplits` calls `ana.vo2maxSubmaxEstimate`; `data/db.dart`: `sessions.vo2max_estimate` and `setSessionVo2max`. Display consumers exist in `ui2/activity/summary.dart` and `ui2/screens/workout_screen.dart`. | Conditional session-level submax estimate, not a universal daily metric or lab measurement. Requires a route with a full kilometre split, split HR, resting/max-HR anchors, and acceptance by analytics. It selects the longest-duration full split; steadiness is not explicitly established by a pace-variance check here. Backfilled once; raw retention can prevent later computation. No supported general lab/manual VO₂-max import was found. |
| Strength activity | `ui2/activity/catalogue.dart`, `ui2/activity/live.dart`: strength activity/logging; `data/db.dart`: `strength_set` linked to sessions, with exercise, reps, load, RPE, hold/rest time. | Logged strength sessions and sets exist. A completed session's duration can summarize recorded strength activity, but is not measured lifting time, muscle strength, or lean mass. No dedicated Healthspan-style weekly strength contributor was found; classification and overlap rules would need a small aggregation layer. |
| Lean body mass | Searched all `lib/` Dart files for lean/body-fat terms; inspected `compute/profile.dart`, `health/health_profile_import.dart`, `health/health_measurement_import.dart`, and DB metric paths. | No dedicated lean-mass/body-fat field, calculation, or supported import path found. Weight, height, and BMI are not lean mass. Leave unavailable. Imported clinical measurements are display-only under the existing project contract and must not be repurposed as model inputs. |
| Profile / age / DOB | `state/app_state.dart`, `compute/profile.dart`, `ui2/onboarding/profile_setup.dart`, `ui2/profile/profile.dart`, `health/health_profile_import.dart`. | Nullable integer `age`, weight, height, and sex are supported. Apple Health DOB can be converted to age on import; Health Connect does not supply DOB in this importer. The persisted profile stores age rather than DOB, so do not promise automatic birthday updates or infer a birth date. |

### Missing capabilities and pitfalls

- No independently validated health-age model, age difference, or calibrated age-confidence measure was found. `crossday_pipeline.dart` explicitly removed the earlier RHR-ratio VO₂-max / fitness-age path; do not revive it. Some comments and onboarding copy still mention fitness age and are not proof of an active calculation.
- Lean mass is absent. VO₂ max is conditional and approximate. Strength duration requires classification/aggregation, and step/HR coverage can be partial.
- A zero total in coverage helpers is not proof of an observed sedentary day. The current derived steps envelope returns null without positive measured steps; a future summary must retain this absence rather than invent a zero or average only positive days without explaining the bias.
- Daily bundles and repository convenience reads can select different windows or fall back to a latest complete day. Require exact-date reads for summaries, respect finalized/partial flags, and expose observation dates, sources, and algorithm versions.
- Metric confidence/tier fields describe individual outputs. They are not calibrated confidence in an age estimate, and should not be averaged into one.
- Raw data is pruned; stored derived results can span algorithm versions. A long retrospective dashboard cannot assume it can recompute all historical inputs.

### Recommended v0 implementation (future work, not implemented)

Build a read-only local factor summary over existing exact-date derived data. Start with chronological age when present, sleep duration, Phillips SRI when eligible, measured nocturnal RHR, source-labelled steps, and zone time with its anchor source. Add completed workout counts/durations and recorded strength-session duration only after classifying activities and excluding duplicates/pending sessions. No new metric formula, DB migration, or raw-signal recomputation is needed for this first candidate.

Keep lean mass unavailable. Defer VO₂ max from the core summary; optionally expose an already-stored session estimate with date and an explicit estimate label after its provenance and eligibility are reviewed. Do not invoke a backfill merely to populate this module. Keep numerical health age, age difference, and age-estimate confidence unavailable. Show per-factor data coverage and reasons for missing inputs instead.

Before implementation, settle aggregation windows and valid-day rules against real exports, verify the canonical repository reads and SRI payload contract, and define overlap handling for sessions/imports. Factor coverage must be independent of whether a value is positive. Use local calendar-day helpers for windows and DST boundaries.

### Inspection and validation record

The remote archive search covered 289 `lib/` Dart files; detailed inspection focused on the paths above, plus `lib/data/models.dart`, `lib/data/coverage_resolver.dart` as the named step-resolution seam, `AGENTS.md`, and `pubspec.yaml`. The resolver was located through its call sites; its implementation has not yet been independently reviewed. No changes were made outside the two audit documents.

Located relevant existing tests: `test/vo2max_session_test.dart` (read its setup and the start of its successful-backfill case; documented scenarios include no-route, near-maximal abstention, and write-once behavior), `test/step_source_ladder_test.dart`, `test/phone_step_source_test.dart`, `test/day_zones_one_set_test.dart`, `test/hr_ceiling_zones_test.dart`, `test/db_strength_schema_test.dart`, `test/health_profile_import_test.dart`, and `test/sleep_windows_and_session_avg_test.dart`. Other than the VO₂-max excerpt, these tests were located by path rather than reviewed in depth. Tests were not run; this audit asserts source availability, not runtime correctness.

Extend the proposed real-user pilot with incomplete nights, WHOOP 4.0 band-versus-phone step sources, absent age, changed zone boundaries, missing GPS routes, unlogged strength sessions, and all-missing inputs. Verify no double-counting, no latest-day substitution, and no missing-to-zero conversion. Compare matching source definitions and windows; official WHOOP outputs remain optional comparators rather than ground truth.

