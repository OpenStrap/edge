import 'dart:convert';

import '../data/db.dart';

class HighFreqWakePlan {
  final bool shouldEnable;
  final DateTime? targetWake;
  final String source;
  final int sampleCount;

  /// Time at which the band prompt lease should start — [preSyncLead] before
  /// the smart-wake window opens — so the app wakes periodically and backfills
  /// `decoded_onehz` with the last ~3h of nocturnal data before the window
  /// opens. The smart-wake DETECTION still only runs inside the actual window
  /// (checked by `inSmartWakeWindow` in `_checkSmartWake`); this only extends
  /// the DATA COLLECTION lease, not the buzz window.
  ///
  /// When the plan is disabled (outside the extended lease), this is null.
  final DateTime? preSyncAt;

  /// The total duration the band prompt lease should cover: from [preSyncAt]
  /// (when set) or the window start, until [targetWake]. Used by callers to
  /// compute the lease duration for `BandPromptRequest.smartWake`.
  Duration? get effectiveLease {
    if (targetWake == null) return null;
    final start = preSyncAt ?? targetWake!.subtract(lease);
    return targetWake!.difference(start);
  }

  const HighFreqWakePlan({
    required this.shouldEnable,
    required this.targetWake,
    required this.source,
    required this.sampleCount,
    this.preSyncAt,
  });
}

class HighFreqWakeWindow {
  static const Duration lease = Duration(minutes: 90);

  /// Extra time the band prompt lease extends BEFORE the smart-wake window
  /// opens, so the app wakes periodically and backfills `decoded_onehz` with
  /// the last ~3h of nocturnal data. Without this, the 10th-percentile HR
  /// baseline (smart_wake v2, Q2) has no data to compute from when the window
  /// opens — the band was offline or the app was suspended all night.
  ///
  /// The band prompt is the ONLY reliable cross-platform wake mechanism at a
  /// specific wall-clock time (iOS BGTask/BGAppRefresh are opportunistic and
  /// never guaranteed; Android has no periodic background scheduler since the
  /// WorkManager tombstone). Extending the existing 61s prompt lease 45 min
  /// earlier costs ~45 extra BLE wake cycles per night — negligible battery
  /// impact, and it reuses infrastructure that already works.
  ///
  /// preSyncAt = targetWake − (lease + preSyncLead).
  static const Duration preSyncLead = Duration(minutes: 45);

  static const int historyDays = 14;
  static const int minSamples = 3;

  /// [scheduledWindowEnd]/[scheduledWindowMinutes] are the currently-armed
  /// alarm's smart-wake window (see `alarm_schedule.armedSmartWakeWindow`),
  /// when known. They widen the lease to also cover an alarm set well before
  /// the habitual wake — e.g. a 05:30 alarm on a 07:30-habitual-wake person —
  /// which the habitual-only window used to miss entirely, starving
  /// `_checkSmartWake`'s "last 3 minutes" query of fresh `decoded_onehz` rows
  /// for the whole real window. Omitting them (every existing call site that
  /// hasn't been updated) keeps today's habitual-only behaviour byte-for-byte.
  static Future<HighFreqWakePlan> planNow({
    DateTime? now,
    DateTime? scheduledWindowEnd,
    int scheduledWindowMinutes = 0,
  }) async {
    final rows = await LocalDb.recentDayResults(historyDays);
    return planFromRows(
      rows,
      now ?? DateTime.now(),
      scheduledWindowEnd: scheduledWindowEnd,
      scheduledWindowMinutes: scheduledWindowMinutes,
    );
  }

  static HighFreqWakePlan planFromRows(
    List<Map<String, dynamic>> rows,
    DateTime now, {
    DateTime? scheduledWindowEnd,
    int scheduledWindowMinutes = 0,
  }) {
    final wakeMinutes = <int>[];
    for (final row in rows) {
      final minute = _wakeMinuteOfDay(row);
      if (minute != null) wakeMinutes.add(minute);
    }

    HighFreqWakePlan? habitualPlan;
    if (wakeMinutes.length >= minSamples) {
      wakeMinutes.sort();
      final habitualWakeMinute = wakeMinutes[wakeMinutes.length ~/ 2];
      final todayTarget = DateTime(
        now.year,
        now.month,
        now.day,
        habitualWakeMinute ~/ 60,
        habitualWakeMinute % 60,
      );
      // Calendar arithmetic, not a Duration(days: 1) add — that's exactly 24
      // elapsed hours, which lands an hour off across a DST transition.
      final targetWake = now.isAfter(todayTarget)
          ? DateTime(
              now.year,
              now.month,
              now.day + 1,
              habitualWakeMinute ~/ 60,
              habitualWakeMinute % 60,
            )
          : todayTarget;
      final windowStart = targetWake.subtract(lease);
      // Pre-sync lead: extend the band prompt lease 45 min before the window
      // opens so the app wakes periodically and backfills decoded_onehz with
      // the last ~3h of nocturnal data. The smart-wake DETECTION still only
      // runs inside the actual window (inSmartWakeWindow check in
      // _checkSmartWake); this only extends the DATA COLLECTION lease.
      final preSyncAt = targetWake.subtract(lease + preSyncLead);
      // shouldEnable covers the FULL extended lease (preSyncAt → targetWake),
      // not just the smart-wake window. The band prompts continuously; each
      // prompt triggers _startHistoricalRefresh() which fills decoded_onehz.
      habitualPlan = HighFreqWakePlan(
        shouldEnable: !now.isBefore(preSyncAt) && now.isBefore(targetWake),
        targetWake: targetWake,
        source: 'habitual_wake',
        sampleCount: wakeMinutes.length,
        preSyncAt: preSyncAt,
      );
    }

    // The scheduled-alarm window only takes over when the habitual window
    // isn't already covering `now` — habitual stays the reported source
    // whenever it alone would enable, matching pre-existing behaviour.
    if (scheduledWindowEnd != null &&
        scheduledWindowMinutes > 0 &&
        habitualPlan?.shouldEnable != true) {
      final scheduledStart = scheduledWindowEnd.subtract(lease);
      final preSyncAt = scheduledWindowEnd.subtract(lease + preSyncLead);
      if (!now.isBefore(preSyncAt) && now.isBefore(scheduledWindowEnd)) {
        return HighFreqWakePlan(
          shouldEnable: true,
          targetWake: scheduledWindowEnd,
          source: 'scheduled_alarm',
          sampleCount: wakeMinutes.length,
          preSyncAt: preSyncAt,
        );
      }
    }

    return habitualPlan ??
        const HighFreqWakePlan(
          shouldEnable: false,
          targetWake: null,
          source: 'insufficient_sleep_history',
          sampleCount: 0,
        );
  }

  static int? _wakeMinuteOfDay(Map<String, dynamic> row) {
    final win = _decodeMap(row['window_json']);
    final payload = _decodeMap(row['payload_json']);
    final winValue = _asMap(win['value']);
    final sleep = _asMap(payload['sleep']);
    final sleepWindow = _asMap(sleep['window']);
    final sleepWindowValue = _asMap(sleepWindow['value']);
    final offsetMs =
        (winValue['offset_ms'] as num?)?.toInt() ??
        (sleepWindowValue['offset_ms'] as num?)?.toInt();
    if (offsetMs == null || offsetMs <= 0) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(offsetMs);
    return dt.hour * 60 + dt.minute;
  }

  static Map<String, dynamic> _decodeMap(Object? raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    if (raw is! String || raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (_) {}
    return const <String, dynamic>{};
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map) return raw.cast<String, dynamic>();
    return const <String, dynamic>{};
  }
}
