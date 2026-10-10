// Rule R6 through the real toggle path (useDevice / setWearableEnabled, with
// onWearableDaysChanged wired to a forced re-derive as the app wires it):
// turning a wearable's flag off leaves nothing of it on a day it shaped
// without HR rows of its own there. That is a night staged off its
// hypnogram alone (a band with HR monitoring off), and a day whose raw rows
// were pruned after it derived. A day the band also contributed to keeps
// the band's numbers.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const String _day = '2026-10-03';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
const List<String> _families = [
  'garmin',
  'pebble',
  'miband234',
  'colmi',
  'oura',
];

void main() {
  final handed = <Set<String>>[];

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'wearable_toggle_no_leak_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final (raws, samples)
        in SyntheticDay(DateTime(2026, 10, 4)).primaryBatches()) {
      await LocalDb.commitSyncBatch(raws, samples);
    }
    final night = SyntheticDay(DateTime(2026, 10, 3));
    for (final f in _families) {
      await LocalDb.upsertDevice(id: '$f-synthetic', adapterId: f, label: f);
      final reported = vendorStagesReported(f);
      // A hypnogram and no HR rows at all.
      await LocalDb.putVendorSleepEpochs([
        for (final (a, b, st) in night.hypnogramBlocks())
          VendorEpoch(a, b, reported.contains(st.name) ? st.name : 'light'),
      ], deviceId: '$f-synthetic', source: f);
    }
    onWearableDaysChanged = (days) async {
      handed.add(days);
      await DerivationEngine().runDays(_profile, days, force: true);
    };
  });

  tearDownAll(() async {
    onWearableDaysChanged = null;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<String?> source(String day) async {
    final row = await LocalDb.dayResult(day);
    if (row == null) return null;
    return (jsonDecode(row['payload_json'] as String) as Map)['sleep_source']
        as String?;
  }

  for (final f in _families) {
    test('$f: an HR-less staged night goes when the flag goes off', () async {
      final id = '$f-synthetic';
      await useDevice(id, f, true);
      await DerivationEngine().runDays(_profile, {_day}, force: true);
      expect(await source(_day), 'vendor_staged');
      await (await LocalDb.instance).update('day_result', {'finalized': 1},
          where: 'day_id = ?', whereArgs: [_day]);
      handed.clear();
      await useDevice(id, f, false);
      expect(handed.expand((d) => d), contains(_day),
          reason: 'the day it staged is re-derived off the band alone');
      expect(await source(_day), isNot('vendor_staged'));
      await DerivationEngine().run(_profile);
      expect(await source(_day), isNot('vendor_staged'),
          reason: 'a plain run never brings the finalized night back');
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('a pruned day only the wearable decided is cleared, a shared one kept',
      () async {
    const id = 'colmi-synthetic';
    final db = await LocalDb.instance;
    // Derived while the ring was on, raw rows since pruned (none here).
    for (final (day, coverage) in const [
      ('2026-09-28', id),
      ('2026-09-29', ',$id'),
    ]) {
      await db.insert('day_result', {
        'day_id': day,
        'algo_version': kAlgoVersion,
        'payload_json': '{}',
        'computed_at': 0,
        'finalized': 1,
        'rhr': 50,
      });
      await db.insert('metric_series', {'date': day, 'key': 'rhr', 'value': 50});
      await db.insert('metric_series_version', {
        'date': day,
        'algo_version': kAlgoVersion,
        'source': 'band',
        'coverage_devices': coverage,
      });
    }
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
    await LocalDb.setCursor(kActiveWearableCursor, id);
    await setWearableEnabled('colmi', false);
    expect(await LocalDb.dayResult('2026-09-28'), isNull,
        reason: 'only the ring contributed: nothing of it may stay');
    expect(
        await db.query('metric_series', where: 'date = ?',
            whereArgs: ['2026-09-28']),
        isEmpty);
    expect(await LocalDb.dayResult('2026-09-29'), isNotNull,
        reason: 'the band contributed too and its rows cannot be re-derived');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
