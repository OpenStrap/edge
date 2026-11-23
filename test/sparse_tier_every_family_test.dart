// Every minute-HR wearable family gets the sparse tier, not just the ones
// it was built and tested on. One table row per family in kHrCadenceSec at
// 60 s: four synthetic days banked as one-a-minute HR plus its own
// hypnogram, derived by the real engine. Flag off: nothing. Flag on: strain
// and resting HR ours, a readiness, a workout window scored off its minute
// HR, and (when it declares a step counter) its own count as the day's
// steps. A family added to the registry without the rest of the wiring
// fails here by name.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart'
    show TimeAnchor, declaredSignals;
import 'package:openstrap_edge/ble/adapters/adapter.dart' show NeutralSample;
import 'package:openstrap_edge/ble/adapters/signals.dart' show InputSignal;
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/inputs/garmin_inputs.dart';
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
const String _dayId = '2026-10-04';
const Set<String> _dayIds = {'2026-10-01', '2026-10-02', '2026-10-03', _dayId};
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final families = [
    for (final e in kHrCadenceSec.entries)
      if (e.value == 60) e.key,
  ];

  test('the table is not empty', () => expect(families, isNotEmpty));

  for (final family in families) {
    test('$family: the sparse tier, flag off then on', () async {
      await LocalDb.close();
      LocalDb.dbName = 'sparse_tier_$family.db';
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
      final id = '$family-synthetic';
      await LocalDb.upsertDevice(id: id, adapterId: family, label: family);
      final minuteHr = <int, int>{
        for (final d in _days)
          for (final MapEntry(key: t, value: bpm) in d.hr.entries)
            if (t % 60 == 0) t: bpm,
      };
      await LocalDb.commitSyncBatch(const [], const [],
          deviceId: id,
          deviceFamily: family,
          neutrals: [
            for (final t in minuteHr.keys.toList()..sort())
              NeutralSample(
                  anchor: TimeAnchor.measured, tsEpoch: t, hr: minuteHr[t]),
          ]);
      for (final d in _days) {
        await LocalDb.putVendorSleepEpochs([
          for (final (a, b, st) in d.hypnogramBlocks())
            VendorEpoch(a, b, st.name),
        ], deviceId: id, source: family);
      }
      await LocalDb.putObservations([
        Observation(
          at: DateTime(2026, 10, 4),
          sourceKind: ObservationSource.vendor,
          key: 'steps',
          value: 8123,
          unit: 'steps',
          attribution: family,
        ),
      ], deviceId: id);
      await LocalDb.setCursor(kActiveWearableCursor, id);

      // Flag off (rule R6): nothing.
      expect(await DerivationEngine().runDays(_profile, {_dayId}, force: true),
          0);
      expect(await dayCells(_dayId), isNull);

      await LocalDb.setCursor(wearableEnabledCursor(family), '1');
      // Twice: strain is priced on the prior days' quiet-waking levels,
      // which the first pass writes.
      for (var i = 0; i < 2; i++) {
        expect(await DerivationEngine().runDays(_profile, _dayIds, force: true),
            4);
      }
      final cells = (await dayCells(_dayId))!;
      String? cls(String row) => cells[row]?['class'] as String?;
      expect(cls('strain'), 'ours', reason: '${cells['strain']}');
      expect(cells['strain']!['value'], isA<num>());
      expect(cls('resting_hr'), 'ours');
      expect(cells['resting_hr']!['method'], 'hr_1min');
      expect(cls('readiness'), anyOf('ours', 'estimated'));
      expect(cells['readiness']!['value'], isA<num>());

      // A workout window reads its minute HR, a minute per sample.
      await refreshSessionSensorSources();
      final run0 = SyntheticDay.sec(_days.last.runStart);
      final hr = await LocalDb.hrSamplesInRange(run0, run0 + 40 * 60);
      expect(hr.length, inInclusiveRange(39, 41));
      final stats = computeManualSessionStats(
        hrTs: [for (final r in hr) (r['rec_ts'] as num).toInt()],
        hrBpm: [for (final r in hr) (r['hr'] as num).toInt()],
        profile: _profile,
        hrMax: 186,
      );
      expect(stats.zoneMinutes.fold<double>(0, (a, b) => a + b),
          inInclusiveRange(38, 41));

      if (declaredSignals(family).contains(InputSignal.steps)) {
        expect(cls('steps'), 'ours');
        expect(cells['steps']!['value'], 8123);
      }
      await LocalDb.close();
    }, timeout: const Timeout(Duration(minutes: 3)));
  }
}
