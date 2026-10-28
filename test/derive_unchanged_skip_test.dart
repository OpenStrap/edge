// A heavy pass leaves a pending day alone when nothing it reads has moved
// since a derive of it that changed nothing it reads. That is only allowed if
// it is invisible: the same passes with every day derived must store exactly
// the same results, and an override, new data, a profile change or an
// algorithm bump must still re-derive.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/models.dart' show RawRecord, Sample;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const _profile = Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

// Mid-July, no DST edge. The newest days stay pending: the data edge is less
// than 48 h past them.
final _days = [
  for (var i = 0; i < 3; i++) SyntheticDay(DateTime(2026, 7, 13 + i)),
];

Future<void> _freshDb(String name) async {
  SharedPreferences.setMockInitialValues({});
  await LocalDb.close();
  LocalDb.dbName = name;
  await databaseFactory
      .deleteDatabase(p.join(await databaseFactory.getDatabasesPath(), name));
  var committed = 0;
  for (final d in _days) {
    for (final (raws, samples) in d.primaryBatches()) {
      final keep = [
        for (var j = 0; j < raws.length; j++)
          if (raws[j].recTs! > committed) j,
      ];
      if (keep.isEmpty) continue;
      await LocalDb.commitSyncBatch(
        [for (final j in keep) raws[j]],
        [for (final j in keep) samples[j]],
        deviceFamily: 'gen4',
      );
      committed = raws[keep.last].recTs!;
    }
  }
}

Future<({int derived, int unchanged})> _pass({Profile profile = _profile}) async {
  final e = DerivationEngine();
  final n = await e.run(profile, heavy: true);
  return (derived: n, unchanged: e.lastRunUnchangedDays);
}

/// Every stored output of a derive, write stamps dropped (the columns, and
/// the wall-clock stamps inside the baseline artifacts).
Future<String> _snapshot() async {
  final db = await LocalDb.instance;
  Future<List<Map<String, Object?>>> rows(String sql) async => [
        for (final r in await db.rawQuery(sql))
          {
            for (final e in r.entries)
              if (!e.key.endsWith('_at') && e.key != 'updated_ts')
                e.key: e.value is String
                    ? (e.value as String).replaceAll(
                        RegExp(r'"(updated|built)[A-Za-z_]*":\s*\d+'), '')
                    : e.value,
          },
      ];
  return jsonEncode({
    'day_result': await rows(
        'SELECT * FROM day_result ORDER BY day_id, algo_version'),
    'metric_series':
        await rows('SELECT * FROM metric_series ORDER BY date, key'),
    'metric_series_version':
        await rows('SELECT * FROM metric_series_version ORDER BY date'),
    'wake_day_features': await rows(
        'SELECT * FROM wake_day_features ORDER BY day_id, algo_version'),
    'sleep_session_candidates': await rows('SELECT * FROM '
        'sleep_session_candidates ORDER BY day_id, algo_version'),
    'activity_suggestions':
        await rows('SELECT * FROM activity_suggestions ORDER BY id'),
    'sleep_nap': await rows('SELECT * FROM sleep_nap ORDER BY start_ts'),
    'baselines': await rows('SELECT * FROM baselines ORDER BY key'),
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    DerivationEngine.debugDeriveEveryDay = false;
    DerivationEngine.debugFingerprintAlgoVersion = null;
    await LocalDb.close();
  });

  test('skipping unchanged days stores exactly what deriving them does',
      () async {
    const passes = 5;
    await _freshDb('unchanged_skip_on.db');
    final log = <({int derived, int unchanged})>[];
    for (var i = 0; i < passes; i++) {
      log.add(await _pass());
    }
    final withSkip = await _snapshot();

    await _freshDb('unchanged_skip_off.db');
    DerivationEngine.debugDeriveEveryDay = true;
    for (var i = 0; i < passes; i++) {
      final r = await _pass();
      expect(r.unchanged, 0);
    }
    final everyDay = await _snapshot();

    // The skip actually happened: by the last pass nothing was derived.
    expect(log.last.derived, 0, reason: '$log');
    expect(log.last.unchanged, greaterThan(0), reason: '$log');
    expect(withSkip, everyDay);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('an override, new data, a profile change and a version bump re-derive',
      () async {
    await _freshDb('unchanged_skip_triggers.db');
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        if ((await _pass()).derived == 0) return;
      }
      fail('never settled');
    }

    await settle();
    final settled = await _pass();
    expect(settled.derived, 0);
    final pending = settled.unchanged;
    expect(pending, greaterThan(0));

    // The user's own sleep window on a pending day.
    final d = _days[1];
    await LocalDb.putSleepOverride(
      dayId: '2026-07-14',
      onsetTs: SyntheticDay.sec(d.sleepOnset) + 600,
      offsetTs: SyntheticDay.sec(d.sleepOffset),
      source: 'manual',
    );
    expect((await _pass()).derived, greaterThanOrEqualTo(1));
    await settle();

    // A second re-delivered inside a pending day's window (counter-reset
    // recovery replaces the row in place, the data edge does not move).
    final t = SyntheticDay.sec(DateTime(2026, 7, 14, 12));
    await LocalDb.commitSyncBatch(
      [
        RawRecord(
            counter: 1, packetType: 0x2F, hex: 'aa', capturedAt: t * 1000,
            recTs: t),
      ],
      [Sample(tsEpoch: t, counter: 1, hr: 140, ax: 0, ay: 0, az: 1)],
      deviceFamily: 'gen4',
    );
    expect((await _pass()).derived, greaterThanOrEqualTo(1));
    await settle();

    expect(
      (await _pass(
              profile: const Profile(
                  ageYears: 33, weightKg: 72, heightCm: 176, sex: 'm')))
          .derived,
      pending,
    );
    await settle();

    DerivationEngine.debugFingerprintAlgoVersion = kAlgoVersion + 1;
    expect((await _pass()).derived, pending);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
