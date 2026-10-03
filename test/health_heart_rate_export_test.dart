import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/health/health_heart_rate_batch.dart';

int _seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> _row(DateTime time, num bpm) => {
  'minute_ts': _seconds(time),
  'avg_hr': bpm,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('continuous heart-rate export', () {
    final start = DateTime(2026, 8, 5);
    final end = DateTime(2026, 8, 6);

    test('normalizes ordered unique in-range whole-minute samples', () {
      final samples = normalizeHealthHeartRateSamples(
        [
          _row(start.add(const Duration(minutes: 3)), 73.9),
          _row(start.subtract(const Duration(minutes: 1)), 65),
          _row(start.add(const Duration(minutes: 1)), 72.8),
          _row(start.add(const Duration(minutes: 3)), 74),
          _row(start.add(const Duration(minutes: 2)), 0),
          _row(start.add(const Duration(minutes: 4)), 301),
          _row(end, 69),
        ],
        start,
        end,
      );

      expect(samples, hasLength(2));
      expect(samples.map((sample) => sample.time), [
        DateTime(2026, 8, 5, 0, 1),
        DateTime(2026, 8, 5, 0, 3),
      ]);
      expect(samples[0].beatsPerMinute, 72);
      expect(samples[1].beatsPerMinute, anyOf(73, 74));
    });

    test('Android sends all normalized samples in one replace call', () async {
      const channel = MethodChannel('openstrap/test_health_connect_heart_rate');
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

      final wrote = await exportContinuousHeartRateDay(
        rows: [
          _row(start.add(const Duration(minutes: 2)), 81.9),
          _row(start.add(const Duration(minutes: 1)), 80.1),
          _row(start.add(const Duration(minutes: 2)), 82),
        ],
        start: start,
        end: end,
        useAndroidBatch: true,
        androidWriter: MethodChannelHealthConnectHeartRateWriter(
          channel: channel,
        ),
        writeGeneric: (_, _) async => throw StateError('not Apple'),
      );

      expect(wrote, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'replaceHeartRateDay');
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(
        args['startTime'],
        start.millisecondsSinceEpoch,
        reason: 'the day is one record starting at midnight and a range '
            'delete matches by start time; a later start misses it',
      );
      expect(args['endTime'], end.millisecondsSinceEpoch);
      expect(args['samples'], [
        {
          'time': DateTime(2026, 8, 5, 0, 1).millisecondsSinceEpoch,
          'beatsPerMinute': 80,
        },
        {
          'time': DateTime(2026, 8, 5, 0, 2).millisecondsSinceEpoch,
          'beatsPerMinute': anyOf(81, 82),
        },
      ]);
    });

    test('Android leaves a partly pruned day\'s record alone', () async {
      final writer = _UnusedHeartRateWriter();
      final rows = [_row(DateTime(2026, 8, 5, 14, 7), 70)];
      Future<bool> export(DateTime? prunedBefore) =>
          exportContinuousHeartRateDay(
            rows: rows,
            start: start,
            end: end,
            useAndroidBatch: true,
            androidWriter: writer,
            prunedBefore: prunedBefore,
            writeGeneric: (_, _) async => throw StateError('not Apple'),
          );

      expect(await export(DateTime(2026, 8, 5, 14)), isTrue);
      expect(writer.calls, 0, reason: 'the record holds HR the rows lost');
      expect(await export(start), isTrue);
      expect(writer.calls, 1);
    });

    test('a day with no samples left is not rewritten', () {
      // The raw window is gone for an older day being re-exported. Clearing
      // its HR anyway deletes what was written while the rows still existed.
      expect(healthHeartRateRewriteFrom(const []), isNull);
      expect(
        healthHeartRateRewriteFrom([
          HealthHeartRateSample(DateTime(2026, 8, 5, 14, 7), 70),
          HealthHeartRateSample(DateTime(2026, 8, 5, 14, 8), 71),
        ]),
        DateTime(2026, 8, 5, 14, 7),
      );
    });

    test('Android batch false result is retryable', () async {
      const channel = MethodChannel(
        'openstrap/test_health_connect_heart_rate_failure',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => false);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      expect(
        await exportContinuousHeartRateDay(
          rows: [_row(start, 70)],
          start: start,
          end: end,
          useAndroidBatch: true,
          androidWriter: MethodChannelHealthConnectHeartRateWriter(
            channel: channel,
          ),
          writeGeneric: (_, _) async => true,
        ),
        isFalse,
      );
    });

    test(
      'Apple writes each valid minute and aggregates false results',
      () async {
        final writes = <(HealthHeartRateSample, DateTime)>[];

        final wrote = await exportContinuousHeartRateDay(
          rows: [
            _row(start.add(const Duration(minutes: 2)), 90.5),
            _row(start.add(const Duration(minutes: 1)), 80.9),
            _row(start.add(const Duration(minutes: 3)), 0),
          ],
          start: start,
          end: end,
          useAndroidBatch: false,
          androidWriter: _UnusedHeartRateWriter(),
          writeGeneric: (sample, sampleEnd) async {
            writes.add((sample, sampleEnd));
            return sample.beatsPerMinute != 80;
          },
        );

        expect(wrote, isFalse);
        expect(writes, [
          (
            HealthHeartRateSample(DateTime(2026, 8, 5, 0, 1), 80),
            DateTime(2026, 8, 5, 0, 2),
          ),
          (
            HealthHeartRateSample(DateTime(2026, 8, 5, 0, 2), 90),
            DateTime(2026, 8, 5, 0, 3),
          ),
        ]);
      },
    );

    test('empty normalized input succeeds without either writer', () async {
      var genericCalls = 0;
      final androidWriter = _UnusedHeartRateWriter();

      expect(
        await exportContinuousHeartRateDay(
          rows: [
            _row(start.subtract(const Duration(minutes: 1)), 70),
            _row(start, 0),
            _row(end, 70),
          ],
          start: start,
          end: end,
          useAndroidBatch: true,
          androidWriter: androidWriter,
          writeGeneric: (_, _) async {
            genericCalls++;
            return true;
          },
        ),
        isTrue,
      );
      expect(androidWriter.calls, 0);
      expect(genericCalls, 0);
    });

    test('native empty request completes before Health Connect availability', () {
      final source = File(
        'android/app/src/main/kotlin/wtf/openstrap/openstrap_edge/HealthConnectHeartRateWriter.kt',
      ).readAsStringSync();
      final replace = source.substring(
        source.indexOf('private suspend fun replace'),
        source.indexOf('private data class Request'),
      );

      expect(
        replace.indexOf('val request = buildRequest(call)'),
        lessThan(replace.indexOf('HealthConnectClient.getSdkStatus(context)')),
      );
      expect(
        replace.indexOf('if (request.samples.isEmpty()) return@withLock true'),
        lessThan(replace.indexOf('HealthConnectClient.getSdkStatus(context)')),
      );
    });
  });
}

class _UnusedHeartRateWriter implements HealthConnectHeartRateWriter {
  var calls = 0;

  @override
  Future<bool> replaceDay(
    DateTime start,
    DateTime end,
    List<HealthHeartRateSample> samples,
  ) async {
    calls++;
    return true;
  }
}
