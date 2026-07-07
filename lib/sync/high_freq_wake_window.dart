import 'dart:convert';

import '../data/db.dart';

class HighFreqWakePlan {
  final bool shouldEnable;
  final DateTime? targetWake;
  final String source;
  final int sampleCount;

  const HighFreqWakePlan({
    required this.shouldEnable,
    required this.targetWake,
    required this.source,
    required this.sampleCount,
  });
}

class HighFreqWakeWindow {
  static const Duration lease = Duration(minutes: 90);
  static const int historyDays = 14;
  static const int minSamples = 3;

  static Future<HighFreqWakePlan> planNow([DateTime? now]) async {
    final rows = await LocalDb.recentDayResults(historyDays);
    return planFromRows(rows, now ?? DateTime.now());
  }

  static HighFreqWakePlan planFromRows(
    List<Map<String, dynamic>> rows,
    DateTime now,
  ) {
    final wakeMinutes = <int>[];
    for (final row in rows) {
      final minute = _wakeMinuteOfDay(row);
      if (minute != null) wakeMinutes.add(minute);
    }
    if (wakeMinutes.length < minSamples) {
      return const HighFreqWakePlan(
        shouldEnable: false,
        targetWake: null,
        source: 'insufficient_sleep_history',
        sampleCount: 0,
      );
    }
    wakeMinutes.sort();
    final habitualWakeMinute = wakeMinutes[wakeMinutes.length ~/ 2];
    final todayTarget = DateTime(
      now.year,
      now.month,
      now.day,
      habitualWakeMinute ~/ 60,
      habitualWakeMinute % 60,
    );
    final targetWake = now.isAfter(todayTarget)
        ? todayTarget.add(const Duration(days: 1))
        : todayTarget;
    final windowStart = targetWake.subtract(lease);
    return HighFreqWakePlan(
      shouldEnable: !now.isBefore(windowStart) && now.isBefore(targetWake),
      targetWake: targetWake,
      source: 'habitual_wake',
      sampleCount: wakeMinutes.length,
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
