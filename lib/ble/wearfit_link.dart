// The HOST for a paired WearFit-family band: connect, run [WearFitAdapter]
// over the link, bank what comes back, disconnect. One-shot, the same shape
// as [OuraLink.sync] and for the same reason — this band has no continuous
// broadcast to arm the way a workout heart-rate strap does, so a session is
// "connect, ask, listen for a while, tear down" rather than an arm/disarm
// pair.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `WearFitAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number.
//
// NO PAIRING KEY, NO CURSOR, NO ANCHOR — the three things `oura_link.dart`
// has to hold that this file genuinely does not: this family needs no key
// exchange, keeps no fetch-by-range history to resume, and every frame is
// stamped on arrival rather than against a device clock this build reads
// back. That is what makes this file the smaller of the two, not an
// oversight relative to it.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/wearfit.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// The live link to a paired WearFit band. One instance; a second concurrent
/// band of this family is not a thing anyone asked for.
class WearFitLink {
  WearFitLink._();
  static final WearFitLink instance = WearFitLink._();

  /// The `device` row for the paired band, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kWearFit.id) return r;
    }
    return null;
  }

  /// The band's own most recent battery report, or null.
  ///
  /// NOT written to `band_battery` — same reason `OuraLink.batteryPct` is
  /// not: that table has no `device_id` column, so a second device's cell
  /// would land in the primary band's own pack-health series.
  int? get batteryPct => _batteryPct;
  bool? get batteryCharging => _batteryCharging;
  int? _batteryPct;
  bool? _batteryCharging;

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  String? _deviceId;
  bool _busy = false;

  /// Connect, run one session, disconnect. Returns false when nothing is
  /// paired or the connect/setup failed. SERIALISED: a second call while one
  /// is in flight is a no-op rather than a second radio session over the
  /// same peripheral.
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
      debugPrint('[wearfit] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;
    try {
      // A cap on concurrent SECONDARY links — see `ble_state.dart`'s
      // `kMaxConcurrentSecondaryLinks` doc, same slot `OuraLink` shares.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kWearFit,
            services: services,
            onLog: (m) => debugPrint('[wearfit] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kWearFit.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[wearfit] ${kWearFit.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const WearFitAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[wearfit] $m'),
            onNote: _handleNote,
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released — same
          // ordering `OuraLink._sync` uses and for the same reason: held in
          // the outer `finally` it would run after the slot had already been
          // released, letting the next queued link connect while this one
          // was still disconnecting.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[wearfit] sync failed: $e');
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
    _deviceId = null;
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
      case 'battery_charging':
        if (value is bool) _batteryCharging = value;
      default:
        debugPrint('[wearfit] $key = $value');
    }
  }

  /// Bank one frame verbatim, decoded or not (owner rulings R1-R3).
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final f = parseWearFitFrame(bytes);
    if (f == null) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0 — this family has no flash-record counter, and `counter`
      // is what `thinRawArchiveBefore` samples on. Same reasoning as Oura's
      // own archive row.
      counter: null,
      packetType: f.opcode,
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'wearfit_evt_0x${f.opcode.toRadixString(16).padLeft(2, '0')}',
    );
  }

  /// Forget a paired band: stop any live session, drop its `device` row.
  ///
  /// Called from `HrsLink.forgetDevice`'s dispatch, before the row goes, so a
  /// sync already in flight for this exact device does not keep running
  /// underneath a row that no longer exists.
  static Future<bool> forgetDevice(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[wearfit] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) {
      await instance.stop();
    }
    await LocalDb.deleteDevice(id);
    return true;
  }
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
