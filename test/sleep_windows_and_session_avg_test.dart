// Two repository seams, against the REAL LocalDb over sqflite_ffi.
//
// 1. `sleepWindows` — onset/offset for N nights in ONE projected query.
//    `getSleep` carries duration and efficiency but no clock times, so an
//    actogram had no choice but to make N separate `getDaySleepV2` calls, each
//    decoding a whole day bundle. `day_result.window_json` has held the sleep
//    window in its own column all along.
//
// 2. `sessions.avg_hr` — the mean HR over a workout window, BANKED. It used to
//    be recomputed on read from the 1 Hz substrate, which is pruned after 3
//    days, so every workout older than that silently lost its average while the
//    peak beside it (a real column) survived.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => root;
  @override
  Future<String?> getLibraryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}

/// A Metric envelope around the window. NOTE: this is NOT what anything
/// actually writes — see [_bareWindowJson]. Kept because the reader has to
/// accept both shapes.
String _windowJson({int? onsetMs, int? offsetMs, double confidence = 0.8}) =>
    jsonEncode({
      'value': onsetMs == null || offsetMs == null
          ? '—' // an absent metric serialises its placeholder, not a map
          : {'onset_ms': onsetMs, 'offset_ms': offsetMs},
      'confidence': confidence,
      'tier': 'HIGH',
      'inputs_used': const ['accel', 'hr'],
    });

/// What the derivation engine and BOTH importers actually store: the BARE
/// `SleepWindow.toJson()` map, no envelope. This file used to assert the
/// envelope shape only, which is why the reader could unwrap `env['value']`
/// with no fallback and still look green while onset_ts/wake_ts came back null
/// for every night that has ever been stored.
String _bareWindowJson({required int onsetMs, required int offsetMs}) =>
    jsonEncode({
      'onset_idx': 0,
      'offset_idx': 1,
      'onset_ms': onsetMs,
      'offset_ms': offsetMs,
      'spt_sec': (offsetMs - onsetMs) ~/ 1000,
    });

