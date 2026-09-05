// The HOST for a paired Coros watch: connect, pull a battery/identity status
// and whatever heart rate arrives during a bounded window, bank it,
// disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `CorosAdapter.signals`
// covers only the generic HR parse, and `coros` is absent from
// `kDerivableSources` — see `adapters/coros.dart`'s own header.
//
// WHY A BOUNDED WINDOW, NOT FETCH-BY-CURSOR OR ARM/DISARM. Same reasoning as
// `dafit_link.dart`: this watch is continuously worn, not a workout-scoped
// strap, and there is no stored-history request this project decodes and no
// natural end-of-session signal — so a periodic background `sync()` (connect
// briefly, read status, catch a few HR samples, disconnect) is the right
// cadence, and a fixed window is the honest floor for it.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/_registry.dart';
import 'adapters/coros.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// The live link to a paired Coros watch. One instance; a second concurrent
/// one is not a thing anyone asked for.
class CorosLink {
  CorosLink._();
  static final CorosLink instance = CorosLink._();

  /// How long one session holds the link open once connected. Bounded rather
  /// than open-ended — see the header note.
  ///
  /// 12s, not the 8s every other secondary link uses: [CorosAdapter.run]
  /// does four sequential status reads BEFORE it ever subscribes to heart
  /// rate, and each read carries its own [GattBandLink] timeout. Sized so a
  /// fully unresponsive watch (four reads, each timing out) still leaves a
  /// few real seconds for the heart-rate subscription to matter, instead of
  /// the whole window being spent finding out nothing answers.
  static const Duration _sessionWindow = Duration(seconds: 12);

  /// The last status pull, held in memory only — same non-durability as
  /// `OuraLink.batteryPct`/`batteryMv`: `band_battery` has no `device_id`
  /// column, and a model/serial/firmware string is not a time series.
  int? get batteryPct => _batteryPct;
  String? get model => _model;
  String? get serial => _serial;
  String? get firmware => _firmware;
  int? _batteryPct;
  String? _model;
  String? _serial;
  String? _firmware;

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kCoros.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: drop its `device` row. No key to drop — this
  /// family needs none.
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[coros] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — stops a write the
  /// adapter queued before teardown from landing on a LATER connection to the
  /// same watch.
  GattBandLink? _link;

  /// The session driving [CorosAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired watch. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired watch, hold the session for [_sessionWindow],
  /// disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. SERIALISED:
  /// a second call while one is in flight is a no-op rather than a second
  /// radio session over the same peripheral.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    final row = await pairedRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[coros] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;

    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). This sync's
      // connect, session and disconnect all complete inside this one call, so
      // the simple scoped form is correct here.
      //
      // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately — held in an outer
      // `finally` it would run AFTER `withSecondaryLinkSlot` had already
      // released the slot, letting the next queued link connect while this
      // one was still disconnecting.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kCoros,
            services: services,
            onLog: (m) => debugPrint('[coros] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kCoros.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[coros] ${kCoros.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const CorosAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[coros] $m'),
            onNote: _handleNote,
          );
          _host = host;
          // The adapter holds this open for as long as the link lives, so
          // this session is bounded here, not by anything the watch or the
          // adapter itself signals.
          await host.run(link).timeout(_sessionWindow, onTimeout: () {});
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[coros] sync failed: $e');
      return false;
    }
  }

  /// Verbatim the same shape as `OuraLink`'s own note switch — moved, not
  /// invented — for the four facts [CorosAdapter] can report about itself.
  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'model':
        if (value is String) _model = value;
      case 'serial':
        if (value is String) _serial = value;
      case 'firmware':
        if (value is String) _firmware = value;
    }
  }

  /// Drop the link, flush what the session banked, disconnect. Safe to call
  /// when nothing is connected.
  Future<void> stop() async {
    // Before the host's run subscription is cancelled: an adapter's `finally`
    // can still write on the way out, and that write must not reach the radio.
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
    _deviceId = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }
}
