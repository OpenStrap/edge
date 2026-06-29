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
  Future<Map<String, dynamic>> patchProfile(Map<String, dynamic> fields) =>
      throw UnimplementedError('re-layer: patchProfile');
  Future<Map<String, dynamic>> setStepGoal(int goal) =>
      throw UnimplementedError('re-layer: setStepGoal');

  // ── today / summaries ────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getToday() =>
      throw UnimplementedError('re-layer: getToday');
  Future<List<Map<String, dynamic>>> getSleep({int? from, int? to}) =>
      throw UnimplementedError('re-layer: getSleep');
  Future<List<Map<String, dynamic>>> getStrain({int? from, int? to}) =>
      throw UnimplementedError('re-layer: getStrain');
  Future<List<Map<String, dynamic>>> getSessions({int? from, int? to}) =>
      throw UnimplementedError('re-layer: getSessions');
  Future<Map<String, dynamic>> getHistory({String range = '30d'}) =>
      throw UnimplementedError('re-layer: getHistory');

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
  Future<Map<String, dynamic>> getDayHrv(String date) =>
      throw UnimplementedError('re-layer: getDayHrv');

  // ── trends + records + charts ────────────────────────────────────────────────
  Future<Map<String, dynamic>> getTrend(String metric,
          {String scale = 'week', String? anchor}) =>
      throw UnimplementedError('re-layer: getTrend');
  Future<Map<String, dynamic>> getRecords() =>
      throw UnimplementedError('re-layer: getRecords');
  Future<Map<String, dynamic>> getChart(String metric, {int? from, int? to}) =>
      throw UnimplementedError('re-layer: getChart');

  // ── workouts (manual / live / auto) ──────────────────────────────────────────
  Future<Map<String, dynamic>> getWorkouts({String range = 'month'}) =>
      throw UnimplementedError('re-layer: getWorkouts');
  Future<Map<String, dynamic>> getWorkout(String id) =>
      throw UnimplementedError('re-layer: getWorkout');
  Future<void> deleteWorkout(String id) =>
      throw UnimplementedError('re-layer: deleteWorkout');
  Future<Map<String, dynamic>> startWorkout(String type, {String? title}) =>
      throw UnimplementedError('re-layer: startWorkout');
  Future<Map<String, dynamic>> endWorkout(String workoutId) =>
      throw UnimplementedError('re-layer: endWorkout');
  Future<Map<String, dynamic>> setWorkoutType(String id, String type) =>
      throw UnimplementedError('re-layer: setWorkoutType');

  // ── journal + correlation engine ──────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) =>
      throw UnimplementedError('re-layer: getJournal');
  Future<void> postJournal(String date, List<String> tags, String note) =>
      throw UnimplementedError('re-layer: postJournal');
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
      throw UnimplementedError('re-layer: getJournalInsights');

  // ── menstrual cycle ────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getCycle() =>
      throw UnimplementedError('re-layer: getCycle');
  Future<void> postCycleLog(String date, {String kind = 'start', String? note}) =>
      throw UnimplementedError('re-layer: postCycleLog');
  Future<void> deleteCycleLog(String date) =>
      throw UnimplementedError('re-layer: deleteCycleLog');
  Future<void> postCycleSymptoms(String date, List<String> symptoms,
          {String? note}) =>
      throw UnimplementedError('re-layer: postCycleSymptoms');
  Future<Map<String, List<String>>> getCycleSymptoms() =>
      throw UnimplementedError('re-layer: getCycleSymptoms');

  // ── notifications feed ──────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> getNotifications() =>
      throw UnimplementedError('re-layer: getNotifications');
  Future<void> markNotificationsRead({List<String>? ids}) =>
      throw UnimplementedError('re-layer: markNotificationsRead');

  // ── live HRV spot-check ───────────────────────────────────────────────────────
  /// Was POST /spotcheck (decode collected live RR frames → HRV). The re-layer
  /// computes this on-device via openstrap_protocol.realtimeRr + openstrap_analytics.
  Future<Map<String, dynamic>> spotCheck(List<String> records) =>
      throw UnimplementedError('re-layer: spotCheck');
}
