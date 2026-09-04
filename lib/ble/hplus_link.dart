// The HOST for a paired HPlus-family band: connect, run [HPlusAdapter] over
// the link for one bounded collection window, bank what comes back,
// disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `HPlusAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number: it banks battery and firmware notes plus raw
// frames only, never a `NeutralSample`.
//
// CONNECT-ON-DEMAND, SYNC TRIGGERED EXPLICITLY — the same shape as
// `oura_link.dart`'s one-shot `sync()`, not `hrs_link.dart`'s workout-armed
// session: this is a continuously-worn band, not a chest-strap-for-a-workout
// accessory. But unlike the ring, it has no fetch-by-cursor history to drain
// either — every notification is a live reading, not a flash record — so
// there is no cursor and no anchor to persist between connections. A sync
// connects, gives the band [collectFor] to answer the init sequence and
// stream, then tears the link down.
//
// NO PAIRING KEY, EITHER. Unlike the ring and the Mi Band, this wire has no
// auth handshake — pairing is the plain notify-class flow
// `HrsLink.pairNotifySensor` already runs for every unauthenticated sensor —
// so there is no secret to store, drop, or clean up on forgetting; forgetting
// this band is the same generic `HrsLink.forgetDevice` every other
// unauthenticated notify-class sensor already uses.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/hplus.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired HPlus-family band. One instance; a second
/// concurrent band of this kind is not a thing anyone asked for.
class HPlusLink {
  HPlusLink._();
  static final HPlusLink instance = HPlusLink._();

  /// The `device` row for the paired band, or null.
  static Future<Map<String, Object?>?> pairedSensorRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kHPlus.id) return r;
    }
    return null;
  }

  /// The most recent battery reading the band reported, or null.
  ///
  /// DELIBERATELY NOT WRITTEN TO `band_battery` — see `oura_link.dart`'s
  /// identical reasoning: that table has no `device_id` column, so a
  /// stranger's cell voltage would land in the WHOOP band's own pack-health
  /// series with no way to tell them apart.
  int? get batteryPct => _batteryPct;
  int? _batteryPct;

  /// The most recent firmware-version string the band reported, or null.
  String? get firmwareVersion => _firmwareVersion;
  String? _firmwareVersion;

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// Connect to the paired band, run the init sequence, collect for
  /// [collectFor], then disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. SERIALISED:
  /// a second call while one is in flight is a no-op rather than a second
  /// radio session over the same peripheral.
  Future<bool> sync({Duration collectFor = const Duration(seconds: 20)}) {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync(collectFor).whenComplete(() => _busy = false);
  }

  Future<bool> _sync(Duration collectFor) async {
    final row = await pairedSensorRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      // The primary band's id, permanently. A sensor writing under it would
      // interleave its rows with the band's own.
      debugPrint('[hplus] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }

    try {
      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see `ble_state.dart`'s `kMaxConcurrentSecondaryLinks` doc).
      // This sync's connect, collect and disconnect all complete inside this
      // one call, so the simple scoped form is correct here.
      //
      // THE TEARDOWN IS INSIDE THE CLOSURE, deliberately — same reasoning as
      // `oura_link.dart`'s own `_sync`: held in an outer `finally` it would run
      // AFTER the slot had already been released, letting a queued link
      // connect while this one was still disconnecting.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kHPlus,
            services: services,
            onLog: (m) => debugPrint('[hplus] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kHPlus.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[hplus] ${kHPlus.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: kHPlusAdapter,
            deviceId: deviceId,
            onLog: (m) => debugPrint('[hplus] $m'),
            onNote: _handleNote,
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          final done = host.run(link);
          // This adapter's stream has no natural end — it is a continuous
          // notify loop — so nothing else stops it. Give the band its
          // collection window, then end the session the same way a workout
          // screen ends a live one: `host.stop()`.
          unawaited(Future<void>.delayed(
              collectFor, () => unawaited(host.stop())));
          await done;
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[hplus] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session banked, disconnect. Safe to call
  /// when nothing is connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {/* already gone */}
    }
  }

  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'firmware':
        if (value is String) _firmwareVersion = value;
      default:
        debugPrint('[hplus] $key = $value');
    }
  }

  /// Bank one frame verbatim, decoded or not (owner rulings R1-R3): the
  /// realtime-stats fields this file does not decode, the sleep record and
  /// the day-summary variants are all in here undecoded, banked now so a
  /// decoder written when someone owns a unit can be run over them.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This wire has no flash-record counter — see
      // `oura_link.dart`'s identical reasoning for why a constant here would
      // be accidental thinning policy rather than a real absence.
      counter: null,
      packetType: bytes[0], // the tag byte
      // NULL. Nothing on this wire carries a clock; every frame is stamped
      // on arrival, not decoded from the bytes.
      recTs: null,
      capturedAt: capturedAtMs,
      // ONE REASON PER TAG, so a decoder written later finds its records by
      // name instead of re-scanning the table.
      reason: 'hplus_evt_0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
    );
  }
}
