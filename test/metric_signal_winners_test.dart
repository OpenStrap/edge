// M6 -- who wins a metric whose required signals do NOT agree.
//
// `signalWinners` + `unanimousWinner` are what the metric-detail caption and
// its "Prefer this device" button read. The pair exists because the screen
// used to read `signalPriority(spec.requires.first)` and call that winner the
// metric's preferred device: readiness needs four signals, and one of them
// cannot answer for the other three.
//
// Opens a real LocalDb (the `coverage_devices_by_day_test.dart` idiom) because
// `signalWinners` reads `device_coverage` directly since the kAlgoVersion 91
// fix: a device with coverage rows but no stored priority row (paired after
// the user last customized ranking) must still be found, the same union
// `_resolveOwnership` does in derivation_engine.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/data/db.dart' show LocalDb;
import 'package:openstrap_edge/ui2/profile/devices.dart';

const _band = HealthSource(
  name: 'WHOOP',
  kind: 'Band',
  tier: SourceTier.wristOptical,
  icon: Icons.watch,
  isBand: true,
  family: 'gen4',
);

const _strap = HealthSource(
  name: 'Polar H10',
  kind: 'Bluetooth heart rate sensor',
  tier: SourceTier.beatToBeat,
  icon: Icons.favorite,
  isBand: false,
  deviceId: 'ble_hrs-0a1b',
  family: 'ble_hrs',
);

// Two of readiness' four inputs — enough to disagree.
const _requires = {InputSignal.rrIntervals, InputSignal.hr1Hz};

Future<void> _insertCoverage(
  String deviceId,
  String signal,
  int startTs,
  int endTs,
) async {
  final db = await LocalDb.instance;
  await db.insert('device_coverage', {
    'device_id': deviceId,
    'signal': signal,
    'start_ts': startTs,
    'end_ts': endTs,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'metric_signal_winners_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    await LocalDb.instance; // run the ladder once.
  });

  tearDown(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('split winners have no unanimous device', () async {
    // The strap wins beat timing; continuous heart rate has no row, so it
    // falls through to the band.
    final winners = await signalWinners(
      const [_band, _strap],
      requires: _requires,
      stored: {
        InputSignal.rrIntervals.name: [_strap.deviceId!, LocalDb.kPrimaryDeviceId],
      },
      fallback: LocalDb.kPrimaryDeviceId,
    );
    expect(winners[InputSignal.rrIntervals], _strap.deviceId);
    expect(winners[InputSignal.hr1Hz], LocalDb.kPrimaryDeviceId);
    // The whole point: no single device is "the" preferred one here.
    expect(unanimousWinner(winners), isNull);
  });

  test('one device winning every required signal is unanimous', () async {
    // The band, because it is the only one of the two that DECLARES both:
    // the strap has no continuous heart rate, so ranking it first for
    // `hr1Hz` cannot make it the winner there (and the priority editor never
    // offers it that row).
    final winners = await signalWinners(
      const [_band, _strap],
      requires: _requires,
      stored: {
        for (final sig in _requires)
          sig.name: [LocalDb.kPrimaryDeviceId, _strap.deviceId!],
      },
      fallback: LocalDb.kPrimaryDeviceId,
    );
    expect(unanimousWinner(winners), LocalDb.kPrimaryDeviceId);
  });

  test('a row from a device that no longer declares the signal is passed over',
      () async {
    // 'ring-GONE' was forgotten (or declares nothing, like the Oura ring):
    // it has no adapter to serve the window, so it is not the winner.
    final winners = await signalWinners(
      const [_band],
      requires: const {InputSignal.rrIntervals},
      stored: {
        InputSignal.rrIntervals.name: ['ring-GONE', LocalDb.kPrimaryDeviceId],
      },
      fallback: LocalDb.kPrimaryDeviceId,
    );
    expect(unanimousWinner(winners), LocalDb.kPrimaryDeviceId);
  });

  test('nothing resolved is not agreement', () {
    // The single-device gate in metric_detail leaves the map empty, and an
    // empty map must not read as "one device wins everything".
    expect(unanimousWinner(const {}), isNull);
    expect(
      unanimousWinner(const {InputSignal.hr1Hz: null}),
      isNull,
    );
  });

  test(
      'a device paired after custom ranking wins on its real coverage instead '
      'of falling to the fallback', () async {
    // The exact kAlgoVersion 91 scenario: `stored` only names a device that
    // no longer declares `hr1Hz` (forgotten, same as the "ring-GONE" case
    // above), and the device that actually has real `device_coverage` rows
    // was paired after and never got a stored row. The engine's
    // `_resolveOwnership` unions it in below the stored order rather than
    // falling through to the fallback — this caption must agree, or it names
    // the wrong device for exactly the population #405 was written for.
    const secondBand = HealthSource(
      name: 'WHOOP 5',
      kind: 'Band',
      tier: SourceTier.wristOptical,
      icon: Icons.watch,
      isBand: false,
      deviceId: 'gen5-abcd',
      family: 'gen5',
    );
    await _insertCoverage('gen5-abcd', InputSignal.hr1Hz.name, 100, 200);

    final winners = await signalWinners(
      const [_band, secondBand],
      requires: const {InputSignal.hr1Hz},
      stored: {
        InputSignal.hr1Hz.name: ['ring-GONE'],
      },
      fallback: LocalDb.kPrimaryDeviceId,
    );
    expect(winners[InputSignal.hr1Hz], 'gen5-abcd');
  });
}
