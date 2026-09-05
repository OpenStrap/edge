// The HOST for a paired Garmin watch: connect, drive [GarminAdapter] over
// the link for one bounded session, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `GarminAdapter.signals` is
// `const {}` and `garmin` is absent from `kDerivableSources` — every row this
// file writes carries a non-null `source`, and nothing here becomes a number.
//
// WHY A BOUNDED WINDOW, NOT FETCH-BY-CURSOR OR ARM/DISARM — same reasoning as
// `dafit_link.dart`: this family's stored activity history (FIT files, the
// numbered real-time streams) is untouched this pass, so there is no
// natural end-of-transfer signal. A fixed window that opens the GFDI
// channel, receives the unprompted device-info push and one battery answer,
// then disconnects is the honest floor.
//
// PAIRING IS THE WATCH'S OWN MENU, NOT A KEY THIS FILE INSTALLS. Unlike the
// Oura ring, GFDI has no pairing-time credential exchange this pass
// implements — the watch has to be put into its own Settings -> Sensors &
// Accessories -> Phone -> Pair Phone screen before the OS-level bond this
// app's ordinary connect triggers will be accepted at all. That precondition
// is stated in the picker's blurb (`devices.dart`), the same way Oura's
// factory-reset precondition is — surfaced before the user commits, not
// discovered after a silent timeout.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/garmin.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Garmin watch. One instance; a second concurrent
/// one is not a thing anyone asked for.
class GarminLink {
  GarminLink._();
  static final GarminLink instance = GarminLink._();

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kGarmin.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: drop its `device` row. No key to drop — this
  /// family's session has no pairing-time credential this app installs.
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[garmin] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  /// The most recent battery reading the watch reported, or null. Not
  /// written to `band_battery` — same reasoning as `OuraLink`'s own doc:
  /// that table has no `device_id` and is read unfiltered, so a second
  /// device's cell voltage would land in the primary band's own series.
  int? get batteryPct => _batteryPct;
  int? _batteryPct;

  String? get model => _model;
  String? get firmware => _firmware;
  String? _model;
  String? _firmware;

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same watch.
  GattBandLink? _link;

  /// The session driving [GarminAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired watch. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired watch, hold the session for its bounded window,
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
      debugPrint('[garmin] refusing to sync: the row claims the primary '
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
            entry: kGarmin,
            services: services,
            onLog: (m) => debugPrint('[garmin] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kGarmin.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[garmin] ${kGarmin.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = _makeHost(deviceId, const GarminAdapter());
          _host = host;
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[garmin] sync failed: $e');
      return false;
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

  BandHost _makeHost(String deviceId, GarminAdapter adapter) => BandHost(
        adapter: adapter,
        deviceId: deviceId,
        onLog: (m) => debugPrint('[garmin] $m'),
        onNote: _handleNote,
        buildArchive: _buildArchiveRow,
      );

  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'model':
        if (value is String) _model = value;
      case 'firmware':
        if (value is String) _firmware = value;
      default:
        debugPrint('[garmin] $key = $value');
    }
  }

  /// Bank one frame verbatim, decoded or not — this family's decode coverage
  /// is deliberately narrow (device info, one battery answer, the plumbing
  /// acks), so everything else is archived undecoded rather than guessed at.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL: this band has no flash-record counter this project reads, and
      // `counter` is what `thinRawArchiveBefore` samples on — a constant 0
      // would make every one of this family's frames permanently exempt
      // from thinning, which is accidental policy.
      counter: null,
      packetType: bytes[0],
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'garmin_frame',
    );
  }
}
