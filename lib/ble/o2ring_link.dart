// The HOST for the Wellue O2Ring: connect, drive [O2RingAdapter] over the
// link, bank what comes back.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `O2RingAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number: its rows carry a non-null `source`, and
// every derive/export read filters `source IS NULL`.
//
// WHY THIS IS SO MUCH SHORTER THAN `oura_link.dart`. There is no pairing key
// to hold, no drain cursor and no time anchor: the ring has no authentication
// handshake at all (`o2ring.dart`'s own header explains why the file commands
// that would need a cursor are not implemented), so pairing here is nothing
// more than "does this peripheral expose the service and both
// characteristics" and a session is one request/reply round trip rather than
// a resumable drain.

import 'dart:async';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show parseO2RingFrame;

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import '../sync/paired_device.dart' show cleanDeviceLabel;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/o2ring.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired O2Ring. One instance; a second concurrent ring
/// is not a thing anyone asked for.
class O2RingLink {
  O2RingLink._();
  static final O2RingLink instance = O2RingLink._();

  /// The `device` row for the paired ring, or null.
  static Future<Map<String, Object?>?> pairedRingRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kO2Ring.id) return r;
    }
    return null;
  }

  /// Forget a paired ring: drop its `device` row. No key to drop — this ring
  /// holds no credential of ours.
  static Future<bool> forgetRing(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[o2ring] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  /// The most recent battery/model/serial the ring reported, or null.
  ///
  /// DELIBERATELY NOT WRITTEN TO `band_battery` — same reasoning as
  /// `OuraLink.batteryPct`'s own doc: that table has no `device_id` column, so
  /// a ring's battery would land in the WHOOP band's own pack-health series.
  int? get batteryPct => _batteryPct;
  String? get model => _model;
  String? get serial => _serial;

  /// Stored recording file names the ring reported, most recent INFO call.
  List<String> get files => _files;
  int? _batteryPct;
  String? _model;
  String? _serial;
  List<String> _files = const <String>[];

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired ring, ask for INFO, disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. SERIALISED:
  /// a second call while one is in flight is a no-op.
  Future<bool> sync() {
    if (_busy) return Future.value(false);
    _busy = true;
    return _sync().whenComplete(() => _busy = false);
  }

  Future<bool> _sync() async {
    final row = await pairedRingRow();
    if (row == null) return false;
    final deviceId = row['id'] as String?;
    final remoteId = row['remote_id'] as String?;
    if (deviceId == null || remoteId == null || remoteId.isEmpty) return false;
    if (deviceId == LocalDb.kPrimaryDeviceId) {
      debugPrint('[o2ring] refusing to sync: the ring row claims the '
          'primary device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;

    try {
      // A cap on concurrent SECONDARY links — see `ble_state.dart`'s
      // `kMaxConcurrentSecondaryLinks` doc. This sync's connect, session and
      // disconnect all complete inside this one call, so the simple scoped
      // form is correct, same as `OuraLink._sync`.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kO2Ring,
            services: services,
            onLog: (m) => debugPrint('[o2ring] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kO2Ring.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[o2ring] ${kO2Ring.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = _makeHost(deviceId);
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[o2ring] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session can still stamp, disconnect. Safe
  /// to call when nothing is connected.
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

  BandHost _makeHost(String deviceId) => BandHost(
        adapter: const O2RingAdapter(),
        deviceId: deviceId,
        onLog: (m) => debugPrint('[o2ring] $m'),
        onNote: _handleNote,
        buildArchive: _buildArchiveRow,
      );

  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'model':
        if (value is String) _model = value;
      case 'serial':
        if (value is String) _serial = value;
      case 'o2ring_files':
        if (value is String) {
          _files = value.isEmpty ? const <String>[] : value.split(',');
        }
      default:
        debugPrint('[o2ring] $key = $value');
    }
  }

  /// Bank one frame verbatim, decoded or not (owner rulings R1-R3): the INFO
  /// reply's JSON is parsed for [BandNote]s already, but the bytes are
  /// archived regardless so a future decoder (the file commands, once a real
  /// ring resolves the ambiguity `o2ring.dart` documents) has something to
  /// run over.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    final f = parseO2RingFrame(bytes);
    if (f == null) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0 — this band has no flash-record counter. See
      // `oura_link.dart`'s identical note on `thinRawArchiveBefore`.
      counter: null,
      packetType: f.cmd,
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'o2ring_cmd_0x${f.cmd.toRadixString(16).padLeft(2, '0')}',
    );
  }
}

/// Pair [device] as this phone's O2Ring. Null on success, or a sentence the
/// user can act on.
///
/// NO KEY, NO CHALLENGE. Unlike the Oura ring this device has no pairing
/// secret at all — the whole of "pairing" is confirming the peripheral
/// exposes the service and both characteristics, then minting a `device`
/// row. STILL HARDWARE-UNVERIFIED, like everything else on this path (R6).
Future<String?> pairO2Ring(BluetoothDevice device) async {
  final rnd = Random.secure();
  final deviceId =
      'o2ring-${_hex(List<int>.generate(4, (_) => rnd.nextInt(256)))}';
  GattBandLink? link;
  try {
    return await withSecondaryLinkSlot<String?>(
      timeout: const Duration(seconds: 30),
      onTimeout: () => 'Another sensor is using this phone’s Bluetooth right '
          'now. Try pairing again in a moment.',
      () async {
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final localLink = GattBandLink(
            entry: kO2Ring,
            services: services,
            onLog: (m) => debugPrint('[o2ring pair] $m'),
          );
          link = localLink;
          final missing =
              localLink.missingCharacteristics(kO2Ring.requiredCharacteristics);
          if (missing.isNotEmpty) {
            return 'That device does not expose the ring service this app '
                'speaks.';
          }
          await LocalDb.upsertDevice(
            id: deviceId,
            adapterId: kO2Ring.id,
            remoteId: device.remoteId.str,
            label: cleanDeviceLabel(device.platformName) ?? kO2Ring.label,
            // `tier` left unset: this ring supplies no signal at all today
            // (`O2RingAdapter.signals` is `const {}`), so there is no
            // measurement quality to rank. NULL is a refusal, not a default.
          );
          return null;
        } finally {
          link?.close();
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      },
    );
  } catch (e) {
    debugPrint('[o2ring pair] failed: $e');
    return 'Could not connect to that ring.';
  }
}
