// SEAM: cloud removed. Implement against openstrap_analytics + db.dart in the local re-layer. See HANDOFF.
//
// LocalRepository is the contract every UI screen consumes. It MIRRORS the old
// ApiClient surface 1:1 (same method names, args, and return shapes — Map / List
// of metric fields) so the screens, the ScreenLoaderMixin, and the AI Coach did
// not have to change their call sites when the cloud transport was excised.
//
// Today every method throws UnimplementedError('re-layer: <method>'). The future
// local re-layer will implement this interface by computing the same payloads from
// `lib/data/db.dart` (the local raw SQLite store) through the pure-Dart
// `openstrap_analytics` package — the exact metric functions the backend used to
// run server-side. The screen DATA layer is therefore a clean, localized seam:
// nothing above this file references HTTP, JWT, or a backend URL anymore.

import '../compute/manual_session.dart' show SessionSpan;
import '../gps/route_models.dart';
import 'journal_fields.dart';

/// The single source of truth for "no step goal configured yet" (8k/day is
/// the commonly-cited optimal benefit/cost ratio for step count). Both the
/// data layer (local_repository_impl.dart's `getProfile()`/`_stepGoal()`,
/// which is where `TodayData.stepGoal` actually gets its default BEFORE any
/// UI-level fallback ever sees a null) and the UI (the steps detail screen's
/// `_StepGoalGauge`, in ui2/screens/metric_detail.dart, seeded from this same
/// constant) must agree — they used to independently default to two different values
/// (10000 here vs. 8000 in the UI), so the UI fallback never actually
/// triggered for real profile data.
const int kDefaultStepGoal = 8000;

/// Replaces the old ApiClient `ApiException`. Screens catch this to show an
/// offline / error state. The re-layer can subclass or throw it directly.
class RepositoryException implements Exception {
  final int status;
  final String body;
  RepositoryException(this.status, this.body);
  @override
  String toString() => 'Repository error $status: $body';
}

/// The local data contract for every insights screen + the AI Coach.
/// Return types mirror the cloud ApiClient exactly (defensive Map/List blobs).
abstract class LocalRepository {
  // ── profile ────────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getProfile() =>
      throw UnimplementedError('re-layer: getProfile');
  Future<Map<String, dynamic>> setStepGoal(int goal) =>
      throw UnimplementedError('re-layer: setStepGoal');

  // ── today / summaries ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getToday() =>
      throw UnimplementedError('re-layer: getToday');

