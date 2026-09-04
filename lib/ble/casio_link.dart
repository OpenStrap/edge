// The HOST for a paired Casio-class watch: connect to its stored remote id,
// drive [CasioAdapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `CasioAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number — every row it commits carries a non-null
// `source`.
//
// THIN COUSIN OF `watch9_link.dart`. There is no drain cursor and no time
// anchor to hold, so this is the same one-shot `sync()` shape: connect,
// let the adapter's own probe run to completion (it has its own per-tag
// timeout — see `CasioAdapter.replyTimeout`), tear down.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/_registry.dart';
import 'adapters/casio.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'ble_state.dart' show withSecondaryLinkSlot;

/// The live link to a paired Casio-class watch. One instance; a second
/// concurrent watch of this family is not a thing anyone asked for.
class CasioLink {
  CasioLink._();
  static final CasioLink instance = CasioLink._();

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kCasio.id) return r;
    }
    return null;
  }

  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// How long one sync session waits for the adapter's own probe to finish
  /// before tearing down regardless. The probe already bounds itself (five
  /// tags at [CasioAdapter.replyTimeout] apiece), so this is a backstop, not
  /// the thing that decides when the session ends.
  static const Duration _listenWindow = Duration(seconds: 25);

  /// Connect, run the probe, disconnect.
  ///
  /// Returns false when nothing is paired or the connect failed. Never
  /// throws. SERIALISED: a second call while one is in flight is a no-op
  /// rather than a second radio session over the same peripheral.
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
      // The primary band's id, permanently. This watch writing under it
      // would interleave its (undecoded, sample-less) rows with the band's
      // own.
      debugPrint('[casio] refusing to sync: the row claims the primary '
          'device id — re-pair it with a minted id.');
      return false;
    }

    try {
      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kCasio,
            services: services,
            onLog: (m) => debugPrint('[casio] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kCasio.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[casio] ${kCasio.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            await device.disconnect().catchError((_) {});
            return false;
          }
          final host = BandHost(
            adapter: const CasioAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[casio] $m'),
          );
          _host = host;
          final done = host.run(link);
          try {
            await done.timeout(_listenWindow, onTimeout: () {});
          } finally {
            await stop();
            try {
              await device.disconnect();
            } catch (_) {/* already gone */}
          }
          return true;
        } catch (e) {
          debugPrint('[casio] connect failed: $e');
          return false;
        }
      });
    } catch (e) {
      debugPrint('[casio] sync failed: $e');
      return false;
    }
  }

  /// Drop the link, flush what has been buffered. Safe when nothing is
  /// connected.
  Future<void> stop() async {
    _link?.close();
    _link = null;
    await _host?.stop();
    _host = null;
  }
}
