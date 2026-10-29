// DATABASE GROWTH + LOAD-TIME SOAK. Opt-in: a full simulated day costs ~15 s
// on a laptop, so this never runs in the default `flutter test`.
//
//   OPENSTRAP_SOAK=1 flutter test test/db_growth_soak_test.dart
//
// Knobs (all optional):
//   SOAK_DAYS          live days to simulate through the real ingest (14)
//   SOAK_DEVICE        gen4, or mg: a WHOOP MG also banks the undecodable
//                      `undecodable_rec_v20` frames, ~45 MB/day at full rate
//                      (measured, see LocalDb.thinRawArchiveBefore) (gen4)
//   SOAK_HISTORY       history lengths, in days, to time loads at
//                      (30,180,365,730)
//   SOAK_BUDGET_MB     steady-state growth budget, MB per day (3)
//   SOAK_MAX_RATIO     longest-history / shortest-history load time, per
//                      load, plus 25 ms of absolute slack (2)
//
// WHAT IS REAL AND WHAT IS NOT.
//   * Every simulated day goes through `LocalDb.commitSyncBatch` — the same
//     ACK-gating commit a WHOOP drain uses — from [SyntheticDay]'s 1 Hz day,
//     so samples, decoded_onehz, decoded_rr and the coverage tables are
//     written exactly as on a phone.
//   * Then `DerivationEngine().run(heavy: true)`, which is what runs after a
//     sync. Its raw prune, substrate archive and storage housekeeping are the
//     production code paths.
//   * Then `LocalDb.vacuumIfBloated()`, as `_maybeReclaimDiskSpace` does once
//     per launch after a foreground heavy derive (one launch per day here).
//   * NOT REAL: the analytics. A real derive costs ~75 s per day under
//     `flutter test`, so ONE day is derived for real and its per-day rows
//     (day_result, metric_series, …) are cloned onto every other day and
//     marked finalized. That makes the engine take its "all days finalized"
//     branch, which still prunes. A healthy install prunes at the same cutoff:
//     its unfinalized days are the newest ones, inside the retention window.
//     The stuck-day hold is pure and covered by raw_prune_gating_test.
//   * NOT REAL either: the cloned rows keep the template day's timestamps
//     inside their payloads, and the cloned substrate_archive buckets keep
//     the template's blob. Nothing timed here decodes either; they stand in
//     for the bytes and the row counts, which is what this measures.
//
// The per-day numbers land in build/soak/db_growth.csv.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart' show ArchiveRecord;
import 'package:openstrap_edge/ui2/screens/home_screen.dart' show HomeData;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/app_state_derive_harness.dart';
import 'support/synthetic_day.dart';

const Profile _profile = Profile(
  ageYears: 32,
  weightKg: 72,
  heightCm: 176,
  sex: 'm',
);

const String _dbName = 'db_growth_soak_test.db';

/// Tables a derive writes one generation of per day, and their day column.
const List<(String, String)> _perDayTables = [
  ('day_result', 'day_id'),
  ('metric_series', 'date'),
  ('metric_series_version', 'date'),
  ('sleep_session_candidates', 'day_id'),
  ('wake_day_features', 'day_id'),
];

final Map<String, String> _env = Platform.environment;
int _int(String k, int d) => int.tryParse(_env[k] ?? '') ?? d;
double _num(String k, double d) => double.tryParse(_env[k] ?? '') ?? d;

const double _mb = 1024 * 1024;

/// The real MG export banked 115,672 `undecodable_rec_v20` frames of 4,256
/// hex chars in 11 days (see LocalDb.thinRawArchiveBefore).
const int _mgFramesPerDay = 115672 ~/ 11;
const int _mgFrameHexChars = 4256;

