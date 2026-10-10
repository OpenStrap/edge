// A Colmi ring as the active wearable after the raw-row prune
// (pruneDecodedBeforeRecTs) took the evening before the oldest kept day.
// Through the real Colmi link and the real engine: a forced re-derive keeps
// the night our HR-led window banked off the ring's rows, and turning the
// ring's flag off then leaves nothing of it on any day, pruned or not
// (rule R6).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/colmi_link.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/inputs/canonical.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/synthetic_day.dart';

final List<SyntheticDay> _days = [
  for (var d = 1; d <= 4; d++) SyntheticDay(DateTime(2026, 10, d)),
];
const String _dayId = '2026-10-04';
const String _id = 'colmi-pruned';
const Profile _profile =
    Profile(ageYears: 32, weightKg: 72, heightCm: 176, sex: 'm');
final DateTime _now = DateTime(2026, 10, 4, 22, 30);

Future<SleepSessionCandidate> _night() async => SleepSessionCandidate.fromJson(
    (jsonDecode((await LocalDb.sleepSessionCandidate(_dayId, kAlgoVersion))![
            'payload_json'] as String) as Map)
        .cast<String, dynamic>());

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await LocalDb.close();
    LocalDb.dbName = 'colmi_pruned_rows_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.upsertDevice(
        id: _id, adapterId: 'colmi', remoteId: 'AA:BB:CC:00:00:07', label: _id);
    // A ring that stages no night of its own: our HR-led window is the night.
    await ColmiLink.instance.ingestForTest(
        _id,
        (_, w) => w[0] == kColmiCmdBigData && w[1] == kColmiBigSleep
            ? [colmiBigDataRequest(kColmiBigSleep, [0])]
            : SyntheticDay.colmiRingReply(_days, w, _now),
        nowSeconds: () => SyntheticDay.sec(_now));
    await LocalDb.setCursor(kActiveWearableCursor, _id);
    await LocalDb.setCursor(wearableEnabledCursor('colmi'), '1');
  });

  tearDownAll(() async {
    onWearableDaysChanged = null;
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a forced re-derive after the prune keeps the banked HR-led night, '
      'and the flag going off clears every day the ring decided', () async {
    final ids = {
      for (final d in _days) d.day.toIso8601String().substring(0, 10)
    };
    await DerivationEngine().runDays(_profile, ids, force: true);
    final banked = await _night();
    expect(banked.sleepSource, 'auto_fallback');
    expect(banked.deviceNight, isTrue);
    expect(banked.deviceId, _id);
    final midnight = SyntheticDay.sec(DateTime(2026, 10, 4));
    expect(banked.sleepOnsetSec, lessThan(midnight),
        reason: 'the night began the evening before');

    await LocalDb.pruneDecodedBeforeRecTs(midnight);
    await DerivationEngine().runDays(_profile, {_dayId}, force: true);
    final again = await _night();
    expect(again.sleepOnsetSec, banked.sleepOnsetSec,
        reason: 'less of the ring\'s rows, not a shorter night');
    expect(again.sleepOffsetSec, banked.sleepOffsetSec);

    // Rule R6 over pruned days: 10-01..10-03 have no raw rows left.
    onWearableDaysChanged = (days) async {
      await DerivationEngine().runDays(_profile, days, force: true);
    };
    await setWearableEnabled('colmi', false);
    for (final d in ids) {
      expect(await LocalDb.dayResult(d), isNull, reason: d);
      expect(
          await (await LocalDb.instance)
              .query('metric_series', where: 'date = ?', whereArgs: [d]),
          isEmpty,
          reason: d);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