void main() {
  late Directory tmp;
  final repo = LocalRepositoryImpl(
    getProfileMap: () => const <String, dynamic>{'age': 34, 'sex': 'male'},
  );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('openstrap_sw_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    LocalDb.dbName = 'openstrap_sleep_windows_test.db';
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('sleepWindows', () {
    test('projects onset/offset for many nights in one read', () async {
      // Three nights, each with a real window, plus one with none.
      const base = 1_714_500_000; // arbitrary epoch seconds
      for (var i = 0; i < 3; i++) {
        await LocalDb.putDayResult(
          dayId: '2024-05-0${i + 1}',
          algoVersion: 66,
          payloadJson: '{}',
          windowJson: _windowJson(
            onsetMs: (base + i * 86400) * 1000,
            offsetMs: (base + i * 86400 + 27000) * 1000,
          ),
        );
      }
      await LocalDb.putDayResult(
        dayId: '2024-05-04',
        algoVersion: 66,
        payloadJson: '{}',
        windowJson: _windowJson(), // no sleep detected
      );

      final rows = await repo.sleepWindows(days: 10);
      expect(rows.length, 4);
      // Newest first — the order an actogram draws top-down.
      expect(rows.first['date'], '2024-05-04');
      expect(rows.last['date'], '2024-05-01');

      final firstNight = rows.last;
      expect(firstNight['onset_ts'], base);
      expect(firstNight['wake_ts'], base + 27000);
      expect(firstNight['confidence'], 0.8);
      expect(firstNight['tier'], 'HIGH');
    });

    test('a night with no detected sleep is PRESENT with null times', () async {
      final rows = await repo.sleepWindows(days: 10);
      final blank = rows.firstWhere((r) => r['date'] == '2024-05-04');
      expect(blank['onset_ts'], isNull);
      expect(blank['wake_ts'], isNull);
      // Dropping the row instead would hand the caller a silently shorter list
      // and shift every night in the actogram by one.
      expect(rows.map((r) => r['date']), contains('2024-05-04'));
    });

    test('reads the BARE window map the engine and both importers write',
        () async {
      const onset = 1_714_000_000;
      await LocalDb.putDayResult(
        dayId: '2024-04-28',
        algoVersion: 66,
        payloadJson: '{}',
        windowJson: _bareWindowJson(
          onsetMs: onset * 1000,
          offsetMs: (onset + 26400) * 1000,
        ),
      );
      final row = (await repo.sleepWindows(days: 30))
          .firstWhere((r) => r['date'] == '2024-04-28');
      expect(row['onset_ts'], onset);
      expect(row['wake_ts'], onset + 26400);
      // No envelope means no confidence/tier — absent, not invented.
      expect(row['confidence'], isNull);
      expect(row['tier'], isNull);
    });

    test('honours the day limit and survives malformed window_json', () async {
      await LocalDb.putDayResult(
        dayId: '2024-05-05',
        algoVersion: 66,
        payloadJson: '{}',
        windowJson: 'not json at all',
      );
      final capped = await repo.sleepWindows(days: 2);
      expect(capped.length, 2);
      expect(capped.first['date'], '2024-05-05');
      expect(capped.first['onset_ts'], isNull);
    });

    test('reads the LATEST algo version for a day, not every version', () async {
      await LocalDb.putDayResult(
        dayId: '2024-05-01',
        algoVersion: 67,
        payloadJson: '{}',
        windowJson: _windowJson(
          onsetMs: 1_700_000_000_000,
          offsetMs: 1_700_027_000_000,
        ),
      );
      final rows = await repo.sleepWindows(days: 30);
      final may1 = rows.where((r) => r['date'] == '2024-05-01').toList();
      expect(may1.length, 1, reason: 'one row per day, not one per version');
      expect(may1.single['onset_ts'], 1_700_000_000);
    });

    test('before keeps only the nights earlier than that day', () async {
      // A past night is compared with the nights before it, not the newest
      // nights overall.
      final rows = await repo.sleepWindows(days: 2, before: '2024-05-04');
      expect(rows.map((r) => r['date']), ['2024-05-03', '2024-05-02']);
    });
  });

  group('sessions.avg_hr', () {
    test('is a real column that round-trips', () async {
      await LocalDb.putSession({
        'id': 's1',
        'start_ts': 1_714_600_000,
        'end_ts': 1_714_603_600,
        'type': 'run',
        'status': 'done',
        'calories': 400.0,
        'strain': 12.0,
        'max_hr': 178,
        'avg_hr': 142,
        'duration_min': 60,
        'zone_min_json': '[]',
        'steps': null,
        'hrr_bpm': null,
        'source': 'manual',
        'created_at': 1_714_603_600_000,
      });
      final row = await LocalDb.session('s1');
      expect(row!['avg_hr'], 142);
    });

    test('setSessionScores never nulls a banked average', () async {
      // A re-score that found no substrate (avgHr omitted) must not delete the
      // measurement an earlier pass banked — that is the whole reason the column
      // exists rather than being recomputed on read.
      await LocalDb.setSessionScores(
        's1',
        strain: 13.0,
        calories: 420.0,
        maxHr: 180,
        zoneMinJson: '[]',
      );
      expect((await LocalDb.session('s1'))!['avg_hr'], 142);

      await LocalDb.setSessionScores(
        's1',
        strain: 13.0,
        calories: 420.0,
        maxHr: 180,
        zoneMinJson: '[]',
        avgHr: 150,
      );
      expect((await LocalDb.session('s1'))!['avg_hr'], 150);
    });

    test('surfaces on getSessions, where there was no average at all', () async {
      final sessions = await repo.getSessions(
        from: 1_714_000_000,
        to: 1_715_000_000,
        includeDetected: false,
      );
      final s = sessions.firstWhere((w) => w['id'] == 's1');
      expect(
        s['avg_hr'],
        150,
        reason: 'getSessions projected max_hr but never an average, so the '
            'activity list had nothing real to label "Avg"',
      );
    });

    test('a session scored with no HR keeps a NULL average, not a 0', () async {
      await LocalDb.putSession({
        'id': 's2',
        'start_ts': 1_714_700_000,
        'end_ts': 1_714_703_600,
        'type': 'yoga',
        'status': 'done',
        'calories': null,
        'strain': null,
        'max_hr': null,
        'avg_hr': null,
        'duration_min': 60,
        'zone_min_json': '[]',
        'steps': null,
        'hrr_bpm': null,
        'source': 'manual',
        'created_at': 1_714_703_600_000,
      });
      final sessions = await repo.getSessions(
        from: 1_714_000_000,
        to: 1_715_000_000,
        includeDetected: false,
      );
      expect(sessions.firstWhere((w) => w['id'] == 's2')['avg_hr'], isNull);
    });
  });
}
