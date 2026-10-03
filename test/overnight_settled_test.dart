// #448 — mid-drain, the newest banked record is still inside last night, the
// stager closes the window at it, and Home served that partial night (and the
// readiness off it) as this morning's. Today's overnight only counts as
// `ready` once the data edge has moved past its wake.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late String dir;
  final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_overnight_settled_test.db';
    dir = await databaseFactory.getDatabasesPath();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    db = await LocalDb.instance;
  });

  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<void> seed({
    required int wakeSec,
    required int edgeSec,
    String? day,
    num? rmssd,
  }) async {
    await db.insert('day_result', {
      'day_id': day ?? todayLabel(),
      'algo_version': kAlgoVersion,
      'payload_json': jsonEncode({
        if (rmssd != null) 'scalars': {'rmssd': rmssd},
        'sleep': {
          'window': {
            'value': {'offset_ms': wakeSec * 1000},
          },
          'accounting': {
            'value': {'tst_sec': 6 * 3600},
          },
        },
      }),
      'window_json': '{}',
      'computed_at': 1,
      'finalized': 0,
    });
    await db.insert('decoded_onehz', {
      'ts_ms': edgeSec * 1000,
      'rec_ts': edgeSec,
      'counter': edgeSec,
      'hr': 60,
    });
  }

  Future<String?> overnightDay() async {
    await LocalDb.refreshComputeFreshness();
    final row = await LocalDb.computeFreshness('today');
    return jsonDecode(row!['payload_json'] as String)['overnight_day'] as String?;
  }

  test('edge still at the wake → today is not the overnight yet', () async {
    final wake = nowSec - 20 * 60;
    await seed(wakeSec: wake, edgeSec: wake + 60);
    expect(await overnightDay(), isNot(todayLabel()));
  });

  test('edge an hour past the wake → today is the overnight', () async {
    final wake = nowSec - 3 * 3600;
    await seed(wakeSec: wake, edgeSec: wake + 2 * 3600);
    expect(await overnightDay(), todayLabel());
  });

  test('a strap that went quiet at wake still settles by the give-up', () {
    final wake = nowSec - 13 * 3600;
    expect(
      overnightSettled(sleepOffsetSec: wake, dataEdgeSec: wake, nowSec: nowSec),
      isTrue,
    );
  });

  test('a stalled drain does not pin by the give-up', () {
    // Drain stopped mid-night: the stored wake IS the edge. Home may give up
    // and show it, but the freeze holds all day, so it waits for the edge.
    final wake = nowSec - 13 * 3600;
    expect(
      overnightSettled(sleepOffsetSec: wake, dataEdgeSec: wake),
      isFalse,
    );
  });

  test('a peripheral streaming this morning does not settle the band night',
      () async {
    final wake = nowSec - 3 * 3600;
    await seed(wakeSec: wake, edgeSec: wake);
    await db.insert('decoded_onehz', {
      'ts_ms': (wake + 2 * 3600) * 1000,
      'rec_ts': wake + 2 * 3600,
      'counter': 2,
      'hr': 70,
      'source': 'hrs',
    });
    expect(await overnightDay(), isNot(todayLabel()));
  });

  test('no window yet with the edge hours behind → not a settled no-sleep night',
      () async {
    // Asleep at 00:30, drain paused at 00:20: today has no window at all.
    await db.insert('day_result', {
      'day_id': todayLabel(),
      'algo_version': kAlgoVersion,
      'payload_json': jsonEncode({
        'flags': ['NO_SLEEP_DETECTED'],
      }),
      'window_json': '{}',
      'computed_at': 1,
      'finalized': 0,
    });
    final edge = nowSec - 3 * 3600;
    await db.insert('decoded_onehz', {
      'ts_ms': edge * 1000,
      'rec_ts': edge,
      'counter': edge,
      'hr': 60,
    });
    expect(await overnightDay(), isNot(todayLabel()));
  });

  test('no window with the edge caught up → no sleep is the answer', () {
    expect(
      overnightSettled(
        sleepOffsetSec: null,
        dataEdgeSec: nowSec - 10 * 60,
        nowSec: nowSec,
      ),
      isTrue,
    );
  });

  test('a warm app picks up the give-up without another derive', () async {
    // Strap went quiet at wake, 13 h ago; the last derive stamped 'building'.
    final wake = nowSec - 13 * 3600;
    await seed(wakeSec: wake, edgeSec: wake);
    await LocalDb.putComputeFreshness(
      'today',
      jsonEncode({
        'today_day': todayLabel(),
        'overnight_state': 'building',
        'overnight_recheck_at': wake + 12 * 3600,
      }),
    );
    final today =
        await LocalRepositoryImpl(getProfileMap: () => const {}).getToday();
    expect(today['status']['overnight_day'], todayLabel());
  });

  test('getToday serves the prior night, not the partial one under its label',
      () async {
    final y = DateTime.now().subtract(const Duration(days: 1));
    final yesterday = '${y.year.toString().padLeft(4, '0')}-'
        '${y.month.toString().padLeft(2, '0')}-'
        '${y.day.toString().padLeft(2, '0')}';
    final wake = nowSec - 60 * 60;
    await seed(
      day: yesterday,
      wakeSec: wake - 24 * 3600,
      edgeSec: wake - 20 * 3600,
      rmssd: 77,
    );
    await seed(wakeSec: wake, edgeSec: wake, rmssd: 11);
    await LocalDb.refreshComputeFreshness();
    final today =
        await LocalRepositoryImpl(getProfileMap: () => const {}).getToday();
    expect(today['status']['overnight_day'], yesterday);
    expect(today['hrv']['rmssd'], 77);
  });

  test('readiness chart leaves out the night getToday holds back', () async {
    final wake = nowSec - 20 * 60;
    await seed(wakeSec: wake, edgeSec: wake + 60);
    await db.insert('metric_series', {
      'date': todayLabel(),
      'key': 'readiness',
      'value': 41,
    });
    await LocalDb.refreshComputeFreshness();
    final repo = LocalRepositoryImpl(getProfileMap: () => const {});
    expect((await repo.getChart('recovery'))['points'], isEmpty);

    // Edge past the wake: the night settles and today's point is back.
    await db.insert('decoded_onehz', {
      'ts_ms': (wake + 2 * 3600) * 1000,
      'rec_ts': wake + 2 * 3600,
      'counter': 2,
      'hr': 60,
    });
    await LocalDb.refreshComputeFreshness();
    expect((await repo.getChart('recovery'))['points'], hasLength(1));
  });

  test('recovery push waits for the same settled night Home does', () {
    final wake = nowSec - 2 * 60 * 60;
    final payload = {
      'sleep': {
        'window': {
          'value': {'offset_ms': wake * 1000},
        },
      },
    };
    // Drain stopped at the wake: the readiness is off a partial night.
    expect(
      recoveryNightSettled(
        dayId: todayLabel(),
        payload: payload,
        dataEdgeSec: wake,
        nowSec: nowSec,
      ),
      isFalse,
    );
    expect(
      recoveryNightSettled(
        dayId: todayLabel(),
        payload: payload,
        dataEdgeSec: wake + 61 * 60,
        nowSec: nowSec,
      ),
      isTrue,
    );
  });
}
