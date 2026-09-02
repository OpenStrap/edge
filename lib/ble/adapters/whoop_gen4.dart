// gen4/gen5 as a [BandAdapter], by DELEGATION. NO DECODE LOGIC LIVES HERE —
// every byte-level fact (opcodes, offsets, framing) stays in `ble_engine.dart`
// and the sealed `protocol` package. This file exists so the seam has an
// entry for the primary band at all; it is a facade, not a second decoder.
//
// `run(link)` DELIBERATELY IGNORES `link` in this wave. `BleEngine` owns its
// own `flutter_blue_plus` connection — connect, bond, MTU 247, connection
// priority, service discovery, the per-peripheral band claim, CoreBluetooth
// restoration — and none of that can be expressed through [BandLink] without
// moving it, which is M2's transport split. What THIS wave buys is that the
// host (`BandHost.commitNativeBatch`), not the engine, owns the commit call
// and (from M1b) the commit-then-confirm ordering — exercised by their real
// originating implementer (gen4) instead of only by the two notify sensors
// that carry none of gen4's hazards (no offload, no ACK, no flash to trim).
//
// M2 replaces the engine's link with `link` and deletes this file's
// `UnsupportedError`. Until then the fiction is loud, not silent: calling
// `run()` is a programming error, and nothing in M1 calls it — app_state.dart
// and background_sync.dart still drive `BleEngine` directly and only route
// its COMMIT and ACK through `BandHost` (see M1a/M1b).
import 'dart:async';

import '../ble_engine.dart' show BleEngine;
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// gen4 R24 v24/v12 — every entry is a column `LocalDb._queueDecodedOneHz`
/// actually writes (db.dart:4722, cross-checked against the schema rather
/// than the wire offsets, which are protocol-repo facts this file cannot
/// verify without touching the sealed protocol package). `ppgGreen` (the
/// green channel, @29/31) is NOT declared — it lands in `samples`, not a
/// substrate column any metric reads. `accelHighRate` is NOT declared — R10's
/// 100 Hz stream is ephemeral and never persisted (invariant 1), and a 1 Hz
/// accel bound is invalid there anyway (see `signals.dart`).
const Map<InputSignal, Duration> kWhoopGen4Signals = <InputSignal, Duration>{
  InputSignal.hr1Hz: Duration(seconds: 1), // hr u8@17
  InputSignal.rrIntervals: Duration(seconds: 1), // rrCount@18 + i16LE pairs@19
  InputSignal.accel1Hz: Duration(seconds: 1), // f32 @36/40/44
  InputSignal.ppgRedIr: Duration(seconds: 1), // u16 @64/66
  InputSignal.skinTempRaw: Duration(seconds: 1), // u16 @68
};

class WhoopFramedAdapter extends BandAdapter {
  const WhoopFramedAdapter(this._engine, this.entry);

  final BleEngine _engine;

  /// The delegate. Unused by anything in M1 (see the file header) — kept
  /// reachable for the caller that constructs this facade and for M2, which
  /// is what finally drives it through [run].
  BleEngine get engine => _engine;

  @override
  final BandEntry entry;

  @override
  Map<InputSignal, Duration> get signals => kWhoopGen4Signals;

  @override
  Stream<BandEvent> run(BandLink link) {
    throw UnsupportedError(
      'WhoopFramedAdapter.run() is not wired in M1 — BleEngine drives its '
      'own flutter_blue_plus connection directly, not through a BandLink. '
      "See this file's header; M2's transport split is what makes this "
      'callable.',
    );
  }
}
