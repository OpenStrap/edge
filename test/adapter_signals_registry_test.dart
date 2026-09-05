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
import 'package:openstrap_edge/ble/adapters/banglejs.dart';
import 'package:openstrap_edge/ble/adapters/ble_hrs.dart';
import 'package:openstrap_edge/ble/adapters/casio.dart';
import 'package:openstrap_edge/ble/adapters/colmi.dart';
import 'package:openstrap_edge/ble/adapters/coros.dart';
import 'package:openstrap_edge/ble/adapters/dafit.dart';
import 'package:openstrap_edge/ble/adapters/dt78.dart';
import 'package:openstrap_edge/ble/adapters/garmin.dart';
import 'package:openstrap_edge/ble/adapters/hplus.dart';
import 'package:openstrap_edge/ble/adapters/id115.dart';
import 'package:openstrap_edge/ble/adapters/jyou.dart';
import 'package:openstrap_edge/ble/adapters/lefun.dart';
import 'package:openstrap_edge/ble/adapters/makibeshr3.dart';
import 'package:openstrap_edge/ble/adapters/miband234.dart';
import 'package:openstrap_edge/ble/adapters/o2ring.dart';
import 'package:openstrap_edge/ble/adapters/oura.dart';
import 'package:openstrap_edge/ble/adapters/pebble.dart';
import 'package:openstrap_edge/ble/adapters/pinetime.dart';
import 'package:openstrap_edge/ble/adapters/polar_pmd.dart';
import 'package:openstrap_edge/ble/adapters/qhybrid.dart';
import 'package:openstrap_edge/ble/adapters/ring11m.dart';
import 'package:openstrap_edge/ble/adapters/ringconn.dart';
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/ble/adapters/smaq2oss.dart';
import 'package:openstrap_edge/ble/adapters/tlw64.dart';
import 'package:openstrap_edge/ble/adapters/ultrahuman.dart';
import 'package:openstrap_edge/ble/adapters/watch9.dart';
import 'package:openstrap_edge/ble/adapters/wearfit.dart';
import 'package:openstrap_edge/ble/adapters/whoop_gen4.dart';
import 'package:openstrap_edge/ble/adapters/withings_steel_hr.dart';
import 'package:openstrap_edge/ble/adapters/xwatch.dart';
import 'package:openstrap_edge/ble/adapters/zetime.dart';

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
      'ring11m': const Ring11mAdapter().signals,
      'coros': const CorosAdapter().signals,
      'garmin': const GarminAdapter().signals,
      'ultrahuman': UltrahumanAdapter().signals,
      'withings_steel_hr': WithingsSteelHrAdapter(firstConnect: true).signals,
      'miband234': MiBand234Adapter(key: const [0]).signals,
      'pebble': kPebbleAdapter.signals,
      'makibeshr3': const MakibesHr3Adapter().signals,
      'id115': const Id115Adapter().signals,
      'smaq2oss': const Smaq2ossAdapter().signals,
      'xwatch': const XWatchAdapter().signals,
      'tlw64': const Tlw64Adapter().signals,
      'dafit': kDafitAdapter.signals,
      'o2ring': const O2RingAdapter().signals,
      'zetime': const ZeTimeAdapter().signals,
      'wearfit': const WearFitAdapter().signals,
      'ringconn': RingConnAdapter().signals,
      'dt78': const Dt78Adapter().signals,
      'lefun': LefunAdapter().signals,
      'hplus': const HPlusAdapter().signals,
      'pinetime': kPineTimeAdapter.signals,
      'qhybrid': kQHybridAdapter.signals,
      'colmi': kColmiAdapter.signals,
      'casio': const CasioAdapter().signals,
      'jyou': const JyouAdapter().signals,
      'watch9': const Watch9Adapter().signals,
      'banglejs': kBangleJsAdapter.signals,
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
    expect(declaredSignals('withings_steel_hr'), isEmpty);
    expect(declaredSignals('pebble'), isEmpty);
    expect(declaredSignals('casio'), isEmpty);
    expect(declaredSignals('nothing-we-speak'), isEmpty);
    expect(declaredSignals(null), isEmpty);
  });
}
