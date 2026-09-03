// M6 -- who wins a metric whose required signals do NOT agree.
//
// `signalWinners` + `unanimousWinner` are what the metric-detail caption and
// its "Prefer this device" button read. The pair exists because the screen
// used to read `signalPriority(spec.requires.first)` and call that winner the
// metric's preferred device: readiness needs four signals, and one of them
// cannot answer for the other three.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  test('split winners have no unanimous device', () {
    // The strap wins beat timing; continuous heart rate has no row, so it
    // falls through to the band.
    final winners = signalWinners(
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

  test('one device winning every required signal is unanimous', () {
    // The band, because it is the only one of the two that DECLARES both:
    // the strap has no continuous heart rate, so ranking it first for
    // `hr1Hz` cannot make it the winner there (and the priority editor never
    // offers it that row).
    final winners = signalWinners(
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
      () {
    // 'ring-GONE' was forgotten (or declares nothing, like the Oura ring):
    // it has no adapter to serve the window, so it is not the winner.
    final winners = signalWinners(
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
}
