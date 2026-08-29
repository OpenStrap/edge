# AGENTS.md — OpenStrap `edge`

Reviewer context. This doc drifts from code between edits — check
`kAlgoVersion` (`lib/compute/derivation_engine.dart`), `schemaVersion`
(`lib/data/db.dart`), and the `version:` line in `pubspec.yaml` directly
rather than trusting a number written here. Where a source comment disagrees
with an implementation, **the implementation wins** — header comments here go
stale (e.g. `lib/compute/substrate.dart`'s file header still describes a
wake-to-wake day model that `calendarDays()` no longer implements; it walks
local midnight to local midnight). The same drift applies to §2's table and
every line-number citation in §3 below — line numbers move on every edit,
symbol names don't; verify against the source, not this doc.

## 1. What this is

A Flutter app for a reverse-engineered WHOOP 4.0 band. **Fully on-device,
local-first**: BLE offload → SQLite → on-device analytics → UI. No backend owns
user data. Network use is limited to OTA update pointers, opt-in
telemetry/Crashlytics, and BYOK LLM calls.

Three sibling repos, strict separation — push work to the right one:
- `OpenStrap/protocol` — bytes: GATT, framing, CRC, opcodes, record decode.
- `OpenStrap/analytics` — metrics: HRV, sleep staging, readiness, strain.
- `OpenStrap/edge` (**this repo**) — flows, BLE link management, storage, UI.

New opcode/record → protocol. New metric → analytics. New screen/flow/table →
edge. A PR implementing a metric inside `edge/lib/compute` is in the wrong repo
unless it is pure orchestration.

## 2. Architecture map (`lib/`, well over 200 files — these five are the biggest by far)

Line counts drift constantly; don't trust a number here, `wc -l` the file.

| file | owns |
|---|---|
| `data/db.dart` | `LocalDb`: schema ladder (`onUpgrade`), all CRUD, coach views |
| `compute/derivation_engine.dart` | `DerivationEngine`, `kAlgoVersion`, day scheduling, isolate offload |
| `state/app_state.dart` | `AppState` ChangeNotifier — BLE↔DB↔UI orchestration |
| `ble/ble_engine.dart` | GATT connect/drain/history-sync state machine |
| `data/local_repository_impl.dart` | read seam: `day_result`/`metric_series` → screen shapes; zero compute on read |

- `ble/` — engine + `ble_state.dart` **pure policies**: `ReconnectPolicy`,
  `SeqAllocator`, `DrainStopEvaluator`, `RecordGate`, `CounterRegressionDetector`,
  `AckRetryPolicy`, `ChunkFailureLedger`, `DeriveDebouncer`, `AlarmPayloads`,
  `AlarmConfirmation`.
- `sync/` — `sync_policy.dart` **pure policies**: `ClockRef`/`ClockPolicy`,
  `BackfillPolicy`, `MarginalRadioDetector`, `FrameCorruptionDetector`,
  `PostBondTimeoutLoopDetector`, `BondRefusalGiveUp`, `EmptySyncTracker`,
  `StuckStrapDetector`; plus background/headless entries and OTA.
- `compute/` — `substrate.dart` (**single** raw→`Substrate` decode point +
  `calendarDays()` day model), `onehz_pipeline.dart` (pure, isolate-safe per-day
  pipeline), `crossday_pipeline.dart`, `derivation_engine.dart`.
- `data/` — `db.dart`, read seam, `day_label.dart` (the *only* day-label helper).
- `notify/` — `notification_center.dart` is the **single emitter**;
  `fired_keys.dart` is the persistent fire-once guard.
- `coach/` — read-only SQL over allow-listed `v_*` views behind a deny-list guard.
- `ui2/` — 66 files (`lib/ui` was deleted in the UI rebuild): `ui2/theme.dart`
  and `ui2/grammar.dart` (design system), `ui2/charts.dart`, `ui2/screens/`
  (shared metric/trend IA), plus `ui2/onboarding/`, `ui2/activity/`,
  `ui2/profile/`.
