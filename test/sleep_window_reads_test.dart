// Sleep-window reads must stop after the newest N served, non-skipped days.
// The original whole-history query remains the correctness and timing oracle.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion;
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<List<Map<String, Object?>>> _original(
  int limit, {
  String? before,
}) async {
  final db = await LocalDb.instance;
  return db.rawQuery(
    'SELECT r.day_id AS day_id, r.window_json AS window_json '
    'FROM day_result r '
    'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result '
    'WHERE algo_version <= $kAlgoVersion GROUP BY day_id) m '
    'ON r.day_id = m.day_id AND r.algo_version = m.v '
    'WHERE r.skipped = 0 '
    '${before == null ? '' : 'AND r.day_id < ? '}'
    'ORDER BY r.day_id DESC LIMIT ?',
    [?before, limit],
  );
}

Map<String, Object?> _row(
  String day,
  int version, {
  bool skipped = false,
  String payload = '{}',
  String? window,
}) => {
  'day_id': day,
  'algo_version': version,
  'payload_json': payload,
  'window_json': window ?? jsonEncode({'day': day, 'version': version}),
  'computed_at': 0,
  'skipped': skipped ? 1 : 0,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const name = 'sleep_window_reads_test.db';

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  setUp(() async {
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  test('empty history and an exclusive before bound return no rows', () async {
    expect(await LocalDb.sleepWindowRows(60), isEmpty);
    final db = await LocalDb.instance;
    await db.insert('day_result', _row('2026-07-01', kAlgoVersion));
    expect(await LocalDb.sleepWindowRows(60, before: '2026-07-01'), isEmpty);
    expect(await LocalDb.sleepWindowRows(0), isEmpty);
  });

  test(
    'versions, skipped days, bounds and limits match the original query',
    () async {
      final db = await LocalDb.instance;
      final batch = db.batch();
      for (final row in [
        _row('2026-07-01', kAlgoVersion - 2),
        _row('2026-07-02', kAlgoVersion),
        // A skipped served version must not fall back to an older real result.
        _row('2026-07-03', kAlgoVersion - 1),
        _row('2026-07-03', kAlgoVersion, skipped: true),
        // A future-only day is absent, and a future skip cannot hide ours.
        _row('2026-07-04', kAlgoVersion + 1),
        _row('2026-07-05', kAlgoVersion),
        _row('2026-07-05', kAlgoVersion + 1, skipped: true),
        // Empty windows still count toward the limit, as they always did.
        _row('2026-07-06', kAlgoVersion, window: '{}'),
        _row('2026-07-07', kAlgoVersion - 1, skipped: true),
        _row('2026-07-07', kAlgoVersion),
        _row('2026-07-08', kAlgoVersion - 2),
        _row('2026-07-08', kAlgoVersion - 1),
      ]) {
        batch.insert('day_result', row);
      }
      await batch.commit(noResult: true);

      for (final before in [null, '2026-07-08', '2026-07-05', '2026-07-01']) {
        for (final limit in [0, 1, 2, 4, 20, -1]) {
          expect(
            await LocalDb.sleepWindowRows(limit, before: before),
            await _original(limit, before: before),
            reason: 'limit=$limit, before=$before',
          );
        }
      }
      final rows = await LocalDb.sleepWindowRows(60);
      expect(rows.map((r) => r['day_id']), [
        '2026-07-08',
        '2026-07-07',
        '2026-07-06',
        '2026-07-05',
        '2026-07-02',
        '2026-07-01',
      ]);
      for (final row in rows) {
        expect(row.keys, unorderedEquals(['day_id', 'window_json']));
      }
    },
  );

  test(
    'skipped and future-only days do not consume the requested limit',
    () async {
      final db = await LocalDb.instance;
      final batch = db.batch();
      for (var i = 0; i < 100; i++) {
        final day = dayLabelOf(DateTime(2026, 1, 1 + i));
        batch.insert('day_result', _row(day, kAlgoVersion - 1));
        batch.insert('day_result', _row(day, kAlgoVersion, skipped: i >= 10));
        batch.insert('day_result', _row(day, kAlgoVersion + 1));
      }
      for (var i = 100; i < 120; i++) {
        batch.insert(
          'day_result',
          _row(dayLabelOf(DateTime(2026, 1, 1 + i)), kAlgoVersion + 1),
        );
      }
      await batch.commit(noResult: true);
      final rows = await LocalDb.sleepWindowRows(5);
      expect(rows, hasLength(5));
      expect(rows.map((r) => r['day_id']), [
        '2026-01-10',
        '2026-01-09',
        '2026-01-08',
        '2026-01-07',
        '2026-01-06',
      ]);
      expect(rows, await _original(5));
    },
  );

  test(
    'bounded sleep-window reads avoid the whole-history read cost',
    () async {
      final db = await LocalDb.instance;
      // Real bundles carry curves and hypnograms; reading late columns in those
      // rows costs more than grouping tiny placeholder rows would reveal.
      final payload = jsonEncode({'curve': List.filled(25000, 100)});
      var seeded = 0;
      for (final days in [30, 365, 730]) {
        await db.transaction((txn) async {
          final batch = txn.batch();
          for (var i = seeded; i < days; i++) {
            final day = dayLabelOf(DateTime(2024, 1, 1 + i));
            for (final version in [
              kAlgoVersion - 1,
              kAlgoVersion,
              kAlgoVersion + 1,
            ]) {
              batch.insert(
                'day_result',
                _row(day, version, skipped: i % 7 == 0, payload: payload),
              );
            }
          }
          await batch.commit(noResult: true);
        });
        seeded = days;
        // Also exercise the before-bound path on a long, versioned history.
        final before = dayLabelOf(DateTime(2024, 1, days - 10));
        for (final bound in [null, before]) {
          expect(
            await LocalDb.sleepWindowRows(60, before: bound),
            await _original(60, before: bound),
          );
          final oldTimes = <int>[], newTimes = <int>[];
          Future<void> measure(bool original) async {
            final clock = Stopwatch()..start();
            if (original) {
              await _original(60, before: bound);
            } else {
              await LocalDb.sleepWindowRows(60, before: bound);
            }
            (original ? oldTimes : newTimes).add(clock.elapsedMicroseconds);
          }

          // Alternate the order so neither implementation always gets a cache
          // warmed by the other. The equality checks above warm up both first.
          for (var i = 0; i < 9; i++) {
            await measure(i.isEven);
            await measure(i.isOdd);
          }
          oldTimes.sort();
          newTimes.sort();
          final oldUs = oldTimes[oldTimes.length ~/ 2];
          final newUs = newTimes[newTimes.length ~/ 2];
          // ignore: avoid_print
          print(
            'sleepWindowRows: history=$days, before=$bound, '
            'original=$oldUs us, bounded=$newUs us',
          );
          if (days == 730) {
            expect(
              newUs * 3,
              lessThan(oldUs),
              reason: 'the bounded read should avoid fetching every old bundle',
            );
          }
        }
      }
    },
  );
}
