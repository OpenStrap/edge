// The `day_result` serve seam, and the read-path changes around it.
//
// F-31: `day_result`'s PRIMARY KEY is (day_id, algo_version), so versions are
// SIBLINGS, not replacements. Every reader picked `MAX(algo_version)` with no
// ceiling, which is right on the way UP and wrong on the way DOWN: after a
// downgrade (store rollback, TestFlight → release) a re-derive writes a row at
// the LOWER version that MAX() then ignores forever. Day-detail (reading the
// bundle) and trends (reading the unversioned, always-overwritten
// `metric_series`) end up permanently disagreeing about the same day, and no
// re-derive can repair it.
//
// Plus: the counter index is gone, `sessions.start_ts` is indexed, and
// `decodedRecTsMaxByDay` no longer groups by a function of the column.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:yaml/yaml.dart';

import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion, kAnalyticsPin, kProtocolPin;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/day_label.dart';

Future<void> _put(String dayId, int version, {double? readiness}) =>
    LocalDb.putDayResult(
      dayId: dayId,
      algoVersion: version,
      payloadJson: '{"v":$version}',
      windowJson: '{}',
      readiness: readiness,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The other half of the serve seam: a day_result records the algo version and
  // NOTHING about which analytics/protocol produced it, so two builds pinning
  // different siblings at the same version serve each other's days as
  // equivalent, and the substrate is pruned behind them. That is not detectable
  // at runtime — the only place it can be caught is here, where the pin and the
  // version constant have to agree. Repin, and this goes red on the line above
  // kAlgoVersion.
  test('the sibling pins match the SHAs kAlgoVersion was derived against', () {
    final deps =
        (loadYaml(File('pubspec.yaml').readAsStringSync())
                as Map)['dependencies']
            as Map;
    String ref(String pkg) =>
        ((deps[pkg] as Map)['git'] as Map)['ref'] as String;

    const why =
        'sibling repinned without visiting kAlgoVersion. bump it and say what '
        'moved, or every day already derived at this version is served as if '
        'it came from the new analytics';
    expect(ref('openstrap_analytics'), kAnalyticsPin, reason: why);
    expect(ref('openstrap_protocol'), kProtocolPin, reason: why);

    // AND THE LOCK, which is the file that actually decides what a build
    // resolves. `pubspec.yaml` and the constants agreeing while the lock
    // trails behind is a PARTIAL repin — the exact failure mode the repin
    // comments promise this test catches, and it did not until it read this
    // file. `resolved-ref` too: `ref` alone can name a moved branch.
    final locked =
        (loadYaml(File('pubspec.lock').readAsStringSync()) as Map)['packages']
            as Map;
    String lockRef(String pkg, String field) =>
        ((locked[pkg] as Map)['description'] as Map)[field] as String;

    const whyLock =
        'pubspec.lock disagrees with pubspec.yaml and the pin constants — a '
        'partial repin. Move all three together, or a build resolves a '
        'sibling nobody reasoned about';
    for (final field in const ['ref', 'resolved-ref']) {
      expect(
        lockRef('openstrap_analytics', field),
        kAnalyticsPin,
        reason: whyLock,
      );
      expect(
        lockRef('openstrap_protocol', field),
        kProtocolPin,
        reason: whyLock,
      );
    }
  });

  const name = 'db_serve_version_test.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = name;
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), name),
    );
  });

  group('F-31 — a version from the future is never served', () {
    test('a downgraded build reads its OWN row, not the higher one', () async {
      const day = '2026-08-10';
      await _put(day, kAlgoVersion, readiness: 61);
      // The row a NEWER build left behind before the user rolled back.
      await _put(day, kAlgoVersion + 1, readiness: 99);

      final row = await LocalDb.dayResult(day);
      expect(row, isNotNull);
      expect(
        (row!['algo_version'] as num).toInt(),
        kAlgoVersion,
        reason: 'the future row must not win',
      );
      expect(row['payload_json'], '{"v":$kAlgoVersion}');

      // Every other reader has to agree with dayResult(), or two screens end up
      // showing different numbers for the same day.
      final recent = await LocalDb.recentDayResults(10);
      final served = recent.firstWhere((r) => r['day_id'] == day);
      expect((served['algo_version'] as num).toInt(), kAlgoVersion);

      final meta = await LocalDb.recentDayResultsMeta(10);
      expect(
        (meta.firstWhere((r) => r['day_id'] == day)['algo_version'] as num)
            .toInt(),
        kAlgoVersion,
      );
      expect(
        meta.first.containsKey('payload_json'),
        isFalse,
        reason: 'the meta read must never drag the bundle',
      );

      expect((await LocalDb.dayResultVersions())[day], kAlgoVersion);
      expect(await LocalDb.availableDayIds(), contains(day));
      expect(await LocalDb.dayResultDayIdsDesc(), contains(day));
    });

    test(
      'the future row is kept, not deleted — re-upgrading gets it back',
      () async {
        const day = '2026-08-10';
        final db = await LocalDb.instance;
        final all = await db.query(
          'day_result',
          where: 'day_id = ?',
          whereArgs: [day],
        );
        expect(all, hasLength(2));
      },
    );

    test(
      'a day that ONLY has a future row is served as absent, not wrong',
      () async {
        const day = '2026-08-11';
        await _put(day, kAlgoVersion + 3, readiness: 12);
        expect(await LocalDb.dayResult(day), isNull);
        expect(await LocalDb.availableDayIds(), isNot(contains(day)));
        expect(await LocalDb.dayResultDayIdsDesc(), isNot(contains(day)));
      },
    );

    test('an OLDER version is still served — that is not the bug', () async {
      const day = '2026-08-09';
      await _put(day, kAlgoVersion - 2, readiness: 44);
      final row = await LocalDb.dayResult(day);
      expect(row, isNotNull);
      expect((row!['algo_version'] as num).toInt(), kAlgoVersion - 2);
    });
  });

  group('read-path hygiene', () {
    test(
      'the decoded counter index is gone and sessions.start_ts is indexed',
      () async {
        final db = await LocalDb.instance;
        final idx = await db.rawQuery(
          "SELECT name, tbl_name FROM sqlite_master WHERE type='index'",
        );
        final names = idx.map((r) => r['name']).toSet();
        // Never on a read path: every decoded read orders by (rec_ts, counter),
        // which a single-column counter index cannot serve.
        expect(names, isNot(contains('idx_decoded_onehz_counter')));
        // The most-called uncovered query in the UI seam was a full scan + sort.
        expect(names, contains('idx_sessions_start'));
      },
    );

    test(
      'decodedRecTsMaxByDay matches the strftime grouping it replaced',
      () async {
        final db = await LocalDb.instance;
        await db.delete('decoded_onehz');
        // Three local days' worth of edges, plus a second row per day so the MAX
        // actually has to choose.
        final days = <String>[];
        var t =
            DateTime.now()
                .subtract(const Duration(days: 3))
                .millisecondsSinceEpoch ~/
            1000;
        for (var i = 0; i < 3; i++) {
          final label = dayLabelOf(
            DateTime.fromMillisecondsSinceEpoch(
              t * 1000,
              isUtc: true,
            ).toLocal(),
          );
          days.add(label);
          final start = localDayStartSec(label)!;
          final end = localDayEndSec(label)!;
          for (final ts in [start + 60, end - 90]) {
            await db.insert('decoded_onehz', {
              // v47 key — see _createDecodedStore.
              'ts_ms': ts * 1000,
              'rec_ts': ts,
              'counter': ts,
              'hr': 60,
            });
          }
          t = end + 60;
        }

        final got = await LocalDb.decodedRecTsMaxByDay();
        // The old implementation, verbatim, as the oracle.
        final oracle = await db.rawQuery(
          "SELECT strftime('%Y-%m-%d', rec_ts, 'unixepoch', 'localtime') AS d, "
          'MAX(rec_ts) AS mx FROM decoded_onehz WHERE rec_ts > 0 GROUP BY d',
        );
        final want = {
          for (final r in oracle) r['d'] as String: (r['mx'] as num).toInt(),
        };
        expect(got, want);
        expect(got.keys.toSet(), days.toSet());
      },
    );

    test(
      'decodedRecTsMaxByDay on an empty store is empty, not a 1970 day',
      () async {
        final db = await LocalDb.instance;
        await db.delete('decoded_onehz');
        expect(await LocalDb.decodedRecTsMaxByDay(), isEmpty);
      },
    );

    test('the newest-N reads stay flat as history grows', () async {
      // recentDayResults joined EVERY day's full row (~100 KB of bundle) and
      // sorted them all before its LIMIT, so reading the last 30 days took
      // 57 ms at 30 days of history and 250-600 ms at 730 — on every
      // refreshComputeFreshness, i.e. every derive and every Home load whose
      // night is still building.
      final db = await LocalDb.instance;
      await db.delete('day_result');
      final bundle = '{"pad":"${'x' * 100000}"}';
      final today = DateTime.now();
      Future<void> grow(int days) async {
        final b = db.batch();
        for (var i = 0; i < days; i++) {
          final day = dayLabelOf(
            DateTime(today.year, today.month, today.day - i),
          );
          for (final v in [kAlgoVersion - 1, kAlgoVersion, kAlgoVersion + 1]) {
            // Every third day stops at an older version; the rest also carry a
            // row from a future build, which must never be served.
            if (v == kAlgoVersion && i % 3 == 0) continue;
            b.insert('day_result', {
              'day_id': day,
              'algo_version': v,
              'payload_json': bundle,
              'window_json': '{}',
              'computed_at': 0,
            });
          }
        }
        await b.commit(noResult: true);
      }

      Future<int> medianMs(Future<Object?> Function() f) async {
        await f();
        final us = <int>[];
        for (var i = 0; i < 5; i++) {
          final sw = Stopwatch()..start();
          await f();
          us.add(sw.elapsedMicroseconds);
        }
        us.sort();
        return us[2] ~/ 1000;
      }

      // The query it replaced, verbatim, as the oracle for WHICH rows come back.
      Future<List<Map<String, Object?>>> oracle(int limit) => db.rawQuery(
        'SELECT r.* FROM day_result r '
        'JOIN (SELECT day_id, MAX(algo_version) AS v FROM day_result '
        'WHERE algo_version <= $kAlgoVersion GROUP BY day_id) m '
        'ON r.day_id = m.day_id AND r.algo_version = m.v '
        'ORDER BY r.day_id DESC LIMIT ?',
        [limit],
      );
      List<String> key(List<Map<String, Object?>> rows) => [
        for (final r in rows) '${r['day_id']}@${r['algo_version']}',
      ];

      await grow(600);
      expect(key(await LocalDb.recentDayResults(30)), key(await oracle(30)));
      expect(
        key(await LocalDb.recentDayResultsMeta(30)),
        key(await oracle(30)),
      );

      // Against the old query, timed back to back on the same machine, so a
      // slow or loaded runner slows both sides alike. On 600 days the old one
      // sorts ~60 MB of bundles to return 30; measured ~10x slower.
      final now = await medianMs(() => LocalDb.recentDayResults(30));
      final before = await medianMs(() => oracle(30));
      expect(
        now * 3,
        lessThanOrEqualTo(before),
        reason:
            'recentDayResults(30) took $now ms at 600 days of history, '
            'the full-history sort it replaced $before ms',
      );
      await db.delete('day_result');
    });
  });
}
