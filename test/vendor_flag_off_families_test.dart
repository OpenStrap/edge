// Rule R6 on an install WITH primary band rows: the band records 10-03 18:00
// onward, so 10-03 derives on the band's edge and its night (which the band
// never saw) is open to a device hypnogram. For every family that banks one,
// the night stages only while that family's flag is on and its device is the
// active wearable, and turning it off
// again leaves nothing of it, not even the night banked while it was on
// (nor one cached on a finalized day). A flag-off device also shows no
// night on the Sleep screen, no row on the day timeline, and owns no window
// of a signal it is ranked for.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/vendor_sleep.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/local_repository_impl.dart';
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
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'vendor_flag_off_families_test.db';
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
      await LocalDb.putVendorSleepEpochs([
        for (final (a, b, st) in night.hypnogramBlocks())
          VendorEpoch(a, b, reported.contains(st.name) ? st.name : 'light'),
      ], deviceId: '$f-synthetic', source: f);
      await (await LocalDb.instance).insert('observation', {
        'device_id': '$f-synthetic',
        'ts_ms': DateTime(2026, 10, 3, 12).millisecondsSinceEpoch,
        'date': _day,
        'source_kind': 'device',
        'vendor_key': 'steps',
        'value': 4321,
        'unit': '',
        'attribution': f,
      });
    }
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  Future<String?> source() async {
    expect(await DerivationEngine().runDays(_profile, {_day}, force: true), 1,
        reason: 'the band has rows that day, so it always derives');
    return (jsonDecode((await LocalDb.dayResult(_day))!['payload_json']
            as String) as Map)['sleep_source'] as String?;
  }

  Future<Map> payload() async => jsonDecode(
      (await LocalDb.dayResult(_day))!['payload_json'] as String) as Map;

  Future<bool> shown(String id) async => [
        ...(await LocalRepositoryImpl(getProfileMap: () => {})
            .getDeviceNights(_day)),
        ...await timelineObservations(await LocalDb.observationsForDay(_day)),
      ].any((r) => r['device_id'] == id);

  for (final f in _families) {
    test('$f: flag off stages nothing, on stages its night, off again '
        'leaves none of it', () async {
      final id = '$f-synthetic';
      expect(await source(), isNot('vendor_staged'));
      expect(await shown(id), isFalse,
          reason: 'flag off: no night on the Sleep screen, no timeline row');
      // Ranked for beat timing over the night it covers: it owns nothing,
      // flag off (rule R6) or on (the band day's reads never load its beats),
      // so the band's beats are all still ours.
      final night = SyntheticDay(DateTime(2026, 10, 3));
      Future<void> ranksNothing(String why) async {
        await (await LocalDb.instance).insert('device_coverage', {
          'device_id': id,
          'signal': InputSignal.rrIntervals.name,
          'start_ts': SyntheticDay.sec(night.sleepOnset),
          'end_ts': SyntheticDay.sec(night.sleepOffset),
        });
        await LocalDb.setSignalPriority(
            InputSignal.rrIntervals, [id, LocalDb.kPrimaryDeviceId]);
        await source();
        expect((await payload())['series']?['coverage'], isNull, reason: why);
        await LocalDb.setSignalPriority(InputSignal.rrIntervals, const []);
        await (await LocalDb.instance)
            .delete('device_coverage', where: 'device_id = ?', whereArgs: [id]);
      }

      await ranksNothing('a flag-off device is no owner of any window');
      await LocalDb.setCursor(wearableEnabledCursor(f), '1');
      // Numbers come from one wearable at a time: flag on but another
      // device active, its night stages nothing either.
      await LocalDb.setCursor(kActiveWearableCursor, kNoActiveWearable);
      expect(await source(), isNot('vendor_staged'));
      await LocalDb.setCursor(kActiveWearableCursor, '$f-synthetic');
      expect(await source(), 'vendor_staged');
      expect(await shown(id), isTrue);
      await ranksNothing('flag on, it still owns no window of a band day');
      // Finalized while the flag was on: the cached night must not outlive
      // the flag either.
      await (await LocalDb.instance).update('day_result', {'finalized': 1},
          where: 'day_id = ?', whereArgs: [_day]);
      await LocalDb.setCursor(wearableEnabledCursor(f), '0');
      expect(await source(), isNot('vendor_staged'));
      expect(await shown(id), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('switching the active wearable drops the old one\'s banked night',
      () async {
    final night = SyntheticDay(DateTime(2026, 10, 3));
    final short =
        SyntheticDay(DateTime(2026, 10, 3), bedShiftMin: 150, wakeShiftMin: -60);
    await LocalDb.upsertDevice(
        id: 'garmin-short', adapterId: 'garmin', label: 'garmin');
    final reported = vendorStagesReported('garmin');
    await LocalDb.putVendorSleepEpochs([
      for (final (a, b, st) in short.hypnogramBlocks())
        VendorEpoch(a, b, reported.contains(st.name) ? st.name : 'light'),
    ], deviceId: 'garmin-short', source: 'garmin');
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '1');
    await LocalDb.setCursor(kActiveWearableCursor, 'colmi-synthetic');
    expect(await source(), 'vendor_staged');
    Future<Map> candidate() async => jsonDecode(
        (await LocalDb.sleepSessionCandidate(_day, kAlgoVersion))![
            'payload_json'] as String) as Map;
    expect((await candidate())['sleep_offset_sec'] as int,
        greaterThanOrEqualTo(SyntheticDay.sec(night.sleepOffset) - 300));
    await LocalDb.setCursor(kActiveWearableCursor, 'garmin-short');
    expect(await source(), 'vendor_staged');
    expect((await candidate())['sleep_offset_sec'] as int,
        lessThanOrEqualTo(SyntheticDay.sec(short.sleepOffset) + 300),
        reason: 'the night is the active watch\'s, not the ring\'s kept one');
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '0');
    await LocalDb.setCursor(wearableEnabledCursor('garmin'), '0');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
