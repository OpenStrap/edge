// A Xiaomi / Mi Smart Band 7 as the ACTIVE WEARABLE, no primary band: four
// synthetic days (test/support/synthetic_day.dart) banked the way its link
// banks them (one-a-minute HR, its own hypnogram, no skin temperature: the
// band has no sensor for it), derived by the real engine and served by the
// declaration-built column. Same numbers as the Helio Strap off the same
// minute HR, with nothing Mi Band 7-specific in compute, and every row the
// band cannot feed unavailable with a reason, never filled in.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart'
    show TimeAnchor, kMiBand7;
import 'package:openstrap_edge/ble/adapters/adapter.dart' show NeutralSample;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
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
const String _id = 'zeppos_l66-synthetic';
final String _family = kMiBand7.id;
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

Map<String, dynamic> _payload(Map<String, Object?> row) =>
    (jsonDecode(row['payload_json'] as String) as Map).cast<String, dynamic>();

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'synthetic_miband7_day_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(id: _id, adapterId: _family, label: kMiBand7.label);
    final minuteHr = <int, int>{};
    for (final d in _days) {
      for (final MapEntry(key: t, value: bpm) in d.hr.entries) {
        if (t % 60 == 0) minuteHr[t] = bpm;
      }
    }
    final ts = minuteHr.keys.toList()..sort();
    await LocalDb.commitSyncBatch(const [], const [],
        deviceId: _id,
        deviceFamily: _family,
        neutrals: [
          for (final t in ts)
            NeutralSample(anchor: TimeAnchor.measured, tsEpoch: t, hr: minuteHr[t]),
        ]);
    for (final d in _days) {
      await LocalDb.putVendorSleepEpochs([
        for (final (a, b, st) in d.hypnogramBlocks()) VendorEpoch(a, b, st.name),
      ], deviceId: _id, source: _family);
    }
  });

  tearDownAll(() async => LocalDb.close());

  test('flag off: the band moves no number and serves no column', () async {
    await LocalDb.setCursor(kActiveWearableCursor, _id);
    expect(
        await DerivationEngine().runDays(_profile, {_dayId}, force: true), 0);
    expect(await LocalDb.dayResult(_dayId), isNull);
    expect(await dayCells(_dayId), isNull);
  });

  test('flag on: strain, resting HR and readiness derive off its minute HR',
      () async {
    await LocalDb.setCursor(wearableEnabledCursor(_family), '1');
    for (var i = 0; i < 2; i++) {
      // The first pass also re-scores the day owed a quiet level (+1).
      expect(await DerivationEngine().runDays(_profile, _dayIds, force: true),
          i == 0 ? 5 : 4);
    }
    final cells = (await dayCells(_dayId))!;
    String cls(String row) => cells[row]!['class'] as String;
    num v(String row) => cells[row]!['value'] as num;

    expect(cls('strain'), 'ours');
    expect(v('strain'), inInclusiveRange(4, 15));
    expect(cls('resting_hr'), 'ours');
    expect(cells['resting_hr']!['method'], 'hr_1min');
    expect((v('resting_hr') - _truth.nightHrNadir).abs(), lessThanOrEqualTo(6));
    expect(cls('readiness'), 'estimated',
        reason: 'resting HR only: no device RMSSD for this family');
    expect(cells['readiness']!['method'], 'rhr_only_partial');
    expect(cls('sleep_window'), 'ours');
    for (final r in [
      'hrv',
      'respiratory_rate',
      'stress',
      'irregular_rhythm',
      'skin_temp',
    ]) {
      expect(cls(r), 'unavailable', reason: '$r: nothing this band feeds');
      expect(cells[r]!['reason'], isNotEmpty);
    }

    final stored = _payload((await LocalDb.dayResult(_dayId))!);
    expect(stored['device_family'], _family);
    expect(stored['sleep_source'], 'vendor_staged');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test("the band's own step count is the day's steps", () async {
    await LocalDb.putObservations([
      Observation(
        at: DateTime(2026, 10, 4),
        sourceKind: ObservationSource.vendor,
        key: 'steps',
        value: 9001,
        unit: 'steps',
        attribution: 'Xiaomi',
      ),
    ], deviceId: _id);
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    final stored = _payload((await LocalDb.dayResult(_dayId))!);
    expect((stored['scalars'] as Map)['steps'], 9001);
    expect((stored['steps'] as Map)['source'], 'wearable');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('turning the band off leaves nothing of it', () async {
    onWearableDaysChanged = (days) async =>
        DerivationEngine().runDays(_profile, days, force: true);
    try {
      await setWearableEnabled(_family, false);
    } finally {
      onWearableDaysChanged = null;
    }
    for (final d in _dayIds) {
      expect(await LocalDb.dayResult(d), isNull, reason: d);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
