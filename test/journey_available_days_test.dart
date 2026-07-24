// availableDays() over the REAL LocalDb (in-memory sqlite via
// sqflite_common_ffi): the RENDERABLE-day range that bounds the lookback
// screen's day navigation (issue #112). availableDayIds must return EXACTLY the
// days `getDayTimeline`/`_bundleForDate` would render non-empty — the latest
// derived `day_result` per day that is NOT a skip-marker — and must EXCLUDE
// raw-only `decoded_onehz` days and skip-markers (both render empty).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_available_days_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> seedDerived(String dayId, {int algoVersion = 15}) =>
      LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: algoVersion,
        payloadJson: jsonEncode({
          'scalars': {'rhr': 52.0},
        }),
        windowJson: '{}',
        finalized: false,
      );

  // A derivation skip-marker, exactly as `_markDaySkipped` writes it: the
  // `skipped` column set alongside the `{skipped:true}` payload.
  Future<void> seedSkip(String dayId, {int algoVersion = 15}) =>
      LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: algoVersion,
        payloadJson: jsonEncode({'skipped': true, 'reason': 'test'}),
        windowJson: '{}',
        finalized: false,
        skipped: true,
      );

  Future<void> seedRawSecond(DateTime localNoon, int counter) {
    final ts = localNoon.millisecondsSinceEpoch ~/ 1000;
    return LocalDb.insertRecord(
      RawRecord(
        counter: counter,
        packetType: 47,
        hex: 'deadbeef',
        capturedAt: ts * 1000,
        recTs: ts,
      ),
      Sample(
        tsEpoch: ts,
        counter: counter,
        hr: 60,
        ax: 0,
        ay: 0,
        az: 1,
        spo2RedRaw: 1,
        spo2IrRaw: 1,
        skinTempRaw: 1,
      ),
    );
  }

  test('returns only genuine derived days; excludes raw-only + skip-markers',
      () async {
    await seedDerived('2099-01-05');
    await seedDerived('2099-01-03');
    await seedDerived('2099-01-01');

    // A skip-marker day — renders empty, must NOT bound navigation.
    await seedSkip('2099-01-06');

    // A RAW-ONLY day (decoded_onehz, no derived row) — also renders empty.
    // Local noon so its calendar-day label is unambiguous in every timezone.
    await seedRawSecond(DateTime(2099, 1, 4, 12), 990004);
    final rawDay = dayLabelOf(DateTime(2099, 1, 4, 12));
    expect(rawDay, '2099-01-04');

    final days = await LocalDb.availableDayIds();

    // Exactly the three genuine derived days, newest → oldest.
    expect(days, ['2099-01-05', '2099-01-03', '2099-01-01']);
    expect(days.contains('2099-01-06'), isFalse, reason: 'skip-marker excluded');
    expect(days.contains(rawDay), isFalse, reason: 'raw-only day excluded');
  });

  test('a derived day that also has raw seconds appears exactly once', () async {
    // '2099-01-03' already has a derived row; adding raw seconds must not
    // duplicate it (and must not resurrect anything via a raw path).
    await seedRawSecond(DateTime(2099, 1, 3, 12), 990003);
    final days = await LocalDb.availableDayIds();
    expect(days.where((d) => d == '2099-01-03').length, 1);
  });

  test('the LATEST algo_version decides skip vs render', () async {
    // Superseded-by-skip: real v15 then skip v16 → latest is skip → EXCLUDED.
    await seedDerived('2099-02-10', algoVersion: 15);
    await seedSkip('2099-02-10', algoVersion: 16);

    // Recovered-from-skip: skip v15 then real v16 → latest is real → INCLUDED.
    await seedSkip('2099-02-11', algoVersion: 15);
    await seedDerived('2099-02-11', algoVersion: 16);

    final days = await LocalDb.availableDayIds();
    expect(days.contains('2099-02-10'), isFalse);
    expect(days.contains('2099-02-11'), isTrue);
  });

  test('LocalRepositoryImpl.availableDays surfaces the same renderable range',
      () async {
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final days = await repo.availableDays();
    expect(days.first, '2099-02-11'); // newest genuine derived day
    expect(days.contains('2099-01-04'), isFalse); // raw-only
    expect(days.contains('2099-01-06'), isFalse); // skip-marker
    expect(days, containsAll(['2099-01-05', '2099-01-03', '2099-01-01']));
  });

  test('empty DB (no derived days) yields an empty range', () async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    LocalDb.dbName = 'openstrap_available_days_empty_test.db';
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));

    // Raw seconds alone (no derived day_result) must NOT make a day available.
    await seedRawSecond(DateTime(2099, 3, 1, 12), 991001);
    final days = await LocalDb.availableDayIds();
    expect(days, isEmpty);

    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    LocalDb.dbName = 'openstrap_available_days_test.db';
  });
}
