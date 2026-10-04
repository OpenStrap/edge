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

Future<bool> exportContinuousHeartRateDay({
  required List<Map<String, Object?>> rows,
  required DateTime start,
  required DateTime end,
  required bool useAndroidBatch,
  required HealthConnectHeartRateWriter androidWriter,
  required Future<bool> Function(HealthHeartRateSample sample, DateTime end)
  writeGeneric,
  required Future<bool> Function(DateTime from, DateTime to) clearGeneric,
}) async {
  final samples = normalizeHealthHeartRateSamples(rows, start, end);
  if (samples.isEmpty) return true;

  // Replace only from the first minute we still hold. The 1 Hz rows are pruned
  // a few days behind the data edge (not on a day boundary), so a re-export of
  // an older day has lost some or all of its substrate; clearing the whole day
  // would delete minutes from the store that nothing can write back.
  final from = samples.first.time;

  if (useAndroidBatch) {
    // Health Connect holds the day as ONE record, so the window stays the whole
    // day; the native writer carries the earlier minutes over from the record
    // it replaces.
    try {
      return await androidWriter.replaceDay(start, end, samples);
    } catch (_) {
      return false;
    }
  }

  if (!await clearGeneric(from, end)) return false;
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
