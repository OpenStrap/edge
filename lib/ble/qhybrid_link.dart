// Fossil/Skagen Q Hybrid: pairing IS the one session this band gets, and
// [QHybridLink.sync] is that same session re-run — there is no cursor, no
// history, and no arm/disarm pair, only "hold the link open a bounded window
// and bank whatever the watch sends".
//
// WHY THIS FILE EXISTS. A heart-rate strap is driven by `HrsLink.arm()`,
// which a workout starts and stops. Oura has its own background sync,
// re-runnable from the ring's own page (`OuraLink`). This band has neither —
// nothing derives from it (`QHybridAdapter.signals` is empty) so there is no
// workout to arm it for, and no ongoing number to keep fresh so there is
// nothing to "sync" in the fetch-by-cursor sense. Writing only the `device`
// row (what `HrsLink.pairNotifySensor` does on its own) would leave
// `QHybridAdapter` undriven from the moment that row exists: `BandHost` never
// archives a byte without a `buildArchive` callback (`adapters/host.dart`'s
// own `_bufferArchive`), and nothing else in this app ever constructs a
// `BandHost` for this adapter. So pairing has to run a session, and that same
// session has to be re-runnable — the raw bytes a future decoder might want
// are worth more than one 10-second window right after pairing.
//
// BEST-EFFORT, AND BOUNDED. [pairQHybrid] returns as soon as the `device` row
// is written — the same promise `pairNotifySensor` already makes elsewhere —
// and the session that follows cannot fail that promise: nothing here can
// un-pair a device that answered a moment ago. Every session is capped at
// [_kSessionWindow]; an unbounded live link nobody is watching a spinner for
// is a battery cost and a scan/connect fight with the primary band, the same
// reason `HrsLink` disarms the moment a workout ends.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart' show kQHybrid;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart';
import 'adapters/qhybrid.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;
import 'hrs_link.dart' show HrsLink;

/// Pair a Fossil/Skagen Q Hybrid, then drive one bounded session over it so
/// pairing means more than a `device` row — see this file's own header.
Future<String?> pairQHybrid(BluetoothDevice device, {String? label}) async {
  final failure =
      await HrsLink.pairNotifySensor(kQHybrid, device, label: label);
  if (failure != null) return failure;
  // Re-finds the row `pairNotifySensor` just wrote and reconnects by
  // `remote_id` — the exact same path a later manual/background sync takes —
  // rather than a second, parallel drain implementation over the still-live
  // `device` handle.
  unawaited(QHybridLink.instance.sync());
  return null;
}

/// The live link to a paired Q Hybrid. One instance; a second concurrent one
/// is not a thing anyone asked for.
class QHybridLink {
  QHybridLink._();
  static final QHybridLink instance = QHybridLink._();

  /// How long one session holds the link open once connected. Bounded rather
  /// than open-ended — see the header note.
  static const Duration _sessionWindow = Duration(seconds: 10);

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kQHybrid.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: drop its `device` row. No key to drop — see the
  /// registry entry's own doc on why this family needs none.
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[qhybrid] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;

  /// Kept only so teardown can [GattBandLink.close] it — that is what stops a
  /// write the adapter queued before teardown from landing on a LATER
  /// connection to the same watch.
  GattBandLink? _link;

  /// The session driving [kQHybridAdapter] over [_link] — see `adapters/host.dart`.
  BandHost? _host;

  /// `device.id` of the paired watch. Never [LocalDb.kPrimaryDeviceId].
  String? _deviceId;

  bool _busy = false;

  /// Connect to the paired watch, hold the session for [_sessionWindow],
  /// disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed (including
  /// the adapter abstaining because the probe never confirmed — see
  /// `qhybrid.dart`). SERIALISED: a second call while one is in flight is a
  /// no-op rather than a second radio session over the same peripheral.
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
      debugPrint('[qhybrid] refusing to sync: the row claims the primary '
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
          await device.connect(timeout: const Duration(seconds: 12));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kQHybrid,
            services: services,
            onLog: (m) => debugPrint('[qhybrid] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kQHybrid.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[qhybrid] ${kQHybrid.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: kQHybridAdapter,
            deviceId: deviceId,
            onLog: (m) => debugPrint('[qhybrid] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          // Whichever finishes first: the adapter abstaining on its own (no
          // probe reply) or the bounded window running out on a confirmed,
          // still-open session. `stop()` is safe either way — `BandHost`'s
          // own doc says so, and it is what flushes whatever this session
          // banked before the link goes down.
          await host.run(link).timeout(_sessionWindow, onTimeout: () {});
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[qhybrid] sync failed: $e');
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
}

/// Bank one frame verbatim, undecoded (owner rulings R1-R3).
///
/// `reason` names the BAND, not the characteristic: six of them share this
/// one archive path and, unlike Oura's frames (which carry their own type
/// byte — see `oura_link.dart`'s `_buildArchiveRow`), qhybrid's do not
/// self-identify which characteristic produced them. Recovering that per
/// frame needs a source tag threaded through `SampleBatch`/`BandHost` itself
/// — a shared-seam change every multi-characteristic notify adapter would
/// benefit from, not something this one band's archive builder can invent on
/// its own — so it is left for that change rather than guessed at here.
ArchiveRecord _buildArchiveRow(List<int> bytes, int capturedAtMs) =>
    ArchiveRecord(
      hex: _hex(bytes),
      counter: null,
      packetType: bytes.isNotEmpty ? bytes[0] : 0,
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'qhybrid_raw',
    );

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