- Also `ai/` (BYOK), `gps/`, `health/` (HealthKit/Health Connect export),
  `telemetry/` (opt-in), `widget/` (App-Group snapshot for WidgetKit/watch).

**Storage.** Durable ledger: `decoded_onehz` (1 Hz, `UNIQUE(rec_ts)`,
INSERT-OR-REPLACE) + `decoded_rr` (beats, cascades on eviction) + `raw_archive`
(never pruned; undecodable/unknown-version records) + `raw_records` (retained as
replay/debug ledger and upgrade fallback) + `events`/`band_events`. Derived
output: versioned **immutable** `day_result` (PK `day_id, algo_version`) and
`metric_series` (PK `date,key`, REPLACE).

**Bug-density hotspots** (fix-titled commit churn, last 300 commits):
`state/app_state.dart` 30 · `data/db.dart` 25 · `compute/derivation_engine.dart`
24 · `data/local_repository_impl.dart` 17 · `ble/ble_engine.dart` 12 ·
`main.dart`+`app.dart` 19. Treat diffs in these with extra scrutiny.
`pubspec.yaml` has high raw churn but most of it is release version bumps — not
a hotspot.

## 3. Hard invariants — violating these is a P0 regression

1. **Commit before ACK.** In the history-sync drain (`ble/ble_engine.dart`)
   decoded rows + cursor commit in one transaction *before*
   `buildHistoryResultOk` echoes the verbatim 8-byte HISTORY_END token. The band
   trims flash on ACK. Reordering, or echoing a regenerated/mangled token, causes
   permanent data loss or an infinite re-flood. Never ACK a partial chunk.
2. **`decoded_onehz` stays INSERT-OR-REPLACE keyed on `rec_ts`.** INSERT-OR-IGNORE
   breaks counter-reset recovery. Evicting a row must delete that counter's
   `decoded_rr` beats in the same batch.
3. **Never fabricate a metric.** Absent input ⇒ null / `Metric.absent` / "—". No
   imputation, no substituted defaults, no deriving one metric from another as a
   fallback. Most-violated rule in the repo (§4.1).
4. **Bump `kAlgoVersion`** (`compute/derivation_engine.dart`) whenever any
   analytics *output* changes, including via a sibling re-pin. Rows are immutable
   per version; without a bump nothing recomputes. Add a changelog entry above
   the constant.
5. **A bump citing a sibling change must be backed by the pin.** Verify the SHA
   in `pubspec.yaml` actually contains the cited change. v43's changelog
   described an analytics fix its pin never contained; the bug stayed live three
   releases and only shipped at v46.
6. **Siblings pinned to full commit SHAs, never branch refs.** `ref: main` on
   analytics shipped main-thread ANRs into 0.9.13/0.9.14.
7. **Day labels are LOCAL.** Always `todayLabel()` / `dayLabelOf()` from
   `data/day_label.dart`; never `DateTime.now().toUtc()...substring(0,10)`. Epoch
   timestamps (rec_ts, session bounds, prune cutoffs) are absolute — do not
   "fix" those to local. Day-length arithmetic must not assume 86400 s (DST).
8. **One source per concern.** One raw decode point (`substrate.dart`), one sleep
   segmentation, one readiness, one frame-ingest path (`RecordGate`), one
   notification emitter (`NotificationCenter.emit`). A second path is the bug.
9. **Never prune raw/decoded for a day that is not fully derived.** `day_result`
   has a `partial` column because days with good headline scalars but a failed
   second-half compute were finalized and pruned — unrecoverable. `raw_archive`
   is never pruned.
10. **Heavy compute never on the UI isolate.** Staging/derivation goes through
    `Isolate.run`; analytics ambient globals do not cross the boundary and must
    be re-armed inside the closure.
11. **Migrations additive and idempotent.** `onUpgrade` is a sequential
    `if (oldV < N)` ladder; `onOpen`'s `_repairOpenSchema` re-runs creators so
    same-version merged builds self-heal. Migrations run inside `openDatabase`
    under iOS's CPU watchdog — keep them cheap. `PRAGMA journal_mode=WAL` must go
    through `rawQuery` (it returns a row; `execute` bricks iOS Darwin sqflite).
