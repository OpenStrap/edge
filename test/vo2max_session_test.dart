// Submax VO2max backfill (`_rescoreSessionFromSubstrate` ->
// `_submaxVo2maxFromSplits`) over a REAL LocalDb (sqflite_ffi):
//   • a clean 1 km GPS split + steady HR backfills `vo2max_estimate`.
//   • it is written ONCE and never recomputed on a later read.
//   • a session with no route never gets an estimate.
//   • an all-out (near-maximal) split abstains — no fabricated number.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/data/models.dart';
import 'package:openstrap_edge/gps/route_models.dart';

RawRecord _raw(int ts, int counter) => RawRecord(
      counter: counter,
      packetType: 47,
      hex: 'v02$counter',
      capturedAt: ts * 1000,
      recTs: ts,
    );

Sample _sample(int ts, int counter, int hr) => Sample(
      tsEpoch: ts,
      counter: counter,
      hr: hr,
      rrIntervalsMs: const [],
      ax: 0,
      ay: 0,
      az: 0,
      spo2RedRaw: 0,
      spo2IrRaw: 0,
      skinTempRaw: 0,
    );

Future<void> _insertHr(int fromTs, int toTs, int hr,
    {required int counterBase}) async {
  final raws = <RawRecord>[];
  final samples = <Sample?>[];
  var c = counterBase;
  for (var ts = fromTs; ts <= toTs; ts++) {
    raws.add(_raw(ts, c));
    samples.add(_sample(ts, c, hr));
    c++;
  }
  await LocalDb.commitSyncBatch(raws, samples, deviceFamily: 'gen4');
}

/// A straight-line 1 km route walked in [durationSec], starting at [startTs]
/// (epoch seconds), one fix every 10 s. ~0.009 deg latitude ≈ 1 km.
Future<void> _insertKmRoute(String sessionId, int startTs, int durationSec) async {
  const points = 30;
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i <= points; i++) {
    final frac = i / points;
    rows.add(RoutePoint(
      seq: i,
      tsMs: (startTs + (durationSec * frac).round()) * 1000,
      lat: 40.0 + 0.009 * frac,
      lng: -74.0,
    ).toRow(sessionId));
  }
  await LocalDb.appendRoutePoints(sessionId, rows);
}

void main() {
  late LocalRepositoryImpl repo;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_vo2max_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    repo = LocalRepositoryImpl(
      getProfileMap: () => {'age': 30, 'resting_hr': 55},
    );
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a clean 1 km split at a submax HR backfills vo2max_estimate',
      () async {
    const id = 'w-vo2-1';
    const start = 500000;
    const durationSec = 330; // ~3.03 m/s, a moderate run pace
    const end = start + durationSec;
    await LocalDb.putSession({
      'id': id,
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'duration_min': (durationSec / 60).round(),
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': start * 1000,
    });
    // Steady 150 bpm for the whole bout. maxHr (Tanaka, age 30) = 187,
    // restingHr 55 -> %HRR = (150-55)/(187-55) ≈ 72%, inside the submax band.
    await _insertHr(start, end, 150, counterBase: 40000);
    await _insertKmRoute(id, start, durationSec);

    final w = await repo.getWorkout(id);
    final vo2max = w['vo2max_estimate'];
    expect(vo2max, isNotNull);
    expect((vo2max as num).toDouble(), inInclusiveRange(30, 70));

    final row = await LocalDb.session(id);
    expect(row?['vo2max_estimate'], isNotNull);
  });

  test('it is written once and a second read does not recompute it',
      () async {
    const id = 'w-vo2-once';
    const start = 510000;
    const durationSec = 330;
    const end = start + durationSec;
    await LocalDb.putSession({
      'id': id,
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'duration_min': (durationSec / 60).round(),
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': start * 1000,
    });
    await _insertHr(start, end, 150, counterBase: 41000);
    await _insertKmRoute(id, start, durationSec);

    await repo.getWorkout(id);
    final first = (await LocalDb.session(id))?['vo2max_estimate'] as num?;
    expect(first, isNotNull);

    // Manually poison the banked value — a real recompute would overwrite it.
    await LocalDb.setSessionVo2max(id, 12.34);
    await repo.getWorkout(id);
    final second = (await LocalDb.session(id))?['vo2max_estimate'] as num?;
    expect(second, 12.34, reason: 'backfill-only: never recomputed once set');
  });

  test('a session with no GPS route never gets an estimate', () async {
    const id = 'w-vo2-no-route';
    const start = 520000;
    const end = start + 600;
    await LocalDb.putSession({
      'id': id,
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'duration_min': 10,
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': start * 1000,
    });
    await _insertHr(start, end, 150, counterBase: 42000);

    final w = await repo.getWorkout(id);
    expect(w['vo2max_estimate'], isNull);
  });

  test('an all-out split (near-maximal HR) abstains rather than fabricate',
      () async {
    const id = 'w-vo2-maximal';
    const start = 530000;
    const durationSec = 330;
    const end = start + durationSec;
    await LocalDb.putSession({
      'id': id,
      'start_ts': start,
      'end_ts': end,
      'type': 'run',
      'status': 'done',
      'duration_min': (durationSec / 60).round(),
      'source': 'manual',
      'device_family': 'gen4',
      'created_at': start * 1000,
    });
    // 183 bpm vs maxHr 187, restingHr 55 -> %HRR ≈ 97% — well past the
    // submaximal band vo2maxSubmaxEstimate accepts.
    await _insertHr(start, end, 183, counterBase: 43000);
    await _insertKmRoute(id, start, durationSec);

    final w = await repo.getWorkout(id);
    expect(w['vo2max_estimate'], isNull);
  });
}
