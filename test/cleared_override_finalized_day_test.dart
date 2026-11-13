// Clearing a sleep override deletes its row before the re-derive, so the day
// is no longer an override day. A night old enough to be finalized has to be
// re-derived anyway, or "Back to automatic" / "Undo" on Not sleep leaves the
// user's window (or the rejected night) on screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

const _profile = Profile(
  ageYears: 35,
  sex: 'm',
  weightKg: 75,
  heightCm: 178,
  restingHrManual: 55,
);

Future<void> _seedDay(String day) async {
  final d = DateTime.parse(day);
  final ts = DateTime(d.year, d.month, d.day, 12).millisecondsSinceEpoch ~/ 1000;
  await (await LocalDb.instance).insert(
    'decoded_onehz',
    {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': ts % 100000,
      'hr': 60,
      'ax': 0.0,
      'ay': -0.5,
      'az': 0.98,
      'device_family': 'gen4',
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_cleared_override_finalized_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a force pass re-derives a finalized day whose override was cleared',
      () async {
    const day = '2026-08-20';
    await _seedDay(day);
    // Written finalized while the override was in place.
    await LocalDb.putDayResult(
      dayId: day,
      algoVersion: kAlgoVersion,
      payloadJson: '{}',
      windowJson: '{}',
      finalized: true,
    );
    expect(await LocalDb.sleepOverrideDays(), isNot(contains(day)));

    final engine = DerivationEngine();
    await engine.run(_profile, force: true);
    expect(engine.snapshot()['todo_days'], 0,
        reason: 'without the edited day a finalized day is skipped');

    await engine.run(_profile, force: true, editedDays: {day});
    expect(engine.snapshot()['todo_days'], 1);
  });
}
