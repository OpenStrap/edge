import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/health/health_heartbeat_series.dart';

final _sleepStart = DateTime(2026, 8, 5, 0, 0);
final _sleepEnd = DateTime(2026, 8, 5, 7, 0);

/// A steady beat train: [count] beats of [rrMs] each, the first ending
/// [startOffsetMs] after sleep onset.
({List<num> rr, List<num> ts}) _steady(
  int count, {
  int rrMs = 1000,
  int startOffsetMs = 1000,
}) {
  final t0 = _sleepStart.millisecondsSinceEpoch + startOffsetMs;
  return (
    rr: List<num>.filled(count, rrMs),
    ts: [for (var i = 0; i < count; i++) t0 + i * rrMs],
  );
}

List<int> _instants(List<HealthHeartbeatSeries> series) => [
  for (final s in series)
    for (final o in s.offsetsMs) s.start.millisecondsSinceEpoch + o,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildSleepHeartbeatSeries', () {
    test('a contiguous run exports every beat with no gaps inside it', () {
      final beats = _steady(120);
      final series = buildSleepHeartbeatSeries(
        rrMs: beats.rr,
        rrTsMs: beats.ts,
        sleepStart: _sleepStart,
        sleepEnd: _sleepEnd,
      );
      expect(series, hasLength(1));
      final s = series.single;
      expect(s.beats, 120);
      expect(s.offsetsMs.first, 0);
      expect(s.precededByGap.first, isFalse);
      expect(s.precededByGap.skip(1), everyElement(isFalse));
      // Successive instants ARE the measured intervals.
      for (var i = 1; i < s.beats; i++) {
        expect(s.offsetsMs[i] - s.offsetsMs[i - 1], 1000);
      }
      expect(_instants(series), beats.ts);
    });

    test('a sensor dropout re-anchors and flags the first beat after it', () {
      final before = _steady(60);
      // 30 s with no beats reported, then the train resumes.
      final after = _steady(60, startOffsetMs: 1000 + 60 * 1000 + 30 * 1000);
      final series = buildSleepHeartbeatSeries(
        rrMs: [...before.rr, ...after.rr],
        rrTsMs: [...before.ts, ...after.ts],
        sleepStart: _sleepStart,
        sleepEnd: _sleepEnd,
      );
      expect(series, hasLength(1));
      final s = series.single;
      expect(s.beats, 120);
      // The resumed beat sits at its real time, not spliced onto the first run.
      expect(s.offsetsMs[60] - s.offsetsMs[59], 31000);
      expect(s.precededByGap[60], isTrue);
      expect(
        [
          for (var i = 0; i < s.beats; i++)
            if (s.precededByGap[i]) i,
        ],
        [60],
      );
    });

    test('a missed beat keeps its real instant and is flagged, never '
        'interpolated', () {
      final t0 = _sleepStart.millisecondsSinceEpoch + 1000;
      final rr = <num>[];
      final ts = <num>[];
      var t = t0;
      for (var i = 0; i < 120; i++) {
        // Beat 60's detection was missed: one 2000 ms interval stands in for
        // two 1000 ms ones.
        final interval = i == 60 ? 2000 : 1000;
        if (i > 0) t += interval;
        rr.add(interval);
        ts.add(t);
      }
      final series = buildSleepHeartbeatSeries(
        rrMs: rr,
        rrTsMs: ts,
        sleepStart: _sleepStart,
        sleepEnd: _sleepEnd,
      );
      final instants = _instants(series);
      // Every exported instant is one the band reported; no beat is invented
      // in the middle of the 2000 ms hole.
      expect(instants.toSet().difference(ts.toSet()), isEmpty);
      final s = series.single;
      final idx = s.offsetsMs.indexOf(ts[60].toInt() - ts[0].toInt());
      expect(idx, greaterThan(0));
      expect(s.precededByGap[idx], isTrue);
      // The beat after it is an ordinary 1000 ms pair again.
      expect(s.precededByGap[idx + 1], isFalse);
    });

    test(
      'an implausible interval is dropped and the beat after it flagged',
      () {
        final t0 = _sleepStart.millisecondsSinceEpoch + 1000;
        final rr = <num>[];
        final ts = <num>[];
        var t = t0;
        for (var i = 0; i < 60; i++) {
          // Beat 30 reports 3000 ms: past kMaxPlausibleRrMs, so not a beat
          // interval the derive path would keep either.
          final interval = i == 30 ? 3000 : 1000;
          if (i > 0) t += interval;
          rr.add(interval);
          ts.add(t);
        }
        final series = buildSleepHeartbeatSeries(
          rrMs: rr,
          rrTsMs: ts,
          sleepStart: _sleepStart,
          sleepEnd: _sleepEnd,
        );
        final s = series.single;
        expect(_instants(series), isNot(contains(ts[30])));
        expect(s.beats, 59);
        // Beat 31 is placed at its own reported time, and the pair 29 -> 31 is
        // not an interval anyone measured.
        expect(_instants(series)[30], ts[31]);
        expect(s.precededByGap[30], isTrue);
        expect(
          [
            for (var i = 0; i < s.beats; i++)
              if (s.precededByGap[i]) i,
          ],
          [30],
        );
      },
    );

    test('only beats inside the sleep window are exported', () {
      final beats = _steady(120, startOffsetMs: -60 * 1000);
      final series = buildSleepHeartbeatSeries(
        rrMs: beats.rr,
        rrTsMs: beats.ts,
        sleepStart: _sleepStart,
        sleepEnd: _sleepEnd,
      );
      final from = _sleepStart.millisecondsSinceEpoch;
      expect(_instants(series), everyElement(greaterThanOrEqualTo(from)));
      expect(series.single.beats, 60);
    });

    test('a long run is split into series no wider than the max span', () {
      final beats = _steady(12 * 60); // 12 minutes
      final series = buildSleepHeartbeatSeries(
        rrMs: beats.rr,
        rrTsMs: beats.ts,
        sleepStart: _sleepStart,
        sleepEnd: _sleepEnd,
      );
      expect(series, hasLength(3));
      for (final s in series) {
        expect(
          s.offsetsMs.last,
          lessThanOrEqualTo(kHeartbeatSeriesMaxSpan.inMilliseconds),
        );
        expect(s.precededByGap.first, isFalse);
      }
      expect(_instants(series), beats.ts);
    });

    test('absent or malformed input writes nothing', () {
      expect(
        buildSleepHeartbeatSeries(
          rrMs: const [],
          rrTsMs: const [],
          sleepStart: _sleepStart,
          sleepEnd: _sleepEnd,
        ),
        isEmpty,
      );
      expect(
        buildSleepHeartbeatSeries(
          rrMs: const [1000, 1000],
          rrTsMs: const [1],
          sleepStart: _sleepStart,
          sleepEnd: _sleepEnd,
        ),
        isEmpty,
      );
      final beats = _steady(10);
      expect(
        buildSleepHeartbeatSeries(
          rrMs: beats.rr,
          rrTsMs: beats.ts,
          sleepStart: _sleepEnd,
          sleepEnd: _sleepStart,
        ),
        isEmpty,
      );
    });
  });

  group('what a Health reader computes from the export', () {
    test('RMSSD over gap-honouring pairs tracks the nightly RMSSD', () {
      // An hour of sinus-arrhythmic beats with dropouts and missed beats, the
      // shapes a wrist night actually has.
      final rng = math.Random(7);
      final rr = <num>[];
      final ts = <num>[];
      var t = _sleepStart.millisecondsSinceEpoch + 1000.0;
      var phase = 0.0;
      while (t < _sleepStart.millisecondsSinceEpoch + 3600 * 1000) {
        phase += 0.25;
        var interval = (1000 + 60 * math.sin(phase) + rng.nextInt(41) - 20)
            .toDouble();
        final roll = rng.nextDouble();
        if (roll < 0.01) {
          t += 8000 + rng.nextInt(20000); // dropout: nothing reported
        } else if (roll < 0.02) {
          interval *= 2; // missed detection
        }
        t += interval;
        rr.add(interval.round());
        ts.add(t.round());
      }

      final series = buildSleepHeartbeatSeries(
        rrMs: rr,
        rrTsMs: ts,
        sleepStart: _sleepStart,
        sleepEnd: _sleepEnd,
      );

      // A reader: interval = successive instants, kept only when the beat is
      // not preceded by a gap; RMSSD over pairs of adjacent kept intervals.
      var ssd = 0.0;
      var pairs = 0;
      for (final s in series) {
        double? prevInterval;
        for (var i = 1; i < s.beats; i++) {
          if (s.precededByGap[i]) {
            prevInterval = null;
            continue;
          }
          final interval = (s.offsetsMs[i] - s.offsetsMs[i - 1]).toDouble();
          if (prevInterval != null) {
            final d = interval - prevInterval;
            ssd += d * d;
            pairs++;
          }
          prevInterval = interval;
        }
      }
      final exported = math.sqrt(ssd / pairs);

      final cleaned = ana.correctRr(
        [for (final v in rr) v.toDouble()],
        rrTsMs: [for (final v in ts) v.toDouble()],
      );
      final nightly = ana
          .hrvTime(cleaned.nn, nnTimesMs: cleaned.nnTimesMs)
          .value
          ?.rmssd;
      expect(nightly, isNotNull);
      expect((exported - nightly!).abs() / nightly, lessThan(0.05));
    });
  });

  group('MethodChannelHealthKitHeartbeatWriter', () {
    test(
      'one replace call carries the cleanup window and every series',
      () async {
        const channel = MethodChannel('openstrap/test_healthkit_heartbeat');
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return true;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final beats = _steady(12 * 60);
        final series = buildSleepHeartbeatSeries(
          rrMs: beats.rr,
          rrTsMs: beats.ts,
          sleepStart: _sleepStart,
          sleepEnd: _sleepEnd,
        );
        final writer = MethodChannelHealthKitHeartbeatWriter(channel: channel);
        final cleanupStart = DateTime(2026, 8, 4, 12);
        final cleanupEnd = DateTime(2026, 8, 5, 12);
        expect(
          await writer.replace(
            cleanupStart: cleanupStart,
            cleanupEnd: cleanupEnd,
            series: series,
          ),
          isTrue,
        );
        expect(calls, hasLength(1));
        expect(calls.single.method, 'replaceHeartbeatSeries');
        final args = (calls.single.arguments as Map).cast<String, Object?>();
        expect(args['cleanupStartTime'], cleanupStart.millisecondsSinceEpoch);
        expect(args['cleanupEndTime'], cleanupEnd.millisecondsSinceEpoch);
        final sent = args['series'] as List;
        expect(sent, hasLength(3));
        final first = (sent.first as Map).cast<String, Object?>();
        expect(first['startTime'], beats.ts.first);
        expect(
          (first['offsetsMs'] as List).length,
          (first['precededByGap'] as List).length,
        );
      },
    );

    test('an empty series list is still sent: it is the clear', () async {
      const channel = MethodChannel('openstrap/test_healthkit_heartbeat_clear');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final writer = MethodChannelHealthKitHeartbeatWriter(channel: channel);
      expect(
        await writer.replace(
          cleanupStart: DateTime(2026, 8, 4, 12),
          cleanupEnd: DateTime(2026, 8, 5, 12),
          series: const [],
        ),
        isTrue,
      );
      expect(((calls.single.arguments as Map)['series'] as List), isEmpty);
    });
  });
}
