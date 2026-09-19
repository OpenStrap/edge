// Data-integrity regressions for the three import paths.
//
//  • WHOOP CSV must NEVER overwrite a day the device derived from real 1 Hz
//    (putDayResult is INSERT-OR-REPLACE on day_result AND metric_series, and
//    the importer used to pass finalized:true, which additionally locked the
//    day out of DerivationEngine forever — months of band data, gone, from a
//    button reachable in onboarding AND in Profile).
//  • Energy is converted from the COLUMN'S declared unit, never guessed from
//    the value's magnitude (a real 4,500 kcal ultra day was being rewritten as
//    1,076 kcal and then exported to Apple Health / Health Connect).
//  • A cloud session with no start_ts is skipped, not filed on 1970-01-01.
//  • The raw-CSV importer's high-water date only moves forward, so an
//    out-of-order row can't discard a whole buffered day.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/cloud/cloud_import.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart' show kAlgoVersion;
import 'package:openstrap_edge/compute/substrate.dart' show localDateLabel;
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/import/noop_import.dart';
import 'package:openstrap_edge/import/whoop_import.dart';

/// Local-time wall clock → the day label the importer will file it under.
const _wake = '2026-03-05 08:30:00';
final _wakeSec = DateTime.parse(_wake).millisecondsSinceEpoch ~/ 1000;
final _day = localDateLabel(_wakeSec);

String _csv(Directory dir, String name, String energyHeader, String energy) {
  final f = File(p.join(dir.path, name));
  f.writeAsStringSync(
    'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
    'Heart rate variability (ms),Day Strain,$energyHeader,'
    'Asleep duration (min)\n'
    '$_wake,$_wake,42,70,19,7.5,$energy,300\n',
  );
  return f.path;
}

Future<Map<String, dynamic>?> _row(String day) => LocalDb.dayResult(day);

Future<double?> _metric(String day, String key) async {
  final db = await LocalDb.instance;
  final rows = await db.query('metric_series',
      where: 'date = ? AND key = ?', whereArgs: [day, key]);
  if (rows.isEmpty) return null;
  return (rows.first['value'] as num?)?.toDouble();
}

