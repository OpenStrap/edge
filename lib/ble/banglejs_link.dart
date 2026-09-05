// The HOST for Bangle.js (or any generic Nordic-UART device): hold the
// paired row, connect, drive [BangleJsAdapter] over the link for a bounded
// window, bank whatever raw bytes arrive, disconnect.
//
// THE SHAPE, AND WHY IT IS OURA'S, NOT HrsLink's. A heart-rate strap is a
// live session armed by a workout; this pipe is neither that nor a
// fetch-by-cursor store — `banglejs.dart`'s `run()` just re-emits every
// notification for as long as the link stays open, and there is no
// end-of-history signal because a third-party JS app decides on its own
// schedule whether to print anything at all. So there is nothing to arm for
// a workout and nothing to drain to the end of: a one-shot [sync] connects,
// gives the watch a bounded window to say whatever it is going to say, and
// disconnects. Same host work and order as `oura_link.dart` otherwise: read
// the `device` row, connect by `remote_id`, discover, check
// [GattBandLink.missingCharacteristics], drive `run()`, stop, disconnect.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/banglejs.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Bangle.js. One instance; a second concurrent one
/// is not a thing anyone asked for.
class BangleJsLink {
  BangleJsLink._();
  static final BangleJsLink instance = BangleJsLink._();

  /// How long a sync stays connected giving the watch a chance to print
  /// something. There is no end-of-history signal on this pipe, so this is a
  /// window, not a drain to completion.
  static const Duration _listenWindow = Duration(seconds: 20);

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kBangleJs.id) return r;
    }
    return null;
  }

  /// Forget a paired watch: stop it if it is live right now, drop the row.
  ///
  /// No secret to drop, unlike `OuraLink.forgetRing` — this pipe carries no
  /// key — but the connection still has to be torn down explicitly, the same
  /// reason that function exists: falling through to some OTHER link's
  /// teardown would leave this one connected while looking like a complete
  /// forget.
  static Future<bool> forget(String id) async {
    if (id == LocalDb.kPrimaryDeviceId) {
      debugPrint('[banglejs] refusing to forget the primary band from here.');
      return false;
    }
    if (instance._deviceId == id) await instance.stop();
    await LocalDb.deleteDevice(id);
    return true;
  }

  BluetoothDevice? _device;
  GattBandLink? _link;
  BandHost? _host;
  String? _deviceId;
  bool _busy = false;

  /// Connect to the paired watch, listen for [_listenWindow], disconnect.
  /// Returns false when nothing is paired or the connect failed.
  /// SERIALISED: a second call while one is in flight is a no-op rather than
  /// a second radio session over the same peripheral.
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
      // The primary band's id, permanently. A watch writing under it would
      // interleave its bytes with the band's in one REPLACE-keyed table.
      debugPrint('[banglejs] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }
    _deviceId = deviceId;
    try {
      // A cap on concurrent SECONDARY links (never the band's own connect —
      // see ble_state.dart's kMaxConcurrentSecondaryLinks doc). Connect,
      // listen and disconnect all complete inside this one call, so the
      // simple scoped form is correct here, same as `OuraLink._sync`.
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          _device = device;
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kBangleJs,
            services: services,
            onLog: (m) => debugPrint('[banglejs] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kBangleJs.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[banglejs] ${kBangleJs.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: kBangleJsAdapter,
            deviceId: deviceId,
            onLog: (m) => debugPrint('[banglejs] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          // Not awaited to completion: `run()`'s stream never ends on its
          // own for this adapter (see banglejs.dart) — only `stop()` (below,
          // in the `finally`) or the link closing does. The window is what
          // bounds this call.
          unawaited(host.run(link));
          await Future<void>.delayed(_listenWindow);
          return true;
        } finally {
          // Drop the link and DISCONNECT before the slot is released.
          await stop();
        }
      });
    } catch (e) {
      debugPrint('[banglejs] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what the session can still bank, disconnect. Safe
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

  /// Bank one chunk verbatim — nothing here is decoded (owner ruling R6).
  /// `counter` stays null: this pipe has no flash-record counter, and a 0
  /// would make every chunk `0 % 60 == 0`, i.e. permanently exempt from
  /// `thinRawArchiveBefore`. `packetType` has no meaning on a pipe with no
  /// frame structure at all — 0, not a guess at one.
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) =>
      ArchiveRecord(
        hex: _hex(bytes),
        counter: null,
        packetType: 0,
        recTs: null,
        capturedAt: capturedAtMs,
        reason: 'banglejs_uart',
      );
}
