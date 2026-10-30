// Regression tests for NOOP CSV schema drift (OpenStrap/edge#160).
//
// NOOP shipped a schema change that these tests pin:
//   • `band_sleep_state` INSERTED at index 15, shifting event_kind/event_payload
//     to 16/17 — the importer must keep reading by NAME, not position.
//   • new streams `steps` / `band_sleep_state` / `ppghr`.
//   • `spo2` and `resp` rows no longer emitted at all.
//
// Before this, `steps` fell into the importer's default branch: every imported
// day reported 0 steps while the band's own counter had measured thousands.
//
// There was no test that parsed a real NOOP CSV at all — only the pure
// `decideRow` ordering contract — which is why the drift shipped unnoticed.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/noop_import.dart';

/// The CURRENT NOOP header — `band_sleep_state` at 15, event_* shifted to 16/17.
const _header = 'unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,'
    'step_counter,ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,'
    'band_sleep_state,event_kind,event_payload';

/// Build one long-format row with only [stream]'s columns filled.
String _row(int ts, String stream,
    {String hr = '',
    String rr = '',
    String gx = '',
    String gy = '',
    String gz = '',
    String stepCounter = '',
    String skinTemp = '',
    String sleepState = '',
    String eventKind = '',
    String eventPayload = ''}) {
  final iso = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
      .toIso8601String();
  return [
    '$ts', iso, stream, hr, rr, gx, gy, gz, stepCounter, '', '', '', '',
    skinTemp, '', sleepState, eventKind, eventPayload,
  ].join(',');
}


/// `payload_json` nests some sections as encoded strings and some as maps,
/// depending on which writer produced them — decode either shape.
Map<String, dynamic>? _section(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is String) {
    try {
      final d = jsonDecode(v);
      if (d is Map<String, dynamic>) return d;
    } on FormatException {
      // A rendered value ("—"), not an encoded section.
    }
  }
  return null;
}

/// Beats the RR pipeline actually used for [day], or null if it did not run.
int? _beatsUsed(Map<String, Object?> row) {
  final payload = _section(row['payload_json']);
  final irregular = _section(_section(payload?['clinical'])?['irregular_24h']);
  return _section(irregular?['value'])?['n_beats'] as int?;
}

