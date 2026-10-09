// An abstaining sleep-session RMSSD persists as NULL — over a stored number,
// and on every re-derive.
//
// `rmssd` used to fall back to the NREM median when the session estimator
// abstained. Without the fallback the scalar is null, and the stored day must
// follow: `day_result.rmssd`, the bundle and `metric_series('rmssd')` all
// overwritten (REPLACE with null, not skipped), the same on the second derive
// as on the first, and the next day's baseline must not fold the stale value.
//
// The night: a forced sleep window over 8 h of 1 Hz HR, with RR in 10-beat
// blocks every 5 minutes. Every 5-min window holds 9 successive differences —
// under the 20 the session estimator needs, over the 5 the NREM median needs —
// so the bundle still publishes `clinical.rmssd_nocturnal`, the number the old
// fallback would have stored.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';

const _dayId = '2025-09-10'; // fixed, not `now`
const _nextDay = '2025-09-11';
const _priorDay = '2025-09-09';

int _sec(int y, int mo, int d, int h, int mi) =>
    DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

final _onset = _sec(2025, 9, 9, 22, 0);
final _offset = _sec(2025, 9, 10, 6, 0);

Future<void> _seedNight(Database db) async {
  final batch = db.batch();
  var counter = 0;
  for (var ts = _onset; ts < _offset; ts++) {
    batch.insert('decoded_onehz', {
      'device_id': '',
      'ts_ms': ts * 1000,
      'rec_ts': ts,
      'counter': counter++,
      'hr': 55,
      'ax': 0.0,
      'ay': 0.0,
      'az': 1.0,
      'device_family': 'gen4',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  for (var block = _onset + 30; block + 15 < _offset; block += 300) {
    var tMs = block * 1000.0;
    final perRecord = <int, int>{};
    for (var i = 0; i < 10; i++) {
      final rr = 1091.0 + 16 * math.sin(2 * math.pi * i / 12);
      tMs += rr;
      final recTs = tMs ~/ 1000;
      final idx = perRecord[recTs] = (perRecord[recTs] ?? -1) + 1;
      batch.insert('decoded_rr', {
        'device_id': '',
        'ts_ms': recTs * 1000,
        'rec_ts': recTs,
        'beat_index': idx,
        'rr_ts_ms': recTs * 1000,
        'beat_ts_ms': tMs.round(),
        'rr_ms': rr.round(),
        'device_family': 'gen4',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }
  await batch.commit(noResult: true);
}

Future<Object?> _seriesValue(Database db, String date, String key) async {
  final rows = await db.query('metric_series',
      columns: ['value'], where: 'date = ? AND key = ?', whereArgs: [date, key]);
  return rows.isEmpty ? 'NO ROW' : rows.single['value'];
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_rmssd_persistence_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a stored rmssd is overwritten with null, identically on every derive',
      () async {
    final db = await LocalDb.instance;
    await _seedNight(db);
    await LocalDb.putSleepOverride(
        dayId: _dayId, onsetTs: _onset, offsetTs: _offset, source: 'manual');
    // A real prior night for the baseline, and a same-day number written by
    // the old fallback.
    await LocalDb.putDayResult(
      dayId: _priorDay,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({'scalars': {'rmssd': 50.0}}),
      windowJson: '{}',
      rmssd: 50.0,
      source: 'band',
      series: {'rmssd': 50.0},
    );
    await LocalDb.putDayResult(
      dayId: _dayId,
      algoVersion: kAlgoVersion,
      payloadJson: jsonEncode({'scalars': {'rmssd': 37.0}}),
      windowJson: '{}',
      rmssd: 37.0,
      source: 'band',
      series: {'rmssd': 37.0},
    );
    expect(await _seriesValue(db, _dayId, 'rmssd'), 37.0);

    for (var pass = 1; pass <= 2; pass++) {
      final done = await DerivationEngine()
          .runDays(const Profile(), {_dayId}, force: true);
      expect(done, 1, reason: 'pass $pass must derive');
      final row = await LocalDb.dayResult(_dayId);
      final bundle = jsonDecode(row!['payload_json'] as String) as Map;
      final clinical = (bundle['clinical'] as Map).cast<String, dynamic>();
      final session = (clinical['rmssd_sleep_session'] as Map);
      expect(session['value'], '—', reason: 'pass $pass: ${session['note']}');
      expect(session['note'] as String, contains('fewer than 20'));
      // The number the old fallback would have stored is still computed, under
      // its own key.
      expect((clinical['rmssd_nocturnal'] as Map)['value'], isA<num>(),
          reason: 'pass $pass: ${(clinical['rmssd_nocturnal'] as Map)['note']}');
      expect((bundle['scalars'] as Map)['rmssd'], isNull, reason: 'pass $pass');
      expect(row['rmssd'], isNull, reason: 'pass $pass: day_result.rmssd');
      expect(await _seriesValue(db, _dayId, 'rmssd'), isNull,
          reason: 'pass $pass: metric_series is REPLACEd with null');
      expect(await _seriesValue(db, _dayId, 'ln_rmssd'), isNull,
          reason: 'pass $pass');
    }

    // The next day's baseline folds the real prior night, not the stale 37.
    final window =
        (await debugSweepBaselineWindows('rmssd', [_nextDay])).single;
    expect(window, contains(50.0));
    expect(window, isNot(contains(37.0)));
  });
}
