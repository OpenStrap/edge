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
import 'package:openstrap_edge/models/payloads.dart' show todayHeadlineOf;
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
    num? readiness,
  }) async {
    await db.insert('day_result', {
      'day_id': day ?? todayLabel(),
      'algo_version': kAlgoVersion,
      'payload_json': jsonEncode({
        'scalars': {'rmssd': ?rmssd, 'readiness': ?readiness},
        'sleep': {
          'window': {
            'value': {'offset_ms': wakeSec * 1000},
          },
          'accounting': {
            'value': {'tst_sec': 6 * 3600},
          },
        },
      }),
      'window_json': jsonEncode({'offset_ms': wakeSec * 1000}),
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
    final afternoon =
        DateTime(2026, 10, 4, 15).millisecondsSinceEpoch ~/ 1000;
    expect(
      overnightSettled(
        sleepOffsetSec: null,
        dataEdgeSec: afternoon - 10 * 60,
        nowSec: afternoon,
      ),
      isTrue,
    );
  });

  test('no window just after midnight is a night not started, not no sleep',
      () {
    // Still awake at 00:30 with the band live: the coming sleep has no window.
    final late = DateTime(2026, 10, 4, 0, 30).millisecondsSinceEpoch ~/ 1000;
    expect(
      overnightSettled(
        sleepOffsetSec: null,
        dataEdgeSec: late - 60,
        nowSec: late,
      ),
      isFalse,
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

  test('a settled no-sleep night is not covered by an older night', () async {
    final y = DateTime.now().subtract(const Duration(days: 1));
    final yesterday = '${y.year.toString().padLeft(4, '0')}-'
        '${y.month.toString().padLeft(2, '0')}-'
        '${y.day.toString().padLeft(2, '0')}';
    await seed(
      day: yesterday,
      wakeSec: nowSec - 24 * 3600,
      edgeSec: nowSec - 20 * 3600,
      rmssd: 77,
    );
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
    // Settled by the give-up, so the result doesn't hang on the time of day.
    final edge = nowSec - 13 * 3600;
    await db.insert('decoded_onehz', {
      'ts_ms': edge * 1000,
      'rec_ts': edge,
      'counter': edge,
      'hr': 60,
    });
    await LocalDb.refreshComputeFreshness();
    final today =
        await LocalRepositoryImpl(getProfileMap: () => const {}).getToday();
    expect(today['status']['overnight_day'], todayLabel());
    expect(today['hrv']?['rmssd'], isNot(77));
  });

  test('a night the active wearable supplied settles on its own edge',
      () async {
    // The band was left on the charger: its edge sits before the night. The
    // ring's row was derived against the ring's edge, two hours past wake.
    final wake = nowSec - 3 * 3600;
    await seed(wakeSec: wake, edgeSec: wake - 8 * 3600);
    await db.update(
      'day_result',
      {
        'payload_json': jsonEncode({
          'sleep': {
            'window': {
              'value': {'offset_ms': wake * 1000},
            },
            'accounting': {
              'value': {'tst_sec': 6 * 3600},
            },
          },
          'data_edge_sec': wake + 2 * 3600,
        }),
      },
      where: 'day_id = ?',
      whereArgs: [todayLabel()],
    );
    expect(await overnightDay(), todayLabel());
    final row = await LocalDb.computeFreshness('today');
    expect(jsonDecode(row!['payload_json'] as String)['recovery_state'],
        'final');
  });

  test('a row derived mid-drain stays unsettled after the band edge moves on',
      () async {
    // Derived with the edge at the wake; the band has since synced past it,
    // but the row (and its score) is still the partial night.
    final wake = nowSec - 3 * 3600;
    await seed(wakeSec: wake, edgeSec: wake + 2 * 3600);
    await db.update(
      'day_result',
      {
        'payload_json': jsonEncode({
          'sleep': {
            'window': {
              'value': {'offset_ms': wake * 1000},
            },
            'accounting': {
              'value': {'tst_sec': 6 * 3600},
            },
          },
          'data_edge_sec': wake + 60,
        }),
      },
      where: 'day_id = ?',
      whereArgs: [todayLabel()],
    );
    expect(await overnightDay(), isNot(todayLabel()));
    final row = await LocalDb.computeFreshness('today');
    expect(jsonDecode(row!['payload_json'] as String)['recovery_state'],
        'night_in_progress');
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

  test("recovery push reads a no-sleep window ('—') as no window", () {
    expect(
      recoveryNightSettled(
        dayId: todayLabel(),
        payload: {
          'sleep': {
            'window': {'value': '—'},
          },
        },
        dataEdgeSec: nowSec - 5 * 60 * 60,
        nowSec: nowSec,
      ),
      isFalse,
    );
  });

  group('recovery_state through getToday', () {
    Future<Map<String, dynamic>> today() async {
      await LocalDb.refreshComputeFreshness();
      return LocalRepositoryImpl(getProfileMap: () => const {}).getToday();
    }

    test('edge at the window close → night in progress, no number', () async {
      final wake = nowSec - 10 * 60;
      await seed(wakeSec: wake, edgeSec: wake, readiness: 2);
      final t = await today();
      expect(t['status']['recovery_state'], 'night_in_progress');
      expect(todayHeadlineOf(t)['recovery'], isNull);
    });

    test('wake confirmed, not settled → provisional number', () async {
      final wake = nowSec - 50 * 60;
      await seed(wakeSec: wake, edgeSec: wake + 40 * 60, readiness: 27.6);
      final h = todayHeadlineOf(await today());
      expect(h['recovery_state'], 'provisional');
      expect(h['recovery'], 27.6);
    });

    test('final night: a legacy pin without wake yields to the live value',
        () async {
      final wake = nowSec - 3 * 3600;
      await seed(wakeSec: wake, edgeSec: wake + 2 * 3600, readiness: 27.6);
      await LocalDb.setFrozenHeadline(todayLabel(), 2);
      final h = todayHeadlineOf(await today());
      expect(h['recovery_state'], 'final');
      expect(h['recovery'], 27.6);
      // A pin taken on this night's wake is honoured.
      await LocalDb.setFrozenHeadline(todayLabel(), 28, wakeSec: wake);
      final h2 = todayHeadlineOf(await today());
      // A wake before kMinPinWakeHour local is never pinnable, so when this
      // test runs in the small hours the pin is ignored and the live value
      // shows. Assert whichever the clock makes correct.
      final pinnable = DateTime.fromMillisecondsSinceEpoch(wake * 1000).hour >=
          kMinPinWakeHour;
      expect(h2['recovery'], pinnable ? 28 : 27.6);
      // 27.6 was shown as 28 already: same number, no "Updated" note.
      expect(h2['recovery_update'], isNull);
    });
  });
}