12. **Headless/background sync serializes through `HeadlessSyncGate.tryRun`** —
    skip, don't queue.
13. **The coach reads only allow-listed `v_*` views** — never `decoded_*`,
    `raw_*`, or base tables.
14. **Live high-rate streams (0x28/0x2B/0x33) are never persisted** — RAM-only.
15. **Dangerous opcodes are never auto-sent** (`dangerousCmds`, gated in
    `ble/ble_engine.dart` wherever a write checks it): force-trim, reboot,
    power-cycle, firmware load.

## 4. Recurring bug patterns — what actually ships broken here

### 4.1 Fabricated / non-abstaining metrics ("honesty" violations)
The project has an explicit never-impute rule and keeps breaking it. Instances:
two copies of a `100 - readiness` stress fallback; RHR falling back to daytime HR
("Readiness 100" ten minutes after first wear); literal `"null"` rendered for
oxygen dips; a skin-temp section gated on `spo2` presence; `StageBars` drawing an
*invisible gap* for an absent sleep stage; pace showing absurd numbers instead of
"—"; a false empty state instead of a retryable error; Bluetooth-off reported as
"no strap found". One is still open: stress shows a confident score on ~20 min of
data.
**Ask on any metric diff:** what does this return when the input is missing or
thin? Anything other than null/"—"/an honest low-confidence envelope is a bug.

### 4.2 Readiness / recompute-idempotence — the largest single cluster
Eight distinct fixes and four sequential attempts at one user-visible symptom.
Readiness recomputes on *every* BLE drain against a moving 28-day baseline, so
any non-idempotent step corrupts it: duplicate-day appends into the baseline
(MAD == 0 ⇒ robust z abstains ⇒ blank ring), rebuilding on persist but not on
read, withholding a score while the overnight builds but not preventing a
ready→ready drift, flashing a stale value before today settles, and saturation
bouncing the ring to 100.
**Ask:** if this runs three more times today with slightly more data, does the
persisted scalar stay stable? Does it append where it should replace?
**Footgun:** `LocalDb.metricSeries(limit: n)` is `ORDER BY date ASC LIMIT n` =
the **oldest** n. For a trailing window use `trailingSeriesValues(key, n)`.

### 4.3 Sticky boolean latches never reset on the failure path
Self-identified as recurring in the repo's own commit messages ("same shape as
the foregroundActive bug from a couple days ago"). A flag is set, an error path
returns early without clearing it, and sync wedges until force-close. Known
instances: `foregroundActive`, `markForegroundIntent`, `_offloadActive`,
`_drainingOffloadFrames` (no `try/finally`), a sticky standard-HR fallback that
silently zeroed step calibration, and trusting a stale `isConnected`.
**Ask:** every flag set in this diff — is it cleared in `finally`, on timeout, and
on the give-up branch?

### 4.4 Heavy compute on the main/UI isolate → ANR, jank, stuck launch
Recurred one build apart: `cardioStager`'s per-30s Lomb–Scargle on the main
isolate (Android ANRs every ~30 s), then the *entire second half* of
`_derivePreparedDay` running on the UI isolate for the foreground pass that fires
on every sync. Also: app freezing during backfills, unbounded pre-`runApp` inits
stalling launch, a dark-mode rebuild storm starving background BLE.

### 4.5 `context` / Provider used after `await` or after unmount
Repeated crash source: `Provider._inheritedElementOf` null in `dispose`,
`context.read` in `dispose`, bare `Navigator.pop()` after an `await`, missing
`mounted` guard on a post-navigation reload.

### 4.6 Notification re-fire, dedupe race, and gating bypass
Call sites promised "at most once per day" with nothing enforcing it, so
derivation re-runs re-fired them across illness, anomaly, temperature, readiness,
HR-shift, recovery-ready, step-goal and auto-workout alerts. Then the stress
screen called `NotificationService.presentEvent` **directly**, bypassing both the
prefs gate and the new dedupe guard. Then a TOCTOU race let two overlapping
`emit()`s both pass `hasFired`.
**Flag:** any direct call into `NotificationService` that skips
`NotificationCenter.emit`, and any check-then-record without the lock.