void main() {
  group('stepRuns — cumulative counter → real step windows (pure)', () {
    test('sums positive deltas across one contiguous run', () {
      // 100 → 130 over 4 s = 30 steps, one window.
      final runs = NoopImporter.stepRuns({0: 100, 1: 110, 2: 120, 3: 130});
      expect(runs, [const StepRun(0, 3, 30)]);
    });

    test('splits on a gap wider than stepRunMaxGapSec', () {
      // The #160 export has a 20.5 h hole; a single window spanning it would
      // claim to cover — and therefore suppress the 1 Hz estimate over — a day
      // we have no samples for.
      final runs = NoopImporter.stepRuns({
        0: 100, 1: 110, // run A: +10
        5000: 500, 5001: 520, // run B: +20
      });
      expect(runs, [const StepRun(0, 1, 10), const StepRun(5000, 5001, 20)]);
    });

    test('a counter RESET is not a negative step count', () {
      // Band reboot: 900 → 0. Must not subtract 900, and must not fabricate.
      final runs = NoopImporter.stepRuns({0: 890, 1: 900, 2: 0, 3: 15});
      expect(runs, [const StepRun(0, 3, 25)]); // +10 then +15, reset ignored
    });

    test('does not attribute steps across a run boundary', () {
      // 100 → 900 happened DURING a 5000 s hole. We cannot say when, so the
      // delta is dropped rather than pinned to either window.
      final runs = NoopImporter.stepRuns({0: 100, 5000: 900, 5001: 905});
      expect(runs, [const StepRun(5000, 5001, 5)]);
    });

    test('emits nothing for a zero-step run', () {
      // A 0-step window would suppress a real 1 Hz estimate for no gain.
      expect(NoopImporter.stepRuns({0: 100, 1: 100, 2: 100}), isEmpty);
    });

    test('handles empty / single-sample input', () {
      expect(NoopImporter.stepRuns({}), isEmpty);
      expect(NoopImporter.stepRuns({5: 100}), isEmpty);
    });

    test('is order-independent', () {
      final a = NoopImporter.stepRuns({3: 130, 0: 100, 2: 120, 1: 110});
      expect(a, [const StepRun(0, 3, 30)]);
    });

    test('skips deltas already covered, and breaks the run there', () {
      // 0..5 covered → only the 5→8 tail is bankable.
      final runs = NoopImporter.stepRuns(
        {0: 100, 1: 110, 2: 120, 5: 150, 6: 160, 7: 170, 8: 180},
        covered: const [
          [0, 5]
        ],
      );
      expect(runs, [const StepRun(5, 8, 30)]);
    });

    test('a fully covered span banks nothing', () {
      expect(
        NoopImporter.stepRuns({0: 100, 1: 110, 2: 120},
            covered: const [
              [0, 2]
            ]),
        isEmpty,
      );
    });

    test('a covered span in the MIDDLE splits into two runs', () {
      final runs = NoopImporter.stepRuns(
        {0: 100, 1: 110, 2: 120, 3: 130, 4: 140, 5: 150},
        covered: const [
          [2, 3]
        ],
      );
      expect(runs, [const StepRun(0, 2, 20), const StepRun(3, 5, 20)]);
    });
  });

  group('end-to-end import of the CURRENT NOOP schema', () {
    late Directory tmp;

    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'openstrap_noop_drift_test.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      tmp = await Directory.systemTemp.createTemp('noop_drift');
    });

    tearDownAll(() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    /// ~40 min of 1 Hz data in the new schema, walking the step counter by 1/s.
    File writeCsv(String name, {required int t0, required int seconds}) {
      final b = StringBuffer()..writeln(_header);
      for (var i = 0; i < seconds; i++) {
        final ts = t0 + i;
        b.writeln(_row(ts, 'hr', hr: '${60 + (i % 20)}'));
        b.writeln(_row(ts, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'));
        b.writeln(_row(ts, 'skintemp', skinTemp: '3240'));
        b.writeln(_row(ts, 'steps', stepCounter: '${24302 + i}'));
        b.writeln(_row(ts, 'band_sleep_state', sleepState: '0'));
        if (i % 5 == 0) b.writeln(_row(ts, 'ppghr'));
      }
      // An event row whose QUOTED payload contains commas — the naive
      // `split(',')` must not let this corrupt unix_s / stream (indexes 0/2).
      b.writeln('${t0 + 1},x,event,,,,,,,,,,,,,,BATTERY_LEVEL(3),'
          '"{""battery_mV"":4155,""battery_pct"":78.4}"');
      final f = File(p.join(tmp.path, name))..writeAsStringSync(b.toString());
      return f;
    }

    test('banks the band step counter as REAL steps, and is idempotent',
        () async {
      // 2026-07-31T09:00:00Z, 2400 s of data.
      const t0 = 1785488400;
      const secs = 2400;
      final csv = writeCsv('a.csv', t0: t0, seconds: secs);

      final res = await NoopImporter.importFile(
          csv.path, const Profile(), DerivationEngine());

      // The whole point: steps are no longer silently dropped.
      expect(res.steps, secs - 1, reason: 'counter advanced 1/s for $secs s');
      expect(res.days, greaterThan(0));
      expect(res.lateRows, 0);

      // Banked where the derivation actually reads real steps from.
      final db = await LocalDb.instance;
      final cov = await db.query('live_coverage');
      expect(cov, isNotEmpty);
      final total = cov.fold<int>(0, (a, r) => a + (r['steps'] as int));
      expect(total, secs - 1);

      // RE-IMPORT must not double-count: live_coverage is an append-only SUM
      // with no uniqueness on the window.
      final res2 = await NoopImporter.importFile(
          csv.path, const Profile(), DerivationEngine());
      expect(res2.steps, 0, reason: 're-import banks nothing new');
      final cov2 = await db.query('live_coverage');
      expect(cov2.length, cov.length, reason: 'no duplicate windows');
      final total2 = cov2.fold<int>(0, (a, r) => a + (r['steps'] as int));
      expect(total2, total, reason: 'step total unchanged after re-import');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an OVERLAPPING re-export does not double-count', () async {
      // The realistic re-import: the user exports again later over a LONGER
      // span covering the same session. An exact-window guard misses this
      // entirely (the run boundary moved), so the overlap gets banked twice —
      // measured at 3,598 against a true 2,399 before the covered-clipping fix.
      const t0 = 1785834000;
      final short = writeCsv('ov_short.csv', t0: t0, seconds: 1200);
      final long = writeCsv('ov_long.csv', t0: t0, seconds: 2400);

      final r1 = await NoopImporter.importFile(
          short.path, const Profile(), DerivationEngine());
      expect(r1.steps, 1199);

      final r2 = await NoopImporter.importFile(
          long.path, const Profile(), DerivationEngine());
      // Only the NEW tail is banked, not the whole longer span.
      expect(r2.steps, 2399 - 1199,
          reason: 'second import banks only the previously uncovered tail');

      final db = await LocalDb.instance;
      final cov = await db.query('live_coverage',
          where: 'start_ts >= ? AND start_ts < ?', whereArgs: [t0, t0 + 2400]);
      final total = cov.fold<int>(0, (a, r) => a + (r['steps'] as int));
      expect(total, 2399, reason: 'total equals the truth, not 3598');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a PARTIALLY flushed import self-heals on re-import', () async {
      // Covered-clipping is keyed by TIME SPAN, not by an exact window row, so
      // a flush interrupted between two runs is recoverable: the run that never
      // landed is not covered, and the next import banks it. This is why the
      // flush does not need to be transactional.
      const t0 = 1785920400;
      final b = StringBuffer()..writeln(_header);
      void block(int start, int n, int base) {
        for (var i = 0; i < n; i++) {
          b.writeln(_row(start + i, 'hr', hr: '65'));
          b.writeln(
              _row(start + i, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'));
          b.writeln(_row(start + i, 'steps', stepCounter: '${base + i}'));
        }
      }

      block(t0, 600, 1000); // run A: 599 steps
      block(t0 + 1200, 600, 2000); // run B: 599 steps, past the 60 s split
      final f = File(p.join(tmp.path, 'partial.csv'))
        ..writeAsStringSync(b.toString());

      final r1 = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(r1.steps, 1198);

      final db = await LocalDb.instance;
      final cov = await db.query('live_coverage',
          where: 'start_ts >= ? AND start_ts < ?',
          whereArgs: [t0, t0 + 2000],
          orderBy: 'start_ts');
      expect(cov.length, 2);

      // Simulate a crash after run A was written but before run B.
      await db.delete('live_coverage',
          where: 'start_ts = ?', whereArgs: [cov.last['start_ts']]);

      final r2 = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(r2.steps, 599, reason: 'the lost run is re-banked, and only it');

      final after = await db.query('live_coverage',
          where: 'start_ts >= ? AND start_ts < ?', whereArgs: [t0, t0 + 2000]);
      final total = after.fold<int>(0, (a, r) => a + (r['steps'] as int));
      expect(total, 1198, reason: 'back to truth, with no double-count');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('shifted event_kind/event_payload columns do not misparse', () async {
      // `band_sleep_state` at 15 pushes event_* to 16/17. Reading by NAME means
      // hr/gravity/steps still land correctly; a positional reader would not.
      const t0 = 1785574800; // a different day, so it derives independently
      final csv = writeCsv('b.csv', t0: t0, seconds: 600);
      final res = await NoopImporter.importFile(
          csv.path, const Profile(), DerivationEngine());
      expect(res.steps, 599);
      expect(res.rows, greaterThan(0));
      expect(res.lateRows, 0);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an export with NO steps stream still imports (steps = 0)', () async {
      // `spo2`/`resp` already vanished from the schema; `steps` could too.
      const t0 = 1785661200;
      final b = StringBuffer()..writeln(_header);
      for (var i = 0; i < 600; i++) {
        b.writeln(_row(t0 + i, 'hr', hr: '65'));
        b.writeln(_row(t0 + i, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'));
      }
      final f = File(p.join(tmp.path, 'c.csv'))
        ..writeAsStringSync(b.toString());
      final res = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(res.steps, 0);
      expect(res.days, greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an rr_ms of NaN or Infinity is not a beat', () async {
      // `double.tryParse('NaN')` really does return NaN, and NaN fails every
      // comparison — so a `ms <= 0` guard passes it straight into the
      // Substrate, where one bad beat poisons the whole day's HRV.
      const t0 = 1786262400; // 2026-08-09
      final b = StringBuffer()..writeln(_header);
      for (var i = 0; i < 600; i++) {
        final ts = t0 + i;
        b.writeln(_row(ts, 'hr', hr: '${60 + (i % 10)}'));
        b.writeln(_row(ts, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'));
        // The finite beats must VARY. A constant series has SD2 = 0, and the
        // irregular-rhythm screen now abstains there rather than publishing
        // "perfectly regular" off an undefined SD1/SD2 ratio — which would
        // leave this test with no beat count to assert on.
        b.writeln(_row(ts, 'rr',
            rr: i == 100
                ? 'NaN'
                : i == 200
                    ? 'Infinity'
                    : '${880 + (i % 41)}'));
      }
      final f = File(p.join(tmp.path, 'nan.csv'))
        ..writeAsStringSync(b.toString());

      final res = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(res.days, greaterThan(0));

      // Assert on the BEAT COUNT the pipeline actually used, not on the row's
      // typed columns: every derived metric lives inside `payload_json`, so a
      // `whereType<double>` sweep over the row finds nothing and passes however
      // broken the guard is. 600 beats were written, two of them non-finite.
      final d = DateTime.fromMillisecondsSinceEpoch(t0 * 1000);
      final day = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      final db = await LocalDb.instance;
      final rows =
          await db.query('day_result', where: 'day_id = ?', whereArgs: [day]);
      expect(rows, isNotEmpty);
      var checked = 0;
      for (final r in rows) {
        final n = _beatsUsed(r);
        if (n == null) continue;
        expect(n, 598,
            reason: 'the NaN and the Infinity are dropped, not counted');
        checked++;
      }
      expect(checked, greaterThan(0), reason: 'the assertion must have run');
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an UNKNOWN future stream is skipped, not fatal', () async {
      const t0 = 1785747600;
      final b = StringBuffer()..writeln(_header);
      for (var i = 0; i < 300; i++) {
        b.writeln(_row(t0 + i, 'hr', hr: '65'));
        b.writeln(_row(t0 + i, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'));
        b.writeln(_row(t0 + i, 'some_future_stream_we_have_never_seen'));
      }
      final f = File(p.join(tmp.path, 'd.csv'))
        ..writeAsStringSync(b.toString());
      final res = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(res.days, greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 5)));

    /// Two adjacent days of 300 s each, with [bad] raw lines spliced in
    /// between them (written verbatim: a µs-scaled unix_s would overflow the
    /// ISO column `_row` builds).
    File twoDaysWith(String name, int t0, List<String> bad) {
      final b = StringBuffer()..writeln(_header);
      void day(int start) {
        for (var i = 0; i < 300; i++) {
          b.writeln(_row(start + i, 'hr', hr: '65'));
          b.writeln(
              _row(start + i, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'));
        }
      }

      day(t0);
      bad.forEach(b.writeln);
      day(t0 + 86400);
      return File(p.join(tmp.path, name))..writeAsStringSync(b.toString());
    }

    test('a millisecond-scaled unix_s does not strand the rest of the file',
        () async {
      // One ms-scaled row used to open a date ~53,000 years out; every real
      // day after it was then "older" than the high-water date and stranded.
      const t0 = 1789030800; // 2026-09-10T09:00:00Z
      final f = twoDaysWith('ms.csv', t0, [
        '1700000000000,x,event,,,,,,,,,,,,,,BATTERY_LEVEL(3),',
        '1700000000001,x,hr,70,,,,,,,,,,,,,,',
      ]);
      final res = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(res.strandedDates, isEmpty);
      expect(res.days, 2);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('an RTC-unset unix_s does not blank the day it lands in', () async {
      // A 1970 sample buffered mid-file stretched the next Substrate past the
      // 400-day calendarDays guard, so the real day derived nothing.
      const t0 = 1789203600; // 2026-09-12T09:00:00Z
      final f = twoDaysWith('rtc.csv', t0, [
        _row(250000, 'hr', hr: '70'),
        _row(250001, 'gravity', gx: '0.1', gy: '0.2', gz: '0.97'),
      ]);
      final res = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(res.strandedDates, isEmpty);
      expect(res.days, 2);
      final db = await LocalDb.instance;
      final rows = await db.rawQuery(
          "SELECT 1 FROM day_result WHERE day_id LIKE '1970-%' LIMIT 1");
      expect(rows, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('a microsecond-scaled unix_s is skipped, not a RangeError', () async {
      const t0 = 1789376400; // 2026-09-14T09:00:00Z
      final f = twoDaysWith('us.csv', t0, [
        '1700000000000000,x,hr,70,,,,,,,,,,,,,,',
      ]);
      final res = await NoopImporter.importFile(
          f.path, const Profile(), DerivationEngine());
      expect(res.days, 2);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