  /// Sleep ONSET/OFFSET for the most recent [days] days, newest first.
  ///
  /// One projected query over `day_result.window_json` — no bundle decode and
  /// no per-day round trip, which is what an actogram (and the circadian
  /// family) needs. The alternative is N separate `getDaySleepV2` calls, each
  /// decoding a full day bundle.
  ///
  /// Rows: `{date: 'YYYY-MM-DD', onset_ts: int?, wake_ts: int?, confidence:
  /// double?, tier: String?}` — epoch SECONDS. A night with no detected sleep
  /// still appears, with null times; the caller decides what an absent night
  /// looks like rather than being handed a silently shorter list.
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60}) =>
      throw UnimplementedError('re-layer: sleepWindows');

  /// Saved sessions in the window, merged with unconfirmed auto-detected bouts.
  ///
  /// Pass `includeDetected: false` when only saved sessions are wanted: the
  /// detected half has to read every recent day bundle to find them, and those
  /// rows carry the full hr_curve/hypnogram/HRV payload.
  Future<List<Map<String, dynamic>>> getSessions({
    int? from,
    int? to,
    bool includeDetected = true,
  }) => throw UnimplementedError('re-layer: getSessions');

  /// Cross-day analytics rollup (illness/anomaly/load/SRI/jetlag/chronotype/
  /// sleep-debt/percentile/glass-box/BRV) — the seam the cross-day screens and
  /// notifications read. Empty map when no rollup has been computed yet.
  Future<Map<String, dynamic>> getInsights() =>
      throw UnimplementedError('re-layer: getInsights');

  // ── day drill-down detail ────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getDaySleepV2(String date) =>
      throw UnimplementedError('re-layer: getDaySleepV2');
  Future<Map<String, dynamic>> getDayStrain(String date) =>
      throw UnimplementedError('re-layer: getDayStrain');

  /// TS-03/04/05 — the observed HR ceiling, the zone edges with the anchors
  /// they were built from, and (only when both anchors were measured) the
  /// 28-day session intensity distribution.
  Future<Map<String, dynamic>> getZones() =>
      throw UnimplementedError('re-layer: getZones');
  Future<Map<String, dynamic>> getDaySleep(String date) =>
      throw UnimplementedError('re-layer: getDaySleep');
  Future<Map<String, dynamic>> getDayTimeline(String date) =>
      throw UnimplementedError('re-layer: getDayTimeline');
  Future<Map<String, dynamic>> getDayStress(String date) =>
      throw UnimplementedError('re-layer: getDayStress');
  Future<Map<String, dynamic>> getDayHeart(String date) =>
      throw UnimplementedError('re-layer: getDayHeart');
  Future<Map<String, dynamic>> getDayLungs(String date) =>
      throw UnimplementedError('re-layer: getDayLungs');
  Future<Map<String, dynamic>> getDayWear(String date) =>
      throw UnimplementedError('re-layer: getDayWear');

  /// [date]'s naps, AFTER the user's own edits have been replayed over the
  /// detector's proposal — the same merged list `nap_min` is summed from, so
  /// the screen and the sleep-need credit cannot disagree about which naps
  /// happened. `{naps: [{start, end, duration_min, source?}], nap_min, note}`,
  /// and an EMPTY map when the day could not be judged at all (which is not
  /// the same as a day with no naps, and reads differently).
  Future<Map<String, dynamic>> getDayNaps(String date) =>
      throw UnimplementedError('re-layer: getDayNaps');
  Future<Map<String, dynamic>> getDayHrv(String date) =>
      throw UnimplementedError('re-layer: getDayHrv');

  /// The individual beat intervals behind [date]'s night — the substrate the
  /// Poincaré plot on Beats is drawn from, artifact-corrected exactly the way
  /// the pipeline corrected them.
  ///
  /// `nn` is the cleaned NN series in ms, in beat order; `rawBeats` is how many
  /// intervals were read before correction, so a screen can state what it threw
  /// away instead of implying the cloud is every beat of the night.
  ///
  /// EMPTY IS THE NORMAL STEADY STATE, not an error. `decoded_rr` is pruned at
  /// `rawRetentionDays` behind the data edge, so the beats exist for the last
  /// few nights and are gone forever after that — while every number computed
  /// FROM them lives in the day bundle for good. A caller must render that as
  /// "the beats are no longer on this phone", never as "no data".
  Future<({List<double> nn, int rawBeats, double cleanFraction})> getNightBeats(
          String date) =>
      throw UnimplementedError('re-layer: getNightBeats');

  /// [date]'s steps as the RESOLVED spans behind them — when each stretch was
  /// counted, by which sensor, and inside which session if any.
  ///
  /// `{total, strap, phone, day_total, day_source, note, spans: [{start_ts,
  /// end_ts, steps, source: 'band'|'phone', activity}]}`, epoch SECONDS.
  ///
  /// The spans are post-ladder (see `resolveDaySteps`), so they sum to `total`
  /// and never show the same walk twice. `day_total`/`day_source` are the
  /// number the day actually published, which is NOT always this sum: with no
  /// span source at all a gen5 day falls back to the strap's on-chip counter,
  /// a whole-day figure with no times behind it and therefore no spans.
  Future<Map<String, dynamic>> getDaySteps(String date) =>
      throw UnimplementedError('re-layer: getDaySteps');

  /// Every day ('YYYY-MM-DD') the lookback screen can actually RENDER — the days
  /// with a genuine derived bundle (`getDayTimeline` returns real data for), not
  /// raw-only or skip-marker days that would render empty — newest first. Bounds
  /// the lookback screen's day navigation (the reachable prev/next days + the
  /// date-picker's selectable days). Empty when nothing has been derived yet.
  Future<List<String>> availableDays() =>
      throw UnimplementedError('re-layer: availableDays');

  // ── trends + records + charts ────────────────────────────────────────────────
  Future<Map<String, dynamic>> getRecords() =>
      throw UnimplementedError('re-layer: getRecords');
  Future<Map<String, dynamic>> getChart(
    String metric, {
    int? from,
    int? to,
    // A string set, not `Set<InputSignal>` — this keeps `lib/data/` free of
    // any dependency on `lib/ble/` (final-plan §5.1). `MetricData.load`
    // passes `{for (final s in spec.requires) s.name}`; an empty set (every
    // existing caller) skips the extra `coverage_recording` query outright.
    Set<String> signals = const {},
  }) =>
      throw UnimplementedError('re-layer: getChart');

  /// ONE DEVICE'S OWN intraday curve for one day, per-minute means, or an empty
  /// point list with the reason it is empty.
  ///
  /// RETENTION-BOUNDED AND SAYS SO. This reads `decoded_onehz`, which prunes at
  /// `rawRetentionDays = 3` (held to `_maxRawHoldDays = 14` for a day that has
  /// not produced a complete result). Outside that window there is nothing to
  /// read and the honest answer is `bounded: true` with `oldest` naming the
  /// edge — never an empty chart with no explanation, and never a per-device
  /// daily trend reconstructed from `metric_series`, which holds ONE MERGED
  /// value per day and has nothing to re-attribute (final-plan §6.4, §7.3).
  ///
  /// Returns `{'points': [{t, v}], 'bounded': bool, 'oldest': 'YYYY-MM-DD'?}`.
  /// `points` is the same `[{t: epochSec, v: num}]` shape `getChart('hr')` and
  /// `getDayTimeline`'s `hr` lane already carry, so `pointsOf` and `dayGraph`
  /// consume it with no new codec.
  Future<Map<String, dynamic>> getDeviceChart(
    String metric, {
    required String deviceId,
    required String date,
  }) =>
      throw UnimplementedError('re-layer: getDeviceChart');

  /// What OTHER sources say about this day, each attributed to whoever said it.
  /// DISPLAY ONLY — see `LocalDb.observationsForDay`.
  Future<List<Map<String, Object?>>> getDayObservations(String date) =>
      throw UnimplementedError('re-layer: getDayObservations');

  // ── workouts (manual / live / auto) ──────────────────────────────────────────
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) =>
      throw UnimplementedError('re-layer: getWorkouts');
  Future<Map<String, dynamic>> getWorkout(String id) =>
      throw UnimplementedError('re-layer: getWorkout');
  Future<void> deleteWorkout(String id) =>
      throw UnimplementedError('re-layer: deleteWorkout');

  /// Mark a session private, or un-mark it. `getWorkout`/`getWorkouts` return
  /// the flag as `private` (bool).
  Future<void> setWorkoutPrivate(String id, bool private) =>
      throw UnimplementedError('re-layer: setWorkoutPrivate');

  /// Re-score recent finished sessions against the 1 Hz substrate now in the
  /// DB, correcting a live session whose in-RAM tallies missed the part of the
  /// workout the app slept through (issue #206). Returns the number of rows
  /// whose strain changed. Best-effort — never throws.
  ///
  /// The default MUST match the implementation's: Dart resolves an omitted
  /// optional from the STATIC receiver type, and every caller holds this
  /// interface — so a different default here is the one that actually runs.
  /// Three days is the raw-retention horizon; nothing older has substrate left
  /// to re-score from.
  Future<int> rescoreRecentSessions({int sinceDays = 3}) =>
      throw UnimplementedError('re-layer: rescoreRecentSessions');
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) =>
      throw UnimplementedError('re-layer: startWorkout');
  Future<Map<String, dynamic>> endWorkout(String workoutId) =>
      throw UnimplementedError('re-layer: endWorkout');

  /// Log a COMPLETED workout the athlete times themselves — one the band never
  /// detected, or detected too narrowly. Scored from the 1 Hz substrate over
  /// [startTs, endTs] (epoch SECONDS); a window with no substrate is still
  /// saved, just unscored. Returns `{workout_id, unscored, hr_samples}`.
  Future<Map<String, dynamic>> logManualWorkout({
    required int startTs,
    required int endTs,
    required String type,
  }) => throw UnimplementedError('re-layer: logManualWorkout');

  /// Retime an existing session and re-score it over the new window. Used to
  /// widen an auto-detected fragment to the real session. Returns
  /// `{workout_id, unscored, hr_samples}`. Throws [StateError] when the id is
  /// unknown or the session is still live, and [ManualWindowException] when
  /// the proposed window is rejected.
  Future<Map<String, dynamic>> setWorkoutWindow(
    String id, {
    required int startTs,
    required int endTs,
  }) => throw UnimplementedError('re-layer: setWorkoutWindow');

  /// Saved session spans (excluding stranded live rows), for the manual-entry
  /// form's overlap check.
  Future<List<SessionSpan>> savedSessionSpans() =>
      throw UnimplementedError('re-layer: savedSessionSpans');
  // GPS route for a run/ride/walk (on-device only). Null when none recorded.
  Future<WorkoutRoute?> getWorkoutRoute(String id) =>
      throw UnimplementedError('re-layer: getWorkoutRoute');

  // ── journal + correlation engine ──────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) =>
      throw UnimplementedError('re-layer: getJournal');
  Future<void> postJournal(String date, List<String> tags, String note) =>
      throw UnimplementedError('re-layer: postJournal');
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
      throw UnimplementedError('re-layer: getJournalInsights');

  /// MIND-12 — does one day of the week actually cost you, on ONE outcome.
  ///
  /// Deliberately one outcome and not four: the omnibus + permutation gate pays
  /// for having looked at seven weekdays, not for having also looked at four
  /// metrics. Empty map when there is nothing to say.
  Future<Map<String, dynamic>> getWeekdayEffect({String key = 'readiness'}) =>
      throw UnimplementedError('re-layer: getWeekdayEffect');

  /// One day's numeric journal fields, keyed by field name.
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) =>
      throw UnimplementedError('re-layer: getJournalMetrics');

  /// Replace one day's numeric fields. A field absent from [fields] is cleared
  /// for that day — the map IS the day, not a patch on it.
  Future<void> postJournalMetrics(
    String date,
    Map<String, JournalMetricValue> fields,
  ) => throw UnimplementedError('re-layer: postJournalMetrics');

  /// Built-in fields followed by the user's own, in editor order.
  Future<List<JournalFieldSpec>> getJournalFields() =>
      throw UnimplementedError('re-layer: getJournalFields');

  Future<void> postCustomJournalField(JournalFieldSpec spec) =>
      throw UnimplementedError('re-layer: postCustomJournalField');

  Future<void> deleteCustomJournalField(String key) =>
      throw UnimplementedError('re-layer: deleteCustomJournalField');

  // ── menstrual cycle ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getCycle() =>
      throw UnimplementedError('re-layer: getCycle');
  Future<void> postCycleLog(
    String date, {
    String kind = 'start',
    String? note,
  }) => throw UnimplementedError('re-layer: postCycleLog');
  Future<void> deleteCycleLog(String date) =>
      throw UnimplementedError('re-layer: deleteCycleLog');
  Future<void> postCycleSymptoms(
    String date,
    List<String> symptoms, {
    String? note,
  }) => throw UnimplementedError('re-layer: postCycleSymptoms');
  Future<Map<String, List<String>>> getCycleSymptoms() =>
      throw UnimplementedError('re-layer: getCycleSymptoms');

  // ── live HRV spot-check ───────────────────────────────────────────────────────
  /// Was POST /spotcheck (decode collected live RR frames → HRV). The re-layer
  /// computes this on-device via openstrap_protocol.realtimeRr + openstrap_analytics.
  Future<Map<String, dynamic>> spotCheck(List<String> records) =>
      throw UnimplementedError('re-layer: spotCheck');

  // ── guided-breathing cardiac coherence ────────────────────────────────────────
  /// Decode live RR frames collected during a guided-breathing session and
  /// compute McCraty & Zayas 2014 cardiac coherence on-device. [pacedHz] is
  /// the guided pacing frequency (e.g. 5.5 breaths/min == 0.0917 Hz).
  Future<Map<String, dynamic>> breathingCoherence(
    List<String> records, {
    double? pacedHz,
  }) => throw UnimplementedError('re-layer: breathingCoherence');
}
