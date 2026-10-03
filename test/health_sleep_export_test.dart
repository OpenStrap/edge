import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health/health.dart';
import 'package:openstrap_edge/health/health_export.dart';
import 'package:openstrap_edge/health/health_sleep_session.dart';

int _seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;

Map<String, Object> _segment(DateTime start, DateTime end, String stage) => {
  'start': _seconds(start),
  'end': _seconds(end),
  'stage': stage,
};

Map<String, dynamic> _overnightBundle() {
  final start = DateTime(2026, 8, 4, 23, 55);
  final end = DateTime(2026, 8, 5, 7, 46);
  final at0011 = DateTime(2026, 8, 5, 0, 11);
  final at0241 = DateTime(2026, 8, 5, 2, 41);
  final at0257 = DateTime(2026, 8, 5, 2, 57);
  final at0545 = DateTime(2026, 8, 5, 5, 45);
  final at0720 = DateTime(2026, 8, 5, 7, 20);
  final at0736 = DateTime(2026, 8, 5, 7, 36);

  return {
    'sleep': {
      'window': {
        'value': {
          'onset_ms': start.millisecondsSinceEpoch,
          'offset_ms': end.millisecondsSinceEpoch,
        },
      },
    },
    'series': {
      // Intentionally out of order: normalization must use timestamps, not
      // the input list order.
      'hypnogram': [
        _segment(at0545, at0720, 'rem'), // 95 min
        _segment(start, at0011, 'wake'), // 16 min awake
        _segment(at0257, at0545, 'light'), // 168 min
        _segment(at0720, at0736, 'awake'), // 16 min awake
        _segment(at0241, at0257, 'deep'), // 16 min
        _segment(at0011, at0241, 'light'), // 150 min
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Health Connect sleep-session export regression', () {
    test(
      'successful priority sleep bypasses retry backoff and cap for same-day bulk',
      () {
        final now = DateTime(2026, 8, 6, 12);

        expect(
          shouldAttemptHealthBulkExport(
            attempts: 2,
            maxAttempts: 6,
            now: now,
            lastAttempt: now.subtract(const Duration(seconds: 1)),
            backoff: const Duration(hours: 2),
            prioritySleepAlreadyWritten: true,
          ),
          isTrue,
        );
        expect(
          shouldAttemptHealthBulkExport(
            attempts: 6,
            maxAttempts: 6,
            now: now,
            lastAttempt: now.subtract(const Duration(seconds: 1)),
            backoff: const Duration(hours: 2),
            prioritySleepAlreadyWritten: false,
          ),
          isFalse,
        );
        expect(
          shouldAttemptHealthBulkExport(
            attempts: 6,
            maxAttempts: 6,
            now: now,
            lastAttempt: now.subtract(const Duration(days: 1)),
            backoff: const Duration(hours: 2),
            prioritySleepAlreadyWritten: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'newest detected sleep is written before bulk and only once',
      () async {
        final writes = <Map<String, dynamic>>[];
        final newestSleep = _overnightBundle();

        final result = await exportNewestPrioritySleep(
          newestFirstDays: [
            MapEntry('2026-08-06', <String, dynamic>{}),
            MapEntry('2026-08-05', newestSleep),
            MapEntry('2026-08-04', _overnightBundle()),
          ],
          write: (bundle) async {
            writes.add(bundle);
            return true;
          },
        );

        expect(result.date, '2026-08-05');
        expect(result.succeeded, isTrue);
        expect(writes, hasLength(1));
        expect(writes.single, same(newestSleep));
      },
    );

    test('failed priority sleep write reports failure', () async {
      var writes = 0;

      final result = await exportNewestPrioritySleep(
        newestFirstDays: [MapEntry('2026-08-05', _overnightBundle())],
        write: (bundle) async {
          writes++;
          return false;
        },
      );

      expect(result.date, '2026-08-05');
      expect(result.succeeded, isFalse);
      expect(writes, 1);
    });

    test('failed priority sleep never invokes the bulk callback', () async {
      var priorityWrites = 0;
      var bulkWrites = 0;

      final result = await exportPrioritySleepBeforeBulk(
        newestFirstDays: [MapEntry('2026-08-05', _overnightBundle())],
        write: (bundle) async {
          priorityWrites++;
          return false;
        },
        exportBulk: (androidSleepAlreadyWritten) async {
          bulkWrites++;
        },
      );

      expect(result.date, '2026-08-05');
      expect(result.succeeded, isFalse);
      expect(priorityWrites, 1);
      expect(bulkWrites, 0);
    });

    test('thrown priority sleep never invokes the bulk callback', () async {
      var bulkWrites = 0;

      await expectLater(
        exportPrioritySleepBeforeBulk(
          newestFirstDays: [MapEntry('2026-08-05', _overnightBundle())],
          write: (bundle) async => throw StateError('priority write failed'),
          exportBulk: (androidSleepAlreadyWritten) async {
            bulkWrites++;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(bulkWrites, 0);
    });

    test('priority success leaves shared retry state for the bulk export', () {
      final source = File('lib/health/health_export.dart').readAsStringSync();
      final priorityCallback = source.substring(
        source.indexOf(
          'final priorityResult = await exportPrioritySleepBeforeBulk(',
        ),
        source.indexOf('exportBulk = (String? androidSleepAlreadyWritten)'),
      );

      expect(
        priorityCallback,
        isNot(contains('retryState.remove(priorityDay!.key)')),
        reason: 'only the full-day bulk result may clear a shared retry entry',
      );
    });

    test(
      'successful priority sleep invokes bulk once without another sleep',
      () async {
        var priorityWrites = 0;
        var totalSleepWrites = 0;
        final bulkPriorityDates = <String?>[];

        final result = await exportPrioritySleepBeforeBulk(
          newestFirstDays: [MapEntry('2026-08-05', _overnightBundle())],
          write: (bundle) async {
            priorityWrites++;
            totalSleepWrites++;
            return true;
          },
          exportBulk: (androidSleepAlreadyWritten) async {
            bulkPriorityDates.add(androidSleepAlreadyWritten);
            if (androidSleepAlreadyWritten == null) totalSleepWrites++;
          },
        );

        expect(result.date, '2026-08-05');
        expect(result.succeeded, isTrue);
        expect(priorityWrites, 1);
        expect(totalSleepWrites, 1);
        expect(bulkPriorityDates, ['2026-08-05']);
      },
    );

    test('Android generic cleanup never deletes sleep records', () {
      final types = healthDeleteTypes(isApplePlatform: false);

      expect(types, contains(HealthDataType.STEPS));
      expect(
        types,
        isNot(contains(HealthDataType.HEART_RATE)),
        reason: 'Android native replacement owns heart-rate cleanup',
      );
      expect(
        types,
        isNot(
          containsAll(<HealthDataType>[
            HealthDataType.SLEEP_DEEP,
            HealthDataType.SLEEP_REM,
            HealthDataType.SLEEP_LIGHT,
            HealthDataType.SLEEP_AWAKE,
            HealthDataType.SLEEP_SESSION,
          ]),
        ),
      );
      expect(types.where((type) => type.name.startsWith('SLEEP_')), isEmpty);
    });

    test('Apple generic cleanup retains heart-rate records', () {
      expect(
        healthDeleteTypes(isApplePlatform: true),
        contains(HealthDataType.HEART_RATE),
      );
    });

    test(
      'Apple generic cleanup never names sleep — native replace owns it',
      () {
        final types = healthDeleteTypes(isApplePlatform: true);

        expect(types, contains(HealthDataType.HEART_RATE));
        expect(types, isNot(contains(HealthDataType.SLEEP_SESSION)));
        expect(types, isNot(contains(HealthDataType.SLEEP_IN_BED)));
        expect(types.where((type) => type.name.startsWith('SLEEP_')), isEmpty);
      },
    );

    test('the sleep delete covers the pre-midnight half of the night', () {
      final dayStart = DateTime(2026, 8, 5);
      final dayEnd = DateTime(2026, 8, 6);
      final night = normalizeHealthSleepSession(_overnightBundle())!;

      // Onset is 2026-08-04 23:55 — OUTSIDE the day that owns this night. A
      // day-scoped delete leaves it behind and every retry appends another
      // copy, which is the truncation and the duplicate bars both.
      expect(night.start.isBefore(dayStart), isTrue);

      final window = sleepCleanupWindow(
        dayStart: dayStart,
        dayEnd: dayEnd,
        night: night,
      );
      expect(window.start, DateTime(2026, 8, 4, 12));
      expect(window.end, DateTime(2026, 8, 5, 12), reason:
          'noon-to-noon only — the old calendar-day union reached into the '
          'previous night and deleted samples nothing ever rewrites');

      // No night to write — nothing to widen for, and the day window still has
      // to be swept so stale samples from an earlier export go.
      final none = sleepCleanupWindow(dayStart: dayStart, dayEnd: dayEnd);
      expect(none.start, dayStart);
      expect(none.end, dayEnd);
    });

    test('Apple and Android share one hypnogram stage vocabulary', () {
      expect(healthSleepStageOf('wake'), HealthSleepStage.awake);
      expect(healthSleepStageOf('awake'), HealthSleepStage.awake);
      expect(healthSleepStageOf('rem'), HealthSleepStage.rem);
      expect(healthSleepStageOf('light'), HealthSleepStage.light);
      expect(healthSleepStageOf('nrem'), HealthSleepStage.light);
      expect(healthSleepStageOf('core'), HealthSleepStage.light);
      // Unobserved is NOT wake — it is unwatched time, and exporting it as
      // measured wake fabricates a reading other apps trust.
      expect(healthSleepStageOf('unobserved'), isNull);
      expect(healthSleepStageOf('deep'), HealthSleepStage.deep);
      expect(healthSleepStageOf('unknown'), isNull);
    });

    test('manual sync bypasses retry backoff and attempt cap', () {
      final now = DateTime(2026, 8, 5, 13);

      expect(
        shouldAttemptHealthExport(
          attempts: 6,
          maxAttempts: 6,
          now: now,
          lastAttempt: now.subtract(const Duration(seconds: 1)),
          backoff: const Duration(hours: 1),
        ),
        isFalse,
      );
      expect(
        shouldAttemptHealthExport(
          attempts: 6,
          maxAttempts: 6,
          now: now,
          lastAttempt: now.subtract(const Duration(seconds: 1)),
          backoff: const Duration(hours: 1),
          force: true,
        ),
        isTrue,
      );
    });

    test(
      'manual health exports are single-flight and reset after completion',
      () async {
        final gate = HealthExportSingleFlight();
        final firstResult = Completer<int>();
        var calls = 0;

        Future<int> export() {
          calls++;
          return calls == 1 ? firstResult.future : Future<int>.value(2);
        }

        final first = gate.run(export);
        final overlapping = gate.run(export);
        expect(calls, 1);

        firstResult.complete(1);
        expect(await first, 1);
        expect(await overlapping, 1);
        expect(await gate.run(export), 2);
        expect(calls, 2);
      },
    );

    test('single-flight preserves synchronous errors and resets', () async {
      final gate = HealthExportSingleFlight();

      await expectLater(
        gate.run(() => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      expect(await gate.run(() async => 3), 3);
    });

    test('AppState centralizes every full health export behind one gate', () {
      final source = File('lib/state/app_state.dart').readAsStringSync();
      final directCalls = RegExp(
        r'_healthExport\.exportAll\(',
      ).allMatches(source);

      expect(
        directCalls,
        hasLength(1),
        reason: 'automatic and forced exports must share one guarded method',
      );
      expect(source, contains('Future<int> _runHealthExport('));
    });

    test('normalizes one complete cross-midnight session with every stage', () {
      final session = normalizeHealthSleepSession(_overnightBundle());

      expect(session, isNotNull);
      expect(session!.start, DateTime(2026, 8, 4, 23, 55));
      expect(session.end, DateTime(2026, 8, 5, 7, 46));
      expect(session.stages, hasLength(6));

      for (var i = 0; i < session.stages.length; i++) {
        final stage = session.stages[i];
        expect(stage.start.isBefore(stage.end), isTrue);
        expect(stage.start.isBefore(session.start), isFalse);
        expect(stage.end.isAfter(session.end), isFalse);
        if (i > 0) {
          expect(
            stage.start.isBefore(session.stages[i - 1].end),
            isFalse,
            reason: 'sleep stages must be ordered and non-overlapping',
          );
        }
      }

      final minutesByStage = <HealthSleepStage, int>{};
      for (final stage in session.stages) {
        minutesByStage.update(
          stage.stage,
          (value) => value + stage.duration.inMinutes,
          ifAbsent: () => stage.duration.inMinutes,
        );
      }
      expect(minutesByStage, {
        HealthSleepStage.awake: 32,
        HealthSleepStage.rem: 95,
        HealthSleepStage.light: 318,
        HealthSleepStage.deep: 16,
      }, reason:
          '07:36–07:46 had no label and stays unwritten — unobserved time '
          'belongs to neither sleep nor wake, so Time Asleep is the sum of '
          'the MEASURED stages only');
    });

    test(
      'clips stages to the parent and removes overlap and zero duration',
      () {
        final start = DateTime(2026, 8, 4, 23, 55);
        final end = DateTime(2026, 8, 5, 0, 25);
        final bundle = {
          'sleep': {
            'window': {
              'value': {
                'onset_ms': start.millisecondsSinceEpoch,
                'offset_ms': end.millisecondsSinceEpoch,
              },
            },
          },
          'series': {
            'hypnogram': [
              _segment(
                start.subtract(const Duration(minutes: 5)),
                start.add(const Duration(minutes: 10)),
                'light',
              ),
              _segment(
                start.add(const Duration(minutes: 8)),
                start.add(const Duration(minutes: 20)),
                'deep',
              ),
              _segment(end, end, 'rem'),
              _segment(
                start.add(const Duration(minutes: 20)),
                end.add(const Duration(minutes: 5)),
                'rem',
              ),
            ],
          },
        };

        final session = normalizeHealthSleepSession(bundle)!;

        expect(session.stages, hasLength(3));
        expect(session.stages[0].start, start);
        expect(session.stages[0].end, start.add(const Duration(minutes: 10)));
        expect(session.stages[1].start, start.add(const Duration(minutes: 10)));
        expect(session.stages[1].end, start.add(const Duration(minutes: 20)));
        expect(session.stages[2].start, start.add(const Duration(minutes: 20)));
        expect(session.stages[2].end, end);
      },
    );

    test('one channel call carries one parent and every stage', () async {
      const channel = MethodChannel('openstrap/test_health_connect_sleep');
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

      final exporter = HealthConnectSleepSessionExporter(
        writer: MethodChannelHealthConnectSleepSessionWriter(channel: channel),
      );

      expect(await exporter.replace(_overnightBundle()), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'replaceSleepSession');
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(
        args['startTime'],
        DateTime(2026, 8, 4, 23, 55).millisecondsSinceEpoch,
      );
      expect(
        args['endTime'],
        DateTime(2026, 8, 5, 7, 46).millisecondsSinceEpoch,
      );
      expect(args['stages'] as List, hasLength(6));
    });

    test(
      'an empty normalized hypnogram is a benign no-op — it never replaces '
      'native data, and it must not fail the whole day\'s export',
      () async {
        const channel = MethodChannel('openstrap/test_health_connect_empty');
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls++;
              return true;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final exporter = HealthConnectSleepSessionExporter(
          writer: MethodChannelHealthConnectSleepSessionWriter(
            channel: channel,
          ),
        );
        final bundle = _overnightBundle();
        ((bundle['series'] as Map)['hypnogram'] as List).clear();

        expect(
          await exporter.replace(bundle),
          isTrue,
          reason:
              'false is a HARD failure for the entire day in health_export.dart '
              '(success = false stops the cursor advancing), so a missing '
              'hypnogram used to withhold steps/calories/HR too. Imported days '
              'carry a sleep window with no substrate to stage from, so they '
              'could never export at all.',
        );
        expect(calls, 0, reason: 'empty stages must not delete native sleep');
      },
    );

    test(
      'an IMPORTED-shaped day (sleep window, no series at all) is a no-op, '
      'not a failure — this is the case that never exported',
      () async {
        const channel = MethodChannel('openstrap/test_health_connect_imported');
        var calls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls++;
              return true;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final exporter = HealthConnectSleepSessionExporter(
          writer: MethodChannelHealthConnectSleepSessionWriter(
            channel: channel,
          ),
        );
        // A CSV import gives a window but no per-second substrate to stage
        // from, so `series` is absent entirely rather than merely empty.
        final bundle = _overnightBundle();
        bundle.remove('series');

        expect(await exporter.replace(bundle), isTrue);
        expect(calls, 0);
      },
    );

    test(
      'a day with NO sleep window and a day with a window but no stages agree '
      '— both are "nothing to write", so both report the same way',
      () async {
        const channel = MethodChannel('openstrap/test_health_connect_symmetry');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async => true);
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final exporter = HealthConnectSleepSessionExporter(
          writer: MethodChannelHealthConnectSleepSessionWriter(
            channel: channel,
          ),
        );

        final noWindow = _overnightBundle()..remove('sleep');
        final noStages = _overnightBundle();
        ((noStages['series'] as Map)['hypnogram'] as List).clear();

        expect(await exporter.replace(noWindow), isTrue);
        expect(
          await exporter.replace(noStages),
          isTrue,
          reason: 'the asymmetry between these two WAS the bug',
        );
      },
    );

    test(
      'a day whose night is gone (rejected) clears the night exported earlier',
      () async {
        const channel = MethodChannel('openstrap/test_health_connect_clear');
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
        final exporter = HealthConnectSleepSessionExporter(
          writer: MethodChannelHealthConnectSleepSessionWriter(
            channel: channel,
          ),
        );

        final noWindow = _overnightBundle()..remove('sleep');
        expect(
          await exporter.replace(noWindow, dayStart: DateTime(2026, 8, 5)),
          isTrue,
        );
        expect(calls.single.method, 'clearSleepSessions');
        final args = (calls.single.arguments as Map).cast<String, Object?>();
        expect(
          args['startTime'],
          DateTime(2026, 8, 4, 12).millisecondsSinceEpoch,
          reason: 'a night that started at 23:00 the evening before is '
              'matched by its start, so the clear has to reach back to it',
        );
        expect(
          args['endTime'],
          DateTime(2026, 8, 5, 12).millisecondsSinceEpoch,
          reason: 'noon: tonight\'s night (starting this evening) is not ours',
        );
      },
    );

    test(
      're-export uses the replace operation and a false result propagates',
      () async {
        const channel = MethodChannel('openstrap/test_health_connect_replace');
        final storedParents = <Map<String, Object?>>[];
        var writes = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              writes++;
              final args = (call.arguments as Map).cast<String, Object?>();
              storedParents
                ..clear()
                ..add(args);
              return writes == 1;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final exporter = HealthConnectSleepSessionExporter(
          writer: MethodChannelHealthConnectSleepSessionWriter(
            channel: channel,
          ),
        );

        expect(await exporter.replace(_overnightBundle()), isTrue);
        expect(await exporter.replace(_overnightBundle()), isFalse);
        expect(writes, 2, reason: 'each export sends exactly one replace call');
        expect(storedParents.single['stages'] as List, hasLength(6));
      },
    );

    test(
      'overlapping exports never enter the native replace concurrently',
      () async {
        const channel = MethodChannel(
          'openstrap/test_health_connect_concurrency',
        );
        final firstEntered = Completer<void>();
        final releaseFirst = Completer<bool>();
        var calls = 0;
        var activeCalls = 0;
        var maxActiveCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls++;
              activeCalls++;
              if (activeCalls > maxActiveCalls) maxActiveCalls = activeCalls;
              if (calls == 1) {
                firstEntered.complete();
                await releaseFirst.future;
              }
              activeCalls--;
              return true;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });
        final exporter = HealthConnectSleepSessionExporter(
          writer: MethodChannelHealthConnectSleepSessionWriter(
            channel: channel,
          ),
        );

        final first = exporter.replace(_overnightBundle());
        await firstEntered.future;
        final second = exporter.replace(_overnightBundle());
        await pumpEventQueue();

        expect(calls, 1, reason: 'the second native replace must stay queued');
        releaseFirst.complete(true);
        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(calls, 2);
        expect(maxActiveCalls, 1);
      },
    );

    test(
      'noon-to-noon cleanup covers leftover fragments before a later onset',
      () {
        // Issue #225: in-app night is 01:06–08:42 but Health still shows REM
        // from ~11pm — those samples sit outside [01:06, 08:42) and a
        // night-scoped delete never touched them.
        final night = HealthSleepSession(
          start: DateTime(2026, 8, 5, 1, 6),
          end: DateTime(2026, 8, 5, 8, 42),
          stages: const [],
        );
        final leftover = DateTime(2026, 8, 4, 23, 0);
        final range = sleepSessionCleanupRange(night);

        expect(range.start, DateTime(2026, 8, 4, 12));
        expect(range.end, DateTime(2026, 8, 5, 12));
        expect(leftover.isBefore(range.start), isFalse);
        expect(leftover.isBefore(range.end), isTrue);
      },
    );

    test('leaves unlabelled gaps out of the stage list entirely', () {
      final start = DateTime(2026, 8, 5, 1);
      final end = DateTime(2026, 8, 5, 4);
      final bundle = {
        'sleep': {
          'window': {
            'value': {
              'onset_ms': start.millisecondsSinceEpoch,
              'offset_ms': end.millisecondsSinceEpoch,
            },
          },
        },
        'series': {
          'hypnogram': [
            _segment(start, start.add(const Duration(hours: 1)), 'light'),
            _segment(start.add(const Duration(hours: 2)), end, 'rem'),
          ],
        },
      };

      final session = normalizeHealthSleepSession(bundle)!;
      // The 1h-2h hole is UNOBSERVED, not wake. Exporting it as measured
      // wake fabricates a reading other apps take as fact; Time Asleep sums
      // asleep stages only, so the hole contributes nothing either way.
      expect(session.stages, hasLength(2));
      expect(session.stages[0].stage, HealthSleepStage.light);
      expect(session.stages[1].stage, HealthSleepStage.rem);
    });

    test('accepts UI-shaped {t,stage} points and millisecond timestamps', () {
      final start = DateTime(2026, 8, 5, 1);
      final mid = DateTime(2026, 8, 5, 2);
      final end = DateTime(2026, 8, 5, 3);
      final bundle = {
        'sleep': {
          'window': {
            'value': {
              'onset_ms': start.millisecondsSinceEpoch,
              'offset_ms': end.millisecondsSinceEpoch,
            },
          },
        },
        'series': {
          'hypnogram': [
            {'t': start.millisecondsSinceEpoch, 'stage': 'core'},
            {'t': mid.millisecondsSinceEpoch, 'stage': 'deep'},
            {'t': end.millisecondsSinceEpoch, 'stage': 'wake'},
          ],
        },
      };

      final session = normalizeHealthSleepSession(bundle)!;
      expect(session.stages, hasLength(2));
      expect(session.stages[0].stage, HealthSleepStage.light);
      expect(session.stages[0].start, start);
      expect(session.stages[0].end, mid);
      expect(session.stages[1].stage, HealthSleepStage.deep);
      expect(session.stages[1].end, end);
    });

    test('a new sleep-writer epoch clears the export cursor once', () async {
      final stored = <String, String>{
        'health_export_through': '2026-08-01',
        'health_export_retry_state': '{"2026-08-02":1}',
      };

      await ensureHealthSleepExportEpoch(
        getCursor: (name) async => stored[name],
        setCursor: (name, value) async {
          stored[name] = value;
        },
        isApplePlatform: true,
      );
      expect(stored['health_export_through'], '');
      expect(stored['health_export_retry_state'], '');
      expect(stored[kHealthSleepExportEpochCursor], kHealthSleepExportEpoch);

      stored['health_export_through'] = '2026-08-05';
      await ensureHealthSleepExportEpoch(
        getCursor: (name) async => stored[name],
        setCursor: (name, value) async {
          stored[name] = value;
        },
        isApplePlatform: true,
      );
      expect(stored['health_export_through'], '2026-08-05');
    });

    test('the sleep-writer epoch never replays Health Connect bundles',
        () async {
      final stored = <String, String>{
        'health_export_through': '2026-08-01',
        'health_export_retry_state': '{"2026-08-02":1}',
      };

      await ensureHealthSleepExportEpoch(
        getCursor: (name) async => stored[name],
        setCursor: (name, value) async {
          stored[name] = value;
        },
        isApplePlatform: false,
      );
      expect(stored['health_export_through'], '2026-08-01');
      expect(stored['health_export_retry_state'], '{"2026-08-02":1}');
      expect(stored.containsKey(kHealthSleepExportEpochCursor), isFalse,
          reason: 'nothing about the HC writer changed — no replay, no bump');
    });

    test('Apple replace sends in-bed even when stages are empty', () async {
      const channel = MethodChannel('openstrap/test_healthkit_sleep');
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

      final exporter = HealthKitSleepSessionExporter(
        writer: MethodChannelHealthKitSleepSessionWriter(channel: channel),
      );
      final bundle = _overnightBundle();
      ((bundle['series'] as Map)['hypnogram'] as List).clear();

      expect(
        await exporter.replace(
          bundle: bundle,
          dayStart: DateTime(2026, 8, 5),
          dayEnd: DateTime(2026, 8, 6),
        ),
        isTrue,
      );
      expect(calls, hasLength(1));
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(args['startTime'], isNotNull);
      expect(args['stages'] as List, isEmpty);
      expect(
        args['cleanupStartTime'],
        DateTime(2026, 8, 4, 12).millisecondsSinceEpoch,
      );
    });

    test(
      'Apple replace carries Core stages and noon-to-noon cleanup',
      () async {
        const channel = MethodChannel('openstrap/test_healthkit_sleep_full');
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

        final exporter = HealthKitSleepSessionExporter(
          writer: MethodChannelHealthKitSleepSessionWriter(channel: channel),
        );

        expect(
          await exporter.replace(
            bundle: _overnightBundle(),
            dayStart: DateTime(2026, 8, 5),
            dayEnd: DateTime(2026, 8, 6),
          ),
          isTrue,
        );
        expect(calls, hasLength(1));
        expect(calls.single.method, 'replaceSleepSession');
        final args = (calls.single.arguments as Map).cast<String, Object?>();
        expect(
          args['cleanupStartTime'],
          DateTime(2026, 8, 4, 12).millisecondsSinceEpoch,
        );
        expect(
          args['cleanupEndTime'],
          DateTime(2026, 8, 5, 12).millisecondsSinceEpoch,
          reason:
              'noon-to-noon only — the calendar-day union reached into the '
              'previous night and deleted samples nothing rewrites',
        );
        final stages = args['stages'] as List;
        expect(stages, isNotEmpty);
        expect(
          stages.map((raw) => (raw as Map)['stage']).toSet(),
          containsAll(<String>['awake', 'rem', 'light', 'deep']),
        );
      },
    );

    test('a sleep edit behind the export cursor pulls that day back in', () {
      // Finalized and already exported: exportAll skips it, so a rejected
      // night's session would never be cleared from Health Connect.
      expect(healthExportCursorBefore('2026-09-30', '2026-09-28'),
          '2026-09-27');
      expect(healthExportCursorBefore('2026-09-28', '2026-09-28'),
          '2026-09-27');
      expect(healthExportCursorBefore('2026-03-01', '2026-03-01'),
          '2026-02-28');
      // Still ahead of the cursor (or nothing exported yet): leave it alone.
      expect(healthExportCursorBefore('2026-09-27', '2026-09-28'), isNull);
      expect(healthExportCursorBefore('', '2026-09-28'), isNull);
    });
  });
}
