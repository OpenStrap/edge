// The band's own HR-led night ('auto_fallback') is banked like any band
// night (#242): a later pass over less substrate keeps the longer banked
// night. Only a night staged off a paired device's records is re-staged.
// Every wearable flag is off here: a WHOOP-only install.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

const String _day = '2026-10-04';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');

void main() {
  late SyntheticDay synth;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'whoop_fallback_night_banked_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    synth = SyntheticDay(DateTime(2026, 10, 4));
    for (final (raws, samples) in synth.primaryBatches()) {
      await LocalDb.commitSyncBatch(raws, samples);
    }
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  /// A banked night longer than anything this substrate re-stages.
  Future<void> bank({required bool deviceNight}) =>
      LocalDb.putSleepSessionCandidate(
        dayId: _day,
        algoVersion: kAlgoVersion,
        payloadJson: jsonEncode(SleepSessionCandidate(
          dayId: _day,
          confidence: 0.4,
          flags: const [],
          sleepJson: const {'tst_sec': 11 * 3600},
          hypnoStages: const [],
          sleepOnsetSec: SyntheticDay.sec(DateTime(2026, 10, 3, 19)),
          sleepOffsetSec: SyntheticDay.sec(DateTime(2026, 10, 4, 7)),
          sleepSource: 'auto_fallback',
          deviceNight: deviceNight,
        ).toJson()),
      );

  Future<SleepSessionCandidate> stored() async =>
      SleepSessionCandidate.fromJson((jsonDecode(
              (await LocalDb.sleepSessionCandidate(_day, kAlgoVersion))![
                  'payload_json'] as String) as Map)
          .cast<String, dynamic>());

  test('a banked band auto_fallback night survives a forced re-derive',
      () async {
    await bank(deviceNight: false);
    await DerivationEngine().runDays(_profile, {_day}, force: true);
    final got = await stored();
    expect(got.sleepSource, 'auto_fallback');
    expect(got.sleepJson['tst_sec'], 11 * 3600,
        reason: 'the band\'s own fallback night is kept over a shorter pass');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a banked device night is re-staged, not kept', () async {
    await bank(deviceNight: true);
    await DerivationEngine().runDays(_profile, {_day}, force: true);
    final got = await stored();
    expect(got.deviceNight, isFalse);
    expect(got.sleepJson['tst_sec'], isNot(11 * 3600));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('device_night round-trips and is absent from a band night\'s JSON', () {
    const band = SleepSessionCandidate(
      dayId: _day,
      confidence: 1,
      flags: [],
      sleepJson: {},
      hypnoStages: [],
      sleepOnsetSec: 0,
      sleepOffsetSec: 0,
    );
    expect(band.toJson().containsKey('device_night'), isFalse);
    final dev = SleepSessionCandidate.fromJson({
      ...band.toJson(),
      'device_night': true,
    });
    expect(dev.deviceNight, isTrue);
    expect(dev.toJson()['device_night'], isTrue);
  });
}
