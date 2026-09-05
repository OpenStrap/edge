// The HOST for a paired white-label smart ring ("R11M"/"R10M", also "TK5"):
// connect, negotiate, hold the session open for the adapter's bounded
// listen window, bank whatever it sends, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). `Ring11mAdapter.signals` is
// `const {}` and `ring11m` is absent from `kDerivableSources` — every row
// this file writes carries a non-null `source`, and nothing here becomes a
// number.
//
// NO KEY, NO CLOCK-BASED CURSOR TO PERSIST. Unlike Oura this family has no
// authentication handshake and no fetch-by-cursor history a bookmark could
// resume — see `ring11m.dart` in both `protocol` and `adapters/` for why. So
// this file, like `dafit_link.dart`, owns only the `device` row and the
// bounded session; there is nothing else to keep between syncs.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'adapters/ring11m.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired ring. One instance; a second concurrent one is
/// not a thing anyone asked for.
class Ring11mLink {
  Ring11mLink._();
  static final Ring11mLink instance = Ring11mLink._();

  /// The `device` row for the paired ring, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kRing11m.id) return r;
    }
    return null;
  }

  /// Forget a paired ring: drop its `device` row. No key to drop — this
  /// family has no authentication (see the header note).
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[ring11m] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same ring.
  GattBandLink? _link;

  /// The session driving [Ring11mAdapter] over [_link] — see
  /// `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired ring. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired ring, run one negotiate-and-listen session,
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
      debugPrint('[ring11m] refusing to sync: the row claims the primary '
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
            entry: kRing11m,
            services: services,
            onLog: (m) => debugPrint('[ring11m] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kRing11m.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[ring11m] ${kRing11m.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const Ring11mAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[ring11m] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          // The adapter itself bounds this — see `ring11m.dart`'s
          // `listenWindow` doc — so there is no outer timeout here.
          await host.run(link);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[ring11m] sync failed: $e');
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

  /// Bank one frame verbatim, decoded or not — this family's history-record
  /// decode coverage is deliberately zero (see `adapters/ring11m.dart`'s own
  /// header), so the bytes are archived now rather than a guess being run
  /// over them today.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0. This band has no flash-record counter this project
      // reads, and `counter` is what `thinRawArchiveBefore` samples on — a
      // constant 0 would make every one of this family's frames `0 % 60 ==
      // 0`, i.e. permanently exempt from thinning, which is accidental policy.
      counter: null,
      packetType: bytes.length > 1 ? bytes[1] : bytes[0],
      recTs: null,
      capturedAt: capturedAtMs,
      // Not in `LocalDb.redrivableArchiveReasons` — there is no decoder for
      // this family's history records yet to redrive them through.
      reason: 'ring11m_frame',
    );
  }
}
