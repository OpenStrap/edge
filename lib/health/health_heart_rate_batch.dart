import 'package:flutter/services.dart';

class HealthHeartRateSample {
  const HealthHeartRateSample(this.time, this.beatsPerMinute);

  final DateTime time;
  final int beatsPerMinute;

  Map<String, Object> toMap() => {
    'time': time.millisecondsSinceEpoch,
    'beatsPerMinute': beatsPerMinute,
  };

  @override
  bool operator ==(Object other) =>
      other is HealthHeartRateSample &&
      time == other.time &&
      beatsPerMinute == other.beatsPerMinute;

  @override
  int get hashCode => Object.hash(time, beatsPerMinute);
}

abstract interface class HealthConnectHeartRateWriter {
  Future<bool> replaceDay(
    DateTime start,
    DateTime end,
    List<HealthHeartRateSample> samples,
  );
}

class MethodChannelHealthConnectHeartRateWriter
    implements HealthConnectHeartRateWriter {
  MethodChannelHealthConnectHeartRateWriter({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('openstrap/health_connect_heart_rate');

  final MethodChannel _channel;

  @override
  Future<bool> replaceDay(
    DateTime start,
    DateTime end,
    List<HealthHeartRateSample> samples,
  ) async {
    final wrote = await _channel.invokeMethod<bool>('replaceHeartRateDay', {
      'startTime': start.millisecondsSinceEpoch,
      'endTime': end.millisecondsSinceEpoch,
      'samples': samples.map((sample) => sample.toMap()).toList(),
    });
    return wrote == true;
  }
}

List<HealthHeartRateSample> normalizeHealthHeartRateSamples(
  List<Map<String, Object?>> rows,
  DateTime start,
  DateTime end,
) {
  final samples = <({HealthHeartRateSample sample, int index})>[];
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final seconds = (row['minute_ts'] as num?)?.toInt();
    final bpm = (row['avg_hr'] as num?)?.toInt();
    if (seconds == null || bpm == null || bpm < 1 || bpm > 300) continue;
    final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    if (time.isBefore(start) || !time.isBefore(end)) continue;
    samples.add((sample: HealthHeartRateSample(time, bpm), index: index));
  }
  samples.sort((left, right) {
    final timeOrder = left.sample.time.compareTo(right.sample.time);
    return timeOrder != 0 ? timeOrder : left.index.compareTo(right.index);
  });

  final unique = <HealthHeartRateSample>[];
  DateTime? previousTime;
  for (final entry in samples) {
    if (entry.sample.time == previousTime) continue;
    unique.add(entry.sample);
    previousTime = entry.sample.time;
  }
  return unique;
}

/// Where a day's minute-HR rewrite starts: its first sample, or null when
/// there is none. The decoded rows behind it are pruned mid-day, so anything
/// earlier was written from rows that are gone and must be left alone.
DateTime? healthHeartRateRewriteFrom(List<HealthHeartRateSample> samples) =>
    samples.isEmpty ? null : samples.first.time;

Future<bool> exportContinuousHeartRateDay({
  required List<Map<String, Object?>> rows,
  required DateTime start,
  required DateTime end,
  required bool useAndroidBatch,
  required HealthConnectHeartRateWriter androidWriter,
  DateTime? prunedBefore,
  required Future<bool> Function(HealthHeartRateSample sample, DateTime end)
  writeGeneric,
}) async {
  final samples = normalizeHealthHeartRateSamples(rows, start, end);
  if (samples.isEmpty) return true;

  if (useAndroidBatch) {
    // Health Connect holds the day as ONE record starting at [start], and a
    // range delete matches records by start time. The replace has to start
    // at [start] too, or it misses the old record and the day goes in twice.
    // A record can't be cut, so a day whose decoded rows were partly pruned
    // ([prunedBefore] past [start]) keeps the record written while they
    // still existed rather than being replaced by the part that's left.
    if (prunedBefore != null && prunedBefore.isAfter(start)) return true;
    try {
      return await androidWriter.replaceDay(start, end, samples);
    } catch (_) {
      return false;
    }
  }

  var success = true;
  for (final sample in samples) {
    try {
      if (!await writeGeneric(
        sample,
        sample.time.add(const Duration(minutes: 1)),
      )) {
        success = false;
      }
    } catch (_) {
      success = false;
    }
  }
  return success;
}