### 4.7 Capability wired into one call path but not all N
The most damaging instance: `FirmwareAwareR24Decoder` existed but was not wired
into all three decode paths (`ble_engine.dart`, `db.dart`, `substrate.dart`), so
a real user's 88-byte v12 records were 100% silently archived — total sync
outage. Also: HealthKit export gated on `day_result` and never session-triggered
(a workout finished offline never exported); auto-detected workouts never
reaching the `sessions` table, invisible to both AI Coach and Health export.
**Ask:** how many call sites exist for this concern, and does the diff cover all
of them?

### 4.8 UTC-vs-local and day-boundary math
Fixed, then reintroduced *in the same file* (SRI's hypnogram grid used raw UTC
time-of-day right below the fix for that exact mistake), then again in the
`v_sessions` view (AI Coach mis-dated workouts). Also: day math assuming 86400 s
breaking on DST, a briefing greeting "morning" in the afternoon, sleep not
detected in non-UTC timezones, and an alarm armed in the phone's clock frame
instead of the strap's RTC frame so it never fired.

### 4.9 Dependency pinning / lockfile / release metadata
Four separate passes. Committed path `dependency_overrides` broke a release;
`pubspec.lock` resolved a package via a stale local path; floating `ref: main`
rode analytics v42 into 0.9.13; a PR bumped `kAlgoVersion` while the lock still
pinned the pre-fix analytics commit, requiring a manual merge-order gate; and
`0.9.17+1` shipped versionCode 1 → `INSTALL_FAILED_VERSION_DOWNGRADE`, making
the release uninstallable.
`pubspec_overrides.yaml` redirects siblings to `../analytics` / `../protocol` and
is gitignored — committing a path override fails CI `flutter pub get` (exit 66).
Note the tracked `pubspec.lock` currently records `source: path` for both
siblings, so it provides **no** pin guarantee; `pubspec.yaml` is the source of
truth. `version:` must always keep its `+BUILD` suffix, and the iOS widget/watch
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` are bumped manually and drift.

### 4.10 Duplicated / inconsistent values across screens
Today showed strain/sleep/stress twice; a week-load wheel duplicated the strain
figure; the steps figure disagreed across screens through three separate
unification attempts and is still being fixed; two different HRV baselines both
labeled "baseline" on one screen.

### 4.11 Chart / hypnogram render regressions
`Hypnogram.plot` lost its `RepaintBoundary` in a refactor and stayed lost through
three rewrites before being restored. Also recap scrub-marker misalignment,
`GanttPainter` needing restoration, and `RangeError` from unpadded substrate
fields. Rendering regressions here surface as test failures rather than obvious
visual bugs — check whether removed wrapper widgets were load-bearing.

## 5. How to review this repo

**CI does run on PRs.** `.github/workflows/test.yml` runs `flutter analyze` +
`flutter test` on every pull request and on push to `main`.
`.github/workflows/build.yml` (the APK/IPA release) is the one gated to
`push: tags: ['v*']` — it doesn't touch PRs. `test/` is large and not flat
(it has `adapters/`, `support/`, and other subdirectories alongside the
top-level test files). Several regression tests are named for the bug they pin
(`readiness_flash_test`, `readiness_freeze_test`, `readiness_saturation_test`,
`readiness_baseline_pollution_test`). A behavior change with no accompanying
test is a real finding — CI passing doesn't mean the right test exists.

`analysis_options.yaml` is stock `flutter_lints`: no custom rules, no excludes,
no strict language modes.

**Deprioritize:** formatting, import ordering, naming style, `const`
constructors, string-interpolation preference, missing dartdoc, "extract a
widget", and general Flutter/Dart idiom advice not tied to a behavior change.

**Prioritize:** the invariants in §3, the patterns in §4, absent-input handling on
every metric path, idempotence under repeated derivation, flag reset on failure
paths, transaction ordering and durability around BLE sync, isolate boundaries,
migration safety, and anything that could display a number the data does not
support.