/// Deterministic, incompressible-looking frame bytes, unique per [counter].
String _mgFrameHex(int counter) {
  final out = StringBuffer(counter.toRadixString(16).padLeft(8, '0'));
  var x = counter * 2654435761 + 1;
  while (out.length < _mgFrameHexChars) {
    x = (x * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFF;
    out.write((x >> 16).toRadixString(16).padLeft(8, '0'));
  }
  return out.toString().substring(0, _mgFrameHexChars);
}

/// One row of the growth report.
class _Snap {
  _Snap(
    this.day,
    this.fileBytes,
    this.usedBytes,
    this.freeBytes,
    this.walBytes,
    this.onehzRows,
    this.tables,
    this.dayMs,
  );
  final int day;
  final int fileBytes, usedBytes, freeBytes, walBytes, onehzRows;
  final Map<String, int> tables;
  final int dayMs;
}

void main() {
  final enabled = _env['OPENSTRAP_SOAK'] == '1';
  final skip = enabled ? null : 'set OPENSTRAP_SOAK=1 to run the soak';

  final liveDays = _int('SOAK_DAYS', 14);
  final mg = _env['SOAK_DEVICE'] == 'mg';
  var mgCounter = 0;
  // Steady state: retention plus the night lookback plus a day of slack.
  final warmup = rawRetentionDays + 3;
  final today = DateTime.now();
  // The last simulated day ends yesterday 22:00, so "today" in the app's sense
  // is the morning after the newest synced night.
  final first = DateTime(today.year, today.month, today.day - liveDays);
  final history =
      (_env['SOAK_HISTORY'] ?? '30,180,365,730')
          .split(',')
          .map(int.parse)
          .toSet()
          .toList()
        ..sort();
  final snaps = <_Snap>[];
  late String template;
  late String path;
  var committedTo = 0;

  Future<Database> db() => LocalDb.instance;

  Future<void> ingest(SyntheticDay day) async {
    for (final (raws, samples) in day.primaryBatches()) {
      // Consecutive synthetic days overlap 18:00–22:00; a band never sends
      // the same second twice, so neither does this.
      final keep = [
        for (var j = 0; j < raws.length; j++)
          if (raws[j].recTs! > committedTo) j,
      ];
      if (keep.isEmpty) continue;
      final at = raws[keep.first].recTs! * 1000;
      await LocalDb.commitSyncBatch(
        [for (final j in keep) raws[j]],
        [for (final j in keep) samples[j]],
        archives: !mg
            ? null
            : [
                for (var k = 0; k < keep.length * _mgFramesPerDay ~/ 86400; k++)
                  ArchiveRecord(
                    counter: ++mgCounter,
                    hex: _mgFrameHex(mgCounter),
                    packetType: 0x2F,
                    capturedAt: at,
                    reason: 'undecodable_rec_v20',
                  ),
              ],
        // The substrate stays gen4 in both scenarios so the template derive
        // is the same; the MG scenario differs only in the banked frames.
        deviceFamily: 'gen4',
      );
      committedTo = raws[keep.last].recTs!;
    }
  }

  Future<void> cloneDay(String from, String to) async {
    final d = await db();
    for (final (table, col) in _perDayTables) {
      final cols = [
        for (final r in await d.rawQuery('PRAGMA table_info($table)'))
          r['name'] as String,
      ];
      final select = [for (final c in cols) c == col ? '?' : c].join(', ');
      await d.rawInsert(
        'INSERT OR REPLACE INTO $table (${cols.join(', ')}) '
        'SELECT $select FROM $table WHERE $col = ?',
        [to, from],
      );
    }
  }

  /// Give every day that still has substrate a finalized result at the
  /// current algorithm version — a cloned one if it has none.
  Future<void> finalizeRawDays() async {
    final d = await db();
    for (final day in (await LocalDb.decodedRecTsMaxByDay()).keys) {
      final has = await d.query(
        'day_result',
        columns: ['day_id'],
        where: 'day_id = ? AND algo_version = ?',
        whereArgs: [day, kAlgoVersion],
      );
      if (has.isEmpty) await cloneDay(template, day);
    }
    await d.update('day_result', {'finalized': 1});
  }

  Future<Map<String, int>> tableBytes() async {
    final d = await db();
    try {
      final rows = await d.rawQuery(
        'SELECT m.tbl_name AS t, SUM(s.pgsize) AS b FROM dbstat s '
        'JOIN sqlite_master m ON m.name = s.name GROUP BY m.tbl_name',
      );
      return {for (final r in rows) r['t'] as String: (r['b'] as num).toInt()};
    } catch (_) {
      // No dbstat in this SQLite build: the table-only estimate.
      return {
        for (final r in await LocalDb.tableStorageStats())
          r['table'] as String: (r['bytes'] as num?)?.toInt() ?? 0,
      };
    }
  }

  Future<_Snap> snapshot(int day, int dayMs) async {
    final d = await db();
    Future<int> pragma(String q) async =>
        ((await d.rawQuery('PRAGMA $q')).first.values.first as num).toInt();
    final pageSize = await pragma('page_size');
    final pages = await pragma('page_count');
    final free = await pragma('freelist_count');
    final wal = File('$path-wal');
    final onehz =
        (await d.rawQuery('SELECT COUNT(*) AS n FROM decoded_onehz')).first['n']
            as int;
    return _Snap(
      day,
      File(path).lengthSync(),
      (pages - free) * pageSize,
      free * pageSize,
      wal.existsSync() ? wal.lengthSync() : 0,
      onehz,
      await tableBytes(),
      dayMs,
    );
  }

  void writeReport() {
    final tables = <String>{for (final s in snaps) ...s.tables.keys}.toList()
      ..sort((a, b) => snaps.last.tables[b]!.compareTo(snaps.last.tables[a]!));
    final out = File('build/soak/db_growth.csv')..createSync(recursive: true);
    out.writeAsStringSync(
      [
        'day,day_ms,file_mb,used_mb,freelist_mb,wal_mb,onehz_rows,'
            '${tables.map((t) => '${t}_mb').join(',')}',
        for (final s in snaps)
          [
            s.day,
            s.dayMs,
            for (final b in [s.fileBytes, s.usedBytes, s.freeBytes, s.walBytes])
              (b / _mb).toStringAsFixed(2),
            s.onehzRows,
            for (final t in tables)
              ((s.tables[t] ?? 0) / _mb).toStringAsFixed(2),
          ].join(','),
      ].join('\n'),
    );
    // ignore: avoid_print
    print('[soak] report: ${out.absolute.path}');
  }

  setUpAll(() async {
    if (!enabled) return;
    // Checked here, not after the hours-long growth run. A single length
    // compares a history with itself, and live days beyond the shortest
    // length would give it more history than its label says.
    expect(
      history.length,
      greaterThanOrEqualTo(2),
      reason: 'SOAK_HISTORY needs two or more distinct lengths',
    );
    expect(
      history.first,
      greaterThanOrEqualTo(liveDays),
      reason: 'SOAK_HISTORY lengths must be at least SOAK_DAYS',
    );
    await deriveDbSetUp(_dbName);
    path = p.join(await databaseFactory.getDatabasesPath(), _dbName);
    // The template: one fully-synced night, derived for real.
    await ingest(SyntheticDay(first, seed: 1));
    await ingest(
      SyntheticDay(DateTime(first.year, first.month, first.day + 1), seed: 2),
    );
    template = dayLabelOf(first);
    await DerivationEngine().runDays(_profile, {template}, force: true);
    expect(
      await LocalDb.dayResult(template),
      isNotNull,
      reason: 'the template day did not derive',
    );
  });

  tearDownAll(() async {
    if (enabled) await deriveDbTearDown(_dbName);
  });

  test(
    'storage levels off once the retention prune is running',
    () async {
      expect(
        liveDays,
        greaterThanOrEqualTo(warmup + 4),
        reason:
            'SOAK_DAYS must leave a steady-state window after $warmup '
            'warm-up days',
      );
      for (var i = 2; i < liveDays; i++) {
        final sw = Stopwatch()..start();
        await ingest(
          SyntheticDay(
            DateTime(first.year, first.month, first.day + i),
            seed: 1 + i,
          ),
        );
        await finalizeRawDays();
        await DerivationEngine().run(_profile, heavy: true);
        await LocalDb.vacuumIfBloated();
        final s = await snapshot(i, sw.elapsedMilliseconds);
        snaps.add(s);
        // ignore: avoid_print
        print(
          '[soak] day $i: used ${(s.usedBytes / _mb).toStringAsFixed(1)} MB'
          ', file ${(s.fileBytes / _mb).toStringAsFixed(1)} MB'
          ', free ${(s.freeBytes / _mb).toStringAsFixed(1)} MB'
          ', wal ${(s.walBytes / _mb).toStringAsFixed(1)} MB'
          ', onehz ${s.onehzRows} rows, ${s.dayMs} ms',
        );
      }
      writeReport();

      final steady = snaps.where((s) => s.day >= warmup).toList();
      final base = steady.first;
      // Every check runs and every miss is reported, so one failure cannot
      // hide another.
      final problems = <String>[];
      String mb(int b) => (b / _mb).toStringAsFixed(0);
      // 1. The live substrate stops growing: it is capped at the retention
      //    window, so its row count plateaus instead of climbing a day at a time.
      final grown = steady.lastWhere(
        (s) => s.onehzRows > base.onehzRows * 1.15,
        orElse: () => base,
      );
      if (grown != base) {
        problems.add(
          'decoded_onehz still growing: ${grown.onehzRows} rows on '
          'day ${grown.day} vs ${base.onehzRows} on day ${base.day}',
        );
      }
      // 2. What the phone actually holds — the file plus its -wal — stays near
      //    what the data needs. Freed pages are reused and a bloated file is
      //    VACUUMed, but in WAL mode that VACUUM writes the whole database
      //    through the -wal, and SQLite only shrinks a -wal on a clean close or
      //    with `journal_size_limit` set.
      final bloated = steady.where(
        (s) => s.fileBytes + s.walBytes > s.usedBytes * 1.25 + 32 * _mb,
      );
      if (bloated.isNotEmpty) {
        final s = bloated.last;
        problems.add(
          '${bloated.length} of ${steady.length} days hold more on '
          'disk than the data needs; day ${s.day}: '
          '${mb(s.fileBytes + s.walBytes)} MB (file ${mb(s.fileBytes)} + wal '
          '${mb(s.walBytes)}) for ${mb(s.usedBytes)} MB of data',
        );
      }
      // 3. What does keep growing (derived history, the compressed archive)
      //    grows slowly. Least-squares slope of used bytes per day.
      final n = steady.length;
      final mx = steady.map((s) => s.day).reduce((a, b) => a + b) / n;
      final my = steady.map((s) => s.usedBytes).reduce((a, b) => a + b) / n;
      var sxy = 0.0, sxx = 0.0;
      for (final s in steady) {
        sxy += (s.day - mx) * (s.usedBytes - my);
        sxx += (s.day - mx) * (s.day - mx);
      }
      final slopeMb = sxy / sxx / _mb;
      final budget = _num('SOAK_BUDGET_MB', 3);
      // ignore: avoid_print
      print(
        '[soak] steady-state growth ${slopeMb.toStringAsFixed(2)} MB/day; '
        'one year from here: '
        '${((snaps.last.usedBytes / _mb) + slopeMb * 365).toStringAsFixed(0)}'
        ' MB',
      );
      if (slopeMb > budget) {
        problems.add(
          'steady-state growth ${slopeMb.toStringAsFixed(2)} MB/day '
          'is over the ${budget.toStringAsFixed(1)} MB/day budget — '
          'build/soak/db_growth.csv shows which table grew',
        );
      }
      if (problems.isNotEmpty) fail(problems.join('\n'));
    },
    skip: skip,
    timeout: const Timeout(Duration(hours: 6)),
  );

  test(
    'launch and home load times do not grow with history',
    () async {
      expect(
        snaps,
        isNotEmpty,
        reason: 'run the whole file: this extends the growth run\'s database',
      );
      final repo = LocalRepositoryImpl(
        getProfileMap: () => {
          'age': 32,
          'weight_kg': 72,
          'height_cm': 176,
          'sex': 'm',
        },
      );
      final archived = await (await db()).query(
        'substrate_archive',
        orderBy: 'utc_day DESC',
        limit: 1,
      );
      final edgeDay = committedTo ~/ 86400;
      var oldest = first;

      // Ages the install to [days] of history: older days get a derived
      // result and, inside the archive's keep window, an archived bucket —
      // what a long-time user's database holds for a day with no substrate.
      Future<void> extendHistoryTo(int days) async {
        final d = await db();
        final target = DateTime(today.year, today.month, today.day - days);
        while (oldest.isAfter(target)) {
          oldest = DateTime(oldest.year, oldest.month, oldest.day - 1);
          final label = dayLabelOf(oldest);
          await cloneDay(template, label);
          final utcDay =
              DateTime.utc(
                oldest.year,
                oldest.month,
                oldest.day,
              ).millisecondsSinceEpoch ~/
              86400000;
          if (archived.isNotEmpty && edgeDay - utcDay <= 365) {
            final a = archived.first;
            final shift = ((a['utc_day'] as int) - utcDay) * 86400;
            await d.insert('substrate_archive', {
              ...a,
              'utc_day': utcDay,
              'from_ts': (a['from_ts'] as int) - shift,
              'to_ts': (a['to_ts'] as int) - shift,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
        await d.update('day_result', {'finalized': 1});
      }

      Future<int> medianMs(Future<void> Function() body) async {
        await body(); // warm the page cache like a second launch would
        final ms = <int>[];
        for (var i = 0; i < 5; i++) {
          final sw = Stopwatch()..start();
          await body();
          ms.add(sw.elapsedMilliseconds);
        }
        ms.sort();
        return ms[2];
      }

      final loads = <String, Future<void> Function()>{
        // What AppState._initSteps reads off a cold database.
        'launch': () async {
          await LocalDb.close();
          await LocalDb.instance;
          await LocalDb.latestSample();
          await LocalDb.refreshComputeFreshness();
        },
        // What the home screen awaits before it draws (HomeData.load and the
        // day switcher), whole and by part, so a failure names its query.
        'home': () async {
          await HomeData.load(repo);
          await repo.availableDays();
        },
        'home.today': () => repo.getToday(),
        'home.insights': () => repo.getInsights(),
        'home.days': () => repo.availableDays(),
        // The trend charts read the whole metric series.
        'trends': () async {
          await repo.getChart('readiness');
          await repo.getChart('hrv');
        },
      };

      final results = <int, Map<String, int>>{};
      for (final days in history) {
        await extendHistoryTo(days);
        // One real pass so housekeeping (archive eviction) sees the new history.
        await DerivationEngine().run(_profile, heavy: true);
        // A load that got fast by coming back empty is not a pass.
        expect(
          (await HomeData.load(repo)).dayId,
          isNotNull,
          reason: 'Home has no day at $days days of history',
        );
        expect(await repo.getToday(), isNotEmpty);
        expect((await repo.availableDays()).length, greaterThanOrEqualTo(days));
        results[days] = {
          for (final e in loads.entries) e.key: await medianMs(e.value),
        };
        // ignore: avoid_print
        print(
          '[soak] $days days of history, '
          '${(File(path).lengthSync() / _mb).toStringAsFixed(0)} MB: '
          '${results[days]}',
        );
      }

      final ratio = _num('SOAK_MAX_RATIO', 2);
      // Absolute slack, so a 3 ms load going to 9 ms is not a failure.
      const slackMs = 25;
      final shortest = results[history.first]!,
          longest = results[history.last]!;
      final slow = [
        for (final k in loads.keys)
          if (longest[k]! > shortest[k]! * ratio + slackMs)
            '$k: ${shortest[k]} ms at ${history.first} days of history, '
                '${longest[k]} ms at ${history.last}',
      ];
      if (slow.isNotEmpty) fail(slow.join('\n'));
    },
    skip: skip,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