void main() {
  late Directory tmp;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_import_safety_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    tmp = Directory.systemTemp.createTempSync('openstrap_import_test');
  });

  tearDownAll(() async {
    await LocalDb.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('WhoopImporter never destroys a real derived day', () {
    test('skips a date that already holds a 1 Hz-derived day', () async {
      // A REAL derived day: no `imported` marker, real scalars.
      await LocalDb.putDayResult(
        dayId: _day,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'date': _day, 'source': 'onehz', 'real': true}),
        windowJson: '{}',
        rhr: 48.0,
        rmssd: 88.0,
        readiness: 91.0,
        series: {'rhr': 48.0, 'rmssd': 88.0, 'readiness': 91.0},
      );

      final res = await WhoopImporter.importFiles(
          [_csv(tmp, 'day_real.csv', 'Energy burned (cal)', '2400')]);

      expect(res.days, 0, reason: 'a real derived day must not be replaced');
      expect(res.skippedExistingDays, 1);

      final row = await _row(_day);
      final payload = jsonDecode(row!['payload_json'] as String) as Map;
      expect(payload['real'], isTrue, reason: 'payload was overwritten');
      expect(payload['source'], 'onehz');
      // The scalars the user cares about survive untouched.
      expect(await _metric(_day, 'rhr'), 48.0);
      expect(await _metric(_day, 'rmssd'), 88.0);
      expect(await _metric(_day, 'readiness'), 91.0);
      // …and the day was NOT force-finalized out of the derivation engine.
      expect((row['finalized'] as num).toInt(), 0);
    });

    test('writes into a genuinely empty day', () async {
      const otherWake = '2026-03-09 07:15:00';
      final otherDay = localDateLabel(
          DateTime.parse(otherWake).millisecondsSinceEpoch ~/ 1000);
      final f = File(p.join(tmp.path, 'day_empty.csv'));
      f.writeAsStringSync(
        'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
        'Heart rate variability (ms),Day Strain,Energy burned (cal),'
        'Asleep duration (min)\n'
        '$otherWake,$otherWake,55,60,70,9.1,2200,420\n',
      );
      final res = await WhoopImporter.importFiles([f.path]);
      expect(res.days, 1);
      expect(res.skippedExistingDays, 0);
      final payload =
          jsonDecode((await _row(otherDay))!['payload_json'] as String) as Map;
      expect(payload['source'], 'whoop_export');
      expect(await _metric(otherDay, 'rhr'), 60.0);
      // No raw for this date, so nothing could ever re-derive it — finalizing
      // is correct here.
      expect(((await _row(otherDay))!['finalized'] as num).toInt(), 1);
    });

    test('does not finalize a day that still has raw to re-derive from',
        () async {
      const wake = '2026-05-04 07:00:00';
      final wakeSec = DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000;
      final day = localDateLabel(wakeSec);
      final db = await LocalDb.instance;
      await db.insert('decoded_onehz', {
        'counter': 900001,
        'rec_ts': wakeSec,
        'hr': 62,
        'ax': 0.0,
        'ay': 0.0,
        'az': 1.0,
        'spo2_red_raw': 0,
        'spo2_ir_raw': 0,
        'skin_temp_raw': 0,
      });
      final f = File(p.join(tmp.path, 'day_with_raw.csv'));
      f.writeAsStringSync(
        'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
        'Heart rate variability (ms),Day Strain,Energy burned (cal),'
        'Asleep duration (min)\n'
        '$wake,$wake,50,60,60,5,2000,400\n',
      );
      expect((await WhoopImporter.importFiles([f.path])).days, 1);
      // finalized:true would lock DerivationEngine out of this day FOREVER —
      // the vendor snapshot would permanently outrank the real 1 Hz signal.
      expect(((await _row(day))!['finalized'] as num).toInt(), 0);
    });

    test('re-importing over a PREVIOUS import is allowed', () async {
      const wake = '2026-03-11 06:00:00';
      final day =
          localDateLabel(DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000);
      String write(String rhr) {
        final f = File(p.join(tmp.path, 'day_reimport.csv'));
        f.writeAsStringSync(
          'Cycle start time,Wake onset,Recovery score %,'
          'Resting heart rate (bpm),Heart rate variability (ms),Day Strain,'
          'Energy burned (cal),Asleep duration (min)\n'
          '$wake,$wake,50,$rhr,65,6.0,2000,400\n',
        );
        return f.path;
      }

      expect((await WhoopImporter.importFiles([write('58')])).days, 1);
      expect(await _metric(day, 'rhr'), 58.0);
      final again = await WhoopImporter.importFiles([write('61')]);
      expect(again.days, 1, reason: 'vendor snapshots may replace each other');
      expect(await _metric(day, 'rhr'), 61.0);
    });
  });

  group('WhoopImporter merges same-day _Kind.day files across the export', () {
    // physiological_cycles.csv (recovery/RHR/RMSSD/strain) and sleeps.csv
    // (sleep-only columns) both classify as _Kind.day and both carry a row
    // for the same date. Neither file has the other's columns, so a naive
    // per-row write would null out whichever file wrote second.
    String cyclesCsv(Directory dir, String wake) {
      final f = File(p.join(dir.path, 'physiological_cycles.csv'));
      f.writeAsStringSync(
        'Cycle start time,Recovery score %,Resting heart rate (bpm),'
        'Heart rate variability (ms),Day Strain\n'
        '$wake,66,52,80,12.3\n',
      );
      return f.path;
    }

    String sleepsCsv(Directory dir, String wake) {
      final f = File(p.join(dir.path, 'sleeps.csv'));
      f.writeAsStringSync(
        'Sleep onset,Wake onset,Asleep duration (min),Light sleep duration (min)\n'
        '$wake,$wake,410,250\n',
      );
      return f.path;
    }

    Future<void> assertMerged(String day) async {
      expect(await _metric(day, 'rhr'), 52.0,
          reason: 'recovery-file field must survive the sleep file\'s write');
      expect(await _metric(day, 'strain'), 12.3,
          reason: 'recovery-file field must survive the sleep file\'s write');
      expect(await _metric(day, 'tst_min'), 410.0,
          reason: 'sleep-file field must survive the recovery file\'s write');
    }

    test('cycles-then-sleep does not lose either file\'s fields', () async {
      const wake = '2026-06-01 07:00:00';
      final day =
          localDateLabel(DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000);
      final res = await WhoopImporter.importFiles(
          [cyclesCsv(tmp, wake), sleepsCsv(tmp, wake)]);
      expect(res.days, 1, reason: 'one date, one write, not one per file');
      await assertMerged(day);
    });

    test('sleep-then-cycles (reversed order) gives the same merged result',
        () async {
      const wake = '2026-06-02 07:00:00';
      final day =
          localDateLabel(DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000);
      final res = await WhoopImporter.importFiles(
          [sleepsCsv(tmp, wake), cyclesCsv(tmp, wake)]);
      expect(res.days, 1);
      await assertMerged(day);
    });
  });

  group('WhoopImporter energy units come from the header, not the value', () {
    Future<double?> importEnergy(
        String wake, String header, String value) async {
      final day =
          localDateLabel(DateTime.parse(wake).millisecondsSinceEpoch ~/ 1000);
      final f = File(p.join(tmp.path, 'energy_${header.hashCode}.csv'));
      f.writeAsStringSync(
        'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
        'Heart rate variability (ms),Day Strain,$header,Asleep duration (min)\n'
        '$wake,$wake,50,60,60,5,$value,400\n',
      );
      await WhoopImporter.importFiles([f.path]);
      return _metric(day, 'calories');
    }

    test('a real 4,500 kcal ultra day is NOT rewritten as kJ', () async {
      // The old heuristic (`v > 4000 ? v / 4.184 : v`) turned this into 1,076.
      expect(await importEnergy('2026-04-01 07:00:00', 'Energy burned (cal)',
              '4500'),
          4500.0);
    });

    test('a kJ column IS converted', () async {
      final v = await importEnergy(
          '2026-04-02 07:00:00', 'Energy burned (kJ)', '8000');
      expect(v, closeTo(8000 / 4.184, 0.01));
    });

    test('an ambiguous unit-less column is dropped, not guessed', () async {
      expect(
          await importEnergy('2026-04-03 07:00:00', 'Energy burned', '5000'),
          isNull);
    });
  });

  group('CloudImporter session rows', () {
    test('skips a session with no start_ts instead of filing it at epoch 0',
        () async {
      final wrote = await CloudImporter.debugWriteSession({
        'id': 'malformed-1',
        'end_ts': 1780000000,
        'type': 'run',
      });
      expect(wrote, isFalse);
      final db = await LocalDb.instance;
      final rows = await db
          .query('sessions', where: 'start_ts <= ?', whereArgs: [0]);
      expect(rows, isEmpty, reason: 'a 1970-01-01 phantom workout was written');
      final byId =
          await db.query('sessions', where: 'id = ?', whereArgs: ['malformed-1']);
      expect(byId, isEmpty);
    });

    test('writes a well-formed session', () async {
      final wrote = await CloudImporter.debugWriteSession({
        'id': 'good-1',
        'start_ts': 1780000000,
        'end_ts': 1780003600,
        'type': 'run',
      });
      expect(wrote, isTrue);
      final db = await LocalDb.instance;
      final rows =
          await db.query('sessions', where: 'id = ?', whereArgs: ['good-1']);
      expect(rows.length, 1);
      expect((rows.first['start_ts'] as num).toInt(), 1780000000);
      expect((rows.first['duration_min'] as num).toInt(), 60);
    });
  });

  group('CloudImporter._writeDay return value (dayCount accuracy)', () {
    test('returns false and does not write when the band already measured '
        'this date', () async {
      const day = '2026-06-01';
      await LocalDb.putDayResult(
        dayId: day,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode({'date': day, 'source': 'onehz', 'real': true}),
        windowJson: '{}',
        rhr: 50.0,
        series: {'rhr': 50.0},
      );
      final wrote =
          await CloudImporter.debugWriteDay(day, {'resting_hr': 99}, null);
      expect(wrote, isFalse,
          reason: 'a measured day must not be overwritten or counted');
      expect(await _metric(day, 'rhr'), 50.0);
    });

    test('returns true when it actually writes an unmeasured date', () async {
      const day = '2026-06-02';
      final wrote =
          await CloudImporter.debugWriteDay(day, {'resting_hr': 55}, null);
      expect(wrote, isTrue);
      expect(await _metric(day, 'rhr'), 55.0);
    });
  });

  group('raw-CSV importer row ordering (high-water date)', () {
    test('the first row starts the window', () {
      expect(NoopImporter.decideRow('2026-01-02', null, {}), RowOrder.advance);
    });

    test('a later date closes out the previous one', () {
      expect(NoopImporter.decideRow('2026-01-03', '2026-01-02', {}),
          RowOrder.advance);
    });

    test('same-date rows just buffer', () {
      expect(NoopImporter.decideRow('2026-01-02', '2026-01-02', {}),
          RowOrder.buffer);
    });

    test('an out-of-order row NEVER rewinds the high-water date', () {
      // THE bug: this used to set curDate back to 2026-01-01, so the next
      // 2026-01-02 row called deriveAndPrune('2026-01-01') and dropped every
      // buffered sample of 2026-01-02.
      expect(NoopImporter.decideRow('2026-01-01', '2026-01-02', {}),
          RowOrder.buffer);
      expect(NoopImporter.decideRow('2026-01-01', '2026-01-02', {}),
          isNot(RowOrder.advance));
    });

    test('a row for an already-derived day is reported late, not silently lost',
        () {
      expect(
        NoopImporter.decideRow('2026-01-01', '2026-01-02', {'2026-01-01'}),
        RowOrder.late,
      );
    });

    test('a whole out-of-order sequence keeps every day exactly once', () {
      // Interleaved input: D1, D2, D1(late-ish), D2, D3, D2(late), D3
      const rows = [
        '2026-01-01',
        '2026-01-02',
        '2026-01-01',
        '2026-01-02',
        '2026-01-03',
        '2026-01-02',
        '2026-01-03',
      ];
      String? cur;
      final derived = <String>{};
      final advanced = <String>[];
      var late = 0;
      for (final d in rows) {
        switch (NoopImporter.decideRow(d, cur, derived)) {
          case RowOrder.advance:
            if (cur != null) {
              advanced.add(cur);
              derived.add(cur);
            }
            cur = d;
          case RowOrder.buffer:
            break;
          case RowOrder.late:
            late++;
        }
      }
      // Each day is derived exactly once and always in order.
      expect(advanced, ['2026-01-01', '2026-01-02']);
      expect(cur, '2026-01-03');
      // Both genuinely unusable rows (a D1 after D1 was derived, and a D2
      // after D2 was derived) are counted rather than silently dropped.
      expect(late, 2);
    });
  });
}
