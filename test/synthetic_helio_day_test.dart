// An Amazfit Helio strap as the ACTIVE WEARABLE, no primary band: four
// synthetic days (test/support/synthetic_day.dart) banked the way its link
// banks them (one-a-minute HR, skin temperature as its own record on the same
// minutes, its own hypnogram), derived by the real engine and served by the
// declaration-built column (lib/compute/inputs/sparse_inputs.dart). It must
// reach the same strain / resting-HR / readiness the Garmin watch gets off
// the same minute HR, with no Helio-specific code in compute.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart' show TimeAnchor;
import 'package:openstrap_edge/ble/adapters/adapter.dart' show NeutralSample;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/manual_session.dart'
    show computeManualSessionStats;
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/observation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++)
    SyntheticDay(DateTime(2026, 10, d), nightHrOffset: d < 4 ? -6 : 0),
];
final SyntheticDay _truth = _days.last;
const String _dayId = '2026-10-04';
const Set<String> _dayIds = {'2026-10-01', '2026-10-02', '2026-10-03', _dayId};
const String _id = 'helio-synthetic';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    (jsonDecode(row['payload_json'] as String) as Map).cast<String, dynamic>();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_helio_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _id, adapterId: 'helio_strap', label: 'Helio');
    final minuteHr = <int, int>{};
    for (final d in _days) {
      for (final MapEntry(key: t, value: bpm) in d.hr.entries) {
        if (t % 60 == 0) minuteHr[t] = bpm;
      }
    }
    final ts = minuteHr.keys.toList()..sort();
    // The strap's activity and temperature rounds are separate records on
    // the same minutes: banked as two samples per minute, as its link does.
    final samples = [
      for (final t in ts) ...[
        NeutralSample(
            anchor: TimeAnchor.measured, tsEpoch: t, hr: minuteHr[t]),
        // Each night a little warmer: a flat channel has no spread to
        // score against, and the z abstains (rightly).
        NeutralSample(
            anchor: TimeAnchor.measured,
            tsEpoch: t,
            skinTempC: 33.0 +
                0.2 * DateTime.fromMillisecondsSinceEpoch(t * 1000).day),
      ],
    ];
    await LocalDb.commitSyncBatch(const [], const [],
        deviceId: _id, deviceFamily: 'helio_strap', neutrals: samples);
    for (final d in _days) {
      await LocalDb.putVendorSleepEpochs([
        for (final (a, b, st) in d.hypnogramBlocks()) VendorEpoch(a, b, st.name),
      ], deviceId: _id, source: 'helio_strap');
    }
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the strap moves no number and serves no column', () async {
    await LocalDb.setCursor(kActiveWearableCursor, _id);
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: strain, resting HR and readiness derive off its minute HR',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor('helio_strap'), '1');
    for (var i = 0; i < 2; i++) {
      expect(
          await DerivationEngine().runDays(_profile, _dayIds, force: true), 4);
    }
    final cells = (await dayCells(_dayId))!;
    String cls(String row) => cells[row]!['class'] as String;
    num v(String row) => cells[row]!['value'] as num;

    expect(cls('strain'), 'ours');
    expect(v('strain'), inInclusiveRange(4, 15),
        reason: 'a 40-minute run at 150 bpm, as on the watch');
    expect(cls('resting_hr'), 'ours');
    expect(cells['resting_hr']!['method'], 'hr_1min');
    expect((v('resting_hr') - _truth.nightHrNadir).abs(), lessThanOrEqualTo(6));
    expect(cls('readiness'), 'estimated');
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(cls('sleep_window'), 'ours');
    expect(cls('calories'), 'ours');
    expect(cls('auto_workouts'), 'ours');
    expect(cls('skin_temp'), 'ours',
        reason: 'its Celsius rode on the HR rows, three nights before today');
    for (final r in ['hrv', 'respiratory_rate', 'stress', 'irregular_rhythm']) {
      expect(cls(r), 'unavailable', reason: '$r: no beats, no device value');
      expect(cells[r]!['reason'], isNotEmpty);
    }
    // A workout window on the strap's day reads its minute HR (no band, no
    // chest strap), and scores off it with each sample a minute long.
    await refreshSessionSensorSources();
    final run0 = SyntheticDay.sec(_truth.runStart);
    final hr = await LocalDb.hrSamplesInRange(run0, run0 + 40 * 60);
    expect(hr.length, inInclusiveRange(39, 41));
    final stats = computeManualSessionStats(
      hrTs: [for (final r in hr) (r['rec_ts'] as num).toInt()],
      hrBpm: [for (final r in hr) (r['hr'] as num).toInt()],
      profile: _profile,
      hrMax: 186,
    );
    expect(stats.zoneMinutes.fold<double>(0, (a, b) => a + b),
        inInclusiveRange(38, 41), reason: 'minutes, not seconds');

    final stored = _payload((await LocalDb.dayResult(_dayId))!);
    expect(stored['device_family'], 'helio_strap');
    expect(stored['sleep_source'], 'vendor_staged');
  }, timeout: const Timeout(Duration(minutes: 3)));

  // Owner decision 2026-11-22: the wearable's own daily count is the day's
  // steps, served as ours (a whole-day answer, never added to the phone's).
  test("the strap's own step count is the day's steps", () async {
    await LocalDb.putObservations([
      Observation(
        at: DateTime(2026, 10, 4),
        sourceKind: ObservationSource.vendor,
        key: 'steps',
        value: 8123,
        unit: 'steps',
        attribution: 'Amazfit',
      ),
    ], deviceId: _id);
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    final stored = _payload((await LocalDb.dayResult(_dayId))!);
    expect((stored['scalars'] as Map)['steps'], 8123);
    expect((stored['steps'] as Map)['source'], 'wearable');
    final cells = (await dayCells(_dayId))!;
    expect(cells['steps']!['class'], 'ours');
    expect(cells['steps']!['value'], 8123);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('re-deriving with nothing new moves no stored number', () async {
    Future<Map<String, Object?>> snapshot() async => {
          for (final d in _dayIds)
            d: (_payload((await LocalDb.dayResult(d))!)['scalars'] as Map)
                .cast<String, Object?>(),
        };
    final before = await snapshot();
    for (var i = 0; i < 3; i++) {
      await DerivationEngine().runDays(_profile, _dayIds, force: true);
    }
    expect(await snapshot(), before);
    final db = await LocalDb.instance;
    final dupes = await db.rawQuery(
        'SELECT date, key, COUNT(*) c FROM metric_series '
        'GROUP BY date, key HAVING c > 1');
    expect(dupes, isEmpty, reason: 'one value per day per key');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('turning the strap off leaves nothing of it', () async {
    onWearableDaysChanged = (days) async =>
        DerivationEngine().runDays(_profile, days, force: true);
    try {
      await setWearableEnabled('helio_strap', false);
    } finally {
      onWearableDaysChanged = null;
    }
    for (final d in _dayIds) {
      expect(await LocalDb.dayResult(d), isNull, reason: d);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
