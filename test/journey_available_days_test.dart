// availableDays() over the REAL LocalDb (in-memory sqlite via
// sqflite_common_ffi): the recorded-day range that bounds the lookback screen's
// day navigation (issue #112). Covers the UNION of derived `day_result` rows
// and raw `decoded_onehz` seconds, newest-first ordering, and the repository
// wrapper that the screen actually calls.

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

  Future<void> seedDayResult(String dayId) => LocalDb.putDayResult(
        dayId: dayId,
        algoVersion: 15,
        payloadJson: jsonEncode({
          'scalars': {'rhr': 52.0},
        }),
        windowJson: '{}',
        finalized: false,
      );

  test('availableDayIds unions derived days + raw-only days, newest first',
      () async {
    // Three derived days (literal day_id labels, timezone-independent) …
    await seedDayResult('2099-01-05');
    await seedDayResult('2099-01-03');
    await seedDayResult('2099-01-01');

    // … plus a RAW-ONLY day (decoded_onehz, no day_result). Seed a frame at
    // local noon so its calendar-day label is unambiguous in every timezone,
    // and derive the expected label the same way the app buckets raw seconds.
    final rawDt = DateTime(2099, 1, 4, 12, 0);
    final rawTs = rawDt.millisecondsSinceEpoch ~/ 1000;
    final rawDay = dayLabelOf(rawDt); // '2099-01-04'
    await LocalDb.insertRecord(
      RawRecord(
        counter: 990004,
        packetType: 47,
        hex: 'deadbeef',
        capturedAt: rawTs * 1000,
        recTs: rawTs,
      ),
      Sample(
        tsEpoch: rawTs,
        counter: 990004,
        hr: 60,
        rrIntervalsMs: const [1000],
        ax: 0,
        ay: 0,
        az: 1,
        spo2RedRaw: 1,
        spo2IrRaw: 1,
        skinTempRaw: 1,
      ),
    );

    final days = await LocalDb.availableDayIds();

    // Exactly the four seeded days, newest → oldest, with the raw-only day
    // slotted in by date (not appended) — proof the UNION + ORDER BY hold.
    expect(days, ['2099-01-05', rawDay, '2099-01-03', '2099-01-01']);
    expect(rawDay, '2099-01-04');
  });

  test('a day with BOTH a derived row and raw seconds appears once', () async {
    // Add raw seconds for an already-derived day → UNION must de-duplicate it.
    final dt = DateTime(2099, 1, 3, 12, 0);
    final ts = dt.millisecondsSinceEpoch ~/ 1000;
    await LocalDb.insertRecord(
      RawRecord(
        counter: 990003,
        packetType: 47,
        hex: 'cafe',
        capturedAt: ts * 1000,
        recTs: ts,
      ),
      Sample(
        tsEpoch: ts,
        counter: 990003,
        hr: 61,
        ax: 0,
        ay: 0,
        az: 1,
        spo2RedRaw: 1,
        spo2IrRaw: 1,
        skinTempRaw: 1,
      ),
    );

    final days = await LocalDb.availableDayIds();
    expect(days.where((d) => d == '2099-01-03').length, 1);
  });

  test('LocalRepositoryImpl.availableDays surfaces the same range', () async {
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    final days = await repo.availableDays();
    expect(days.first, '2099-01-05'); // newest
    expect(days.last, '2099-01-01'); // oldest
    expect(days, containsAll(['2099-01-04', '2099-01-03', '2099-01-01']));
  });

  test('empty DB (no data) yields an empty range', () async {
    // A fresh, separate DB so nothing seeded above leaks in.
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    LocalDb.dbName = 'openstrap_available_days_empty_test.db';
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));

    final days = await LocalDb.availableDayIds();
    expect(days, isEmpty);

    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    LocalDb.dbName = 'openstrap_available_days_test.db';
  });
}
