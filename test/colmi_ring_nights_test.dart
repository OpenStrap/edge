// A Colmi ring as the active wearable, past the happy path of
// synthetic_colmi_day_test.dart: a ring that keeps its nights in the form we
// bank but do not decode, a night the ring reports again ending later, a
// ring set to measure HR less often than every 5 minutes, and a nap the ring
// recorded. Each through the real Colmi link and the real engine.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/colmi_inputs.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart'
    show sparseHrSubstrate;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const String _dayId = '2026-10-04';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);

Future<void> _ring(String id) => LocalDb.upsertDevice(
    id: id, adapterId: 'colmi', remoteId: 'AA:BB:CC:00:00:0${id.length % 10}',
    label: id);

Future<void> _use(String id) async {
  await LocalDb.setCursor(kActiveWearableCursor, id);
  await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
}

/// One night in a big-data sleep reply, `daysAgo` 0, ending at [endMin]
/// minute of the day, its blocks [stageMinutes] in order.
List<int> _sleepReply(int endMin, List<(int, int)> stageMinutes) {
  final pairs = [for (final (s, m) in stageMinutes) ...[s, m]];
  return colmiBigDataRequest(kColmiBigSleep, [
    1, 0, pairs.length + 4, 1380 & 0xff, 1380 >> 8, endMin & 0xff,
    endMin >> 8, ...pairs,
  ]);
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'colmi_ring_nights_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async => LocalDb.close());

  test('a night the ring reports again, ending later, replaces the first: '
      'its stage minutes are not added up and its epochs do not stack',
      () async {
    const id = 'colmi-rereport';
    await _ring(id);
    final noon = SyntheticDay.sec(DateTime(2026, 10, 4, 12));
    for (final reply in [
      _sleepReply(390, [
        (kColmiStageLight, 200), (kColmiStageDeep, 80), //
        (kColmiStageRem, 90), (kColmiStageAwake, 10),
      ]),
      _sleepReply(435, [
        (kColmiStageLight, 230), (kColmiStageDeep, 85), //
        (kColmiStageRem, 100), (kColmiStageAwake, 10),
      ]),
    ]) {
      await ColmiLink.instance.ingestForTest(
          id,
          (_, w) => w[0] == kColmiCmdBigData && w[1] == kColmiBigSleep
              ? [reply]
              : const [],
          nowSeconds: () => noon);
    }
    await _use(id);
    final cells = (await dayCells(_dayId))!;
    expect(cells['sleep_stages']!['class'], 'device');
    expect(cells['sleep_stages']!['value'], 85, reason: 'not 80 + 85');
    final db = await LocalDb.instance;
    final epochs = await db.rawQuery(
        'SELECT start_ts, end_ts FROM vendor_sleep_epoch WHERE device_id = ? '
        'ORDER BY start_ts', [id]);
    for (var i = 1; i < epochs.length; i++) {
      expect(epochs[i]['start_ts'] as int,
          greaterThanOrEqualTo(epochs[i - 1]['end_ts'] as int),
          reason: 'overlapping epochs: the first report is still there');
    }
    expect(
        epochs.fold<int>(0, (s, e) => s + (e['end_ts'] as int) - (e['start_ts'] as int)),
        425 * 60);
  });

  test('a night the ring reports again, ending later but shorter, keeps none '
      'of the first report: its leading epochs do not chain into the night',
      () async {
    const id = 'colmi-rereport-short';
    await _ring(id);
    final noon = SyntheticDay.sec(DateTime(2026, 10, 4, 12));
    for (final reply in [
      _sleepReply(390, [
        (kColmiStageLight, 60), (kColmiStageDeep, 80), (kColmiStageLight, 190),
      ]),
      _sleepReply(435, [(kColmiStageLight, 215), (kColmiStageDeep, 80)]),
    ]) {
      await ColmiLink.instance.ingestForTest(
          id,
          (_, w) => w[0] == kColmiCmdBigData && w[1] == kColmiBigSleep
              ? [reply]
              : const [],
          nowSeconds: () => noon);
    }
    final rows = await (await LocalDb.instance).rawQuery(
        'SELECT MIN(start_ts) AS s, SUM(end_ts - start_ts) AS d '
        'FROM vendor_sleep_epoch WHERE device_id = ?', [id]);
    expect(rows.single['d'], 295 * 60);
    expect(rows.single['s'],
        SyntheticDay.sec(DateTime(2026, 10, 4, 7, 15)) - 295 * 60);
  });

  test('a ring set to measure HR every 30 minutes abstains: its rows are '
      'not read as 5-minute HR', () async {
    const id = 'colmi-30min';
    await _ring(id);
    await ColmiLink.instance.ingestForTest(id, (_, w) {
      if (w[0] != kColmiCmdHrHistory) return const [];
      final v = List.filled(48, 60);
      return [
        colmiFrame(w[0], [0, 5, 30]),
        colmiFrame(w[0], [1, 0, 0, 0, 0, ...v.sublist(0, 9)]),
        for (var i = 9, pg = 2; i < 48; i += 13, pg++)
          colmiFrame(w[0], [pg, ...v.sublist(i, i + 13 > 48 ? 48 : i + 13)]),
      ];
    }, nowSeconds: () => SyntheticDay.sec(_now));
    final from = SyntheticDay.sec(DateTime(2026, 10, 3));
    final to = SyntheticDay.sec(DateTime(2026, 10, 4)) - 1;
    expect((await sparseHrSubstrate('colmi', id, from, to)).length, 48,
        reason: 'the rows are there');
    expect((await colmiSubstrate(id, from, to)).isEmpty, isTrue);
    expect(await colmiNight(id, from - 86400, to), isNull);
  });

  test('a ring that keeps its nights in the undecoded form: our HR-led '
      'window is the night, so every night-anchored row of ours still '
      'serves, and what the ring\'s night would give says "not decoded"',
      () async {
    const id = 'colmi-old-sleep';
    await _ring(id);
    final link = await ColmiLink.instance.ingestForTest(
        id,
        (_, w) => switch (w[0]) {
              // Byte 9 = 0: no big-data sleep on this ring.
              kColmiCmdSetTime => [colmiFrame(kColmiCmdSetTime)],
              kColmiCmdSleepDetails => [
                  colmiFrame(kColmiCmdSleepDetails, [0xff]),
                ],
              _ => SyntheticDay.colmiRingReply(_days, w, _now),
            },
        nowSeconds: () => SyntheticDay.sec(_now));
    expect(
        link.writes.where(
            (x) => x.$2[0] == kColmiCmdBigData && x.$2[1] == kColmiBigSleep),
        isEmpty);
    await _use(id);
    // The first test's ring staged a night on this day: not this ring's.
    await (await LocalDb.instance).delete('vendor_sleep_epoch');
    final ids = {for (final d in _days) d.day.toIso8601String().substring(0, 10)};
    for (var i = 0; i < 2; i++) {
      await DerivationEngine().runDays(_profile, ids, force: true);
    }
    final full = jsonDecode(
        (await LocalDb.dayResult(_dayId))!['payload_json'] as String) as Map;
    expect(full['sleep_source'], 'auto_fallback');
    final cells = (await dayCells(_dayId))!;
    String cls(String row) => cells[row]!['class'] as String;
    for (final row in [
      'sleep_window',
      'resting_hr',
      'nadir_dip',
      'baselines_load_illness',
    ]) {
      expect(cls(row), 'ours', reason: row);
      expect(cells[row]!['method'], 'hr_5min', reason: row);
    }
    expect((cells['resting_hr']!['value'] as num) - _days.last.nightHrNadir,
        inInclusiveRange(-6, 6));
    expect(cls('strain'), 'estimated');
    expect(cls('calories'), 'device');
    for (final row in kColmiNightRows) {
      expect(cls(row), 'unavailable', reason: row);
      expect(cells[row]!['reason'], Why.notDecoded.name, reason: row);
    }
    // The window holds no stages: none of ours stored, no hypnogram on the
    // native cards.
    final acct = (((full['sleep'] as Map)['accounting'] as Map)['value'] as Map);
    expect(acct['deep_sec'], isNull);
    expect(acct['efficiency_pct'], isNull);
    expect(
        ((withoutWearableEstimates(full.cast<String, dynamic>())['series']
                as Map?) ??
            const {})
            .containsKey('hypnogram'),
        isFalse);

    // A nap the ring recorded is served as the ring's own.
    await LocalDb.putObservation(
        Observation(
          at: DateTime(2026, 10, 4, 14),
          sourceKind: ObservationSource.vendor,
          vendorKey: 'nap_min',
          value: 35,
          unit: 'min',
          attribution: 'Colmi',
        ),
        deviceId: id);
    final withNap = (await dayCells(_dayId))!;
    expect(withNap['naps']!['class'], 'device');
    expect(withNap['naps']!['value'], 35);
    expect(capabilities(kColmiColumn)['naps'], MetricClass.device);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a ring that stages no night: our HR-led window is the night, and '
      'efficiency says the ring staged none, not that no night is stored',
      () async {
    const id = 'colmi-no-staged';
    await _ring(id);
    await ColmiLink.instance.ingestForTest(
        id,
        (_, w) => w[0] == kColmiCmdBigData && w[1] == kColmiBigSleep
            ? [colmiBigDataRequest(kColmiBigSleep, [0])]
            : SyntheticDay.colmiRingReply(_days, w, _now),
        nowSeconds: () => SyntheticDay.sec(_now));
    await _use(id);
    await (await LocalDb.instance).delete('vendor_sleep_epoch');
    final ids = {for (final d in _days) d.day.toIso8601String().substring(0, 10)};
    await DerivationEngine().runDays(_profile, ids, force: true);
    final full = jsonDecode(
        (await LocalDb.dayResult(_dayId))!['payload_json'] as String) as Map;
    expect(full['sleep_source'], 'auto_fallback');
    final cells = (await dayCells(_dayId))!;
    expect(cells['sleep_window']!['class'], 'ours');
    // Our HR-led window quotes the error measured against the synthetic
    // truth (test/lowres_validation_test.dart).
    expect(cells['sleep_window']!['band'], 30);
    // HRV and SpO2 too: the ring sent both, it just staged no night to
    // hold their means, so "your ring gave none" would be false.
    for (final row in ['efficiency_awakenings', 'sleep_stages', 'hrv', 'spo2']) {
      expect(cells[row]!['class'], 'unavailable', reason: row);
      expect(cells[row]!['reason'], Why.noStagedNight.name, reason: row);
    }

    // A day the ring stored no calories for: ours estimated, with no band
    // (no profile in the low-resolution validation measures it).
    expect(cells['calories']!['class'], 'device');
    await (await LocalDb.instance).delete('observation',
        where: "device_id = ? AND vendor_key = 'calories'", whereArgs: [id]);
    final est = (await dayCells(_dayId))!['calories']!;
    expect(est['class'], 'estimated');
    expect(est['method'], 'hr_5min');
    expect(est.containsKey('band'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('native cards: a provisional readiness on a ring\'s day is taken out, '
      'a band\'s day is left as it is', () {
    final ring = <String, dynamic>{
      'device_family': 'colmi',
      'scalars': {'readiness': 55, 'rhr': 50},
      'clinical': {
        'readiness_composite': {'value': 55, 'provisional': true},
      },
    };
    expect(withoutWearableEstimates(ring)['scalars'], {'rhr': 50});
    final band = {...ring, 'device_family': 'gen4'};
    expect(withoutWearableEstimates(band), same(band));
  });
}
