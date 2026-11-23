// `kAdapterSignals` is KEPT IN SYNC BY HAND with each adapter's own `signals`
// declaration — `_registry.dart` says so, and explains why (importing the
// three adapters back into the file they all import their `BandEntry` from
// would be a cycle for three lines of data). A hand-synced table with no test
// is a table that drifts, and the drift is invisible: `declaredSignals` is
// what decides whether a device is a candidate for a metric at all, so a
// missing entry reads as "this band cannot measure that" rather than as a bug.
//
// A test has no cycle to worry about, so it compares both sides directly:
// membership AND the declared cadence.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/adapters/_registry.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/colmi.dart';
import 'package:openstrap_edge/ble/adapters/coros.dart';
import 'package:openstrap_edge/ble/adapters/garmin.dart';
import 'package:openstrap_edge/ble/adapters/helio_strap.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart';
import 'package:openstrap_edge/ble/adapters/pebble.dart';
import 'package:openstrap_edge/ble/adapters/polar_pmd.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/adapters/miscale.dart';
import 'package:openstrap_edge/ble/adapters/thermometer.dart';
import 'package:openstrap_edge/ble/adapters/ultrahuman.dart';
import 'package:openstrap_edge/ble/adapters/whoop_gen4.dart';

void main() {
  test('kAdapterSignals matches each adapter own declaration', () {
    final declared = <String, Map<InputSignal, Duration>>{
      // gen5 reuses gen4's map by design — same inner payload layout, only
      // the envelope differs (see `kWhoopGen5`'s doc).
      'gen4': kWhoopGen4Signals,
      'gen5': kWhoopGen4Signals,
      'ble_hrs': const BleHrsAdapter().signals,
      'oura': OuraAdapter(key: const [0]).signals,
      'polar_pmd': const PolarPmdAdapter().signals,
      'coros': const CorosAdapter().signals,
      'garmin': const GarminAdapter().signals,
      'ultrahuman': UltrahumanAdapter().signals,
      'miband234': MiBand234Adapter(key: const [0]).signals,
      'huami_cinco':
          MiBand234Adapter(key: const [0], entry: kMiBand4).signals,
      'huami_kongming':
          MiBand234Adapter(key: const [0], entry: kMiBand5).signals,
      'huami_pangu':
          MiBand234Adapter(key: const [0], entry: kMiBand6).signals,
      'huami_tonlesap':
          MiBand234Adapter(key: const [0], entry: kAmazfitBipS).signals,
      'huami_como':
          MiBand234Adapter(key: const [0], entry: kAmazfitBipU).signals,
      'huami_kestrel':
          MiBand234Adapter(key: const [0], entry: kAmazfitGts).signals,
      'huami_newton':
          MiBand234Adapter(key: const [0], entry: kAmazfitGts2).signals,
      'huami_falcon':
          MiBand234Adapter(key: const [0], entry: kAmazfitGtr).signals,
      'pebble': kPebbleAdapter.signals,
      'colmi': kColmiAdapter.signals,
      'helio_strap': kHelioStrapAdapter.signals,
      'zeppos_l66': kMiBand7Adapter.signals,
      'zeppos_verona': HelioStrapAdapter(entry: kAmazfitGtr3).signals,
      'zeppos_madrid': HelioStrapAdapter(entry: kAmazfitGtr3Pro).signals,
      'zeppos_zurich': HelioStrapAdapter(entry: kAmazfitGts3).signals,
      'thermometer': ThermometerAdapter().signals,
      'miscale_bc': MiScaleAdapter(kMiScaleComposition).signals,
      'miscale2': MiScaleAdapter(kMiScale2).signals,
      'amazfit_scale': AmazfitScaleAdapter().signals,
    };

    // Every registry id is covered above: a NEW adapter must extend this test,
    // not slip past it.
    expect(kAdapterSignals.keys.toSet(), declared.keys.toSet());

    for (final entry in declared.entries) {
      expect(
        kAdapterSignals[entry.key],
        entry.value,
        reason: 'kAdapterSignals["${entry.key}"] has drifted from the '
            'adapter\'s own `signals` — signals and/or durations differ',
      );
    }
  });

  test('declaredSignals reads the registry, and is empty for an unknown id',
      () {
    expect(declaredSignals('gen4'), kWhoopGen4Signals.keys.toSet());
    expect(declaredSignals('oura'), kOuraSignals.keys.toSet());
    expect(declaredSignals('pebble'),
        {InputSignal.hrSparse, InputSignal.steps, InputSignal.deviceStages});
    expect(declaredSignals('casio'), isEmpty,
        reason: 'a family this build removed reads as unknown');
    expect(declaredSignals('nothing-we-speak'), isEmpty);
    expect(declaredSignals(null), isEmpty);
  });
}
