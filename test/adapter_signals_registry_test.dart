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
import 'package:openstrap_edge/ble/adapters/hplus.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
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
      'hplus': const HPlusAdapter().signals,
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
    expect(declaredSignals('oura'), isEmpty);
    expect(declaredSignals('nothing-we-speak'), isEmpty);
    expect(declaredSignals(null), isEmpty);
  });
}
