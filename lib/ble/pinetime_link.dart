// The HOST for a paired PineTime: connect to its stored remote id, drive
// [PineTimeAdapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `PineTimeAdapter.signals` stays `const {}`, and nothing this
// file writes becomes a number — every row it commits carries a non-null
// `source`.
//
// THIN COUSIN OF `watch9_link.dart`. There is no auth, no drain cursor and
// no time anchor to hold — nothing here writes anything at all — so this is
// the same one-shot `sync()` shape: connect, listen for whatever the watch
// sends over one flush window, tear down.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/_registry.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/pinetime.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// The live link to a paired PineTime. One instance; a second concurrent
/// unit is not a thing anyone asked for.
class PineTimeLink {
  PineTimeLink._();
  static final PineTimeLink instance = PineTimeLink._();

  /// The `device` row for the paired watch, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kPineTime.id) return r;
    }
    return null;
  }

  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// How long one sync session listens before tearing down. There is no
  /// drain to finish and no cursor to exhaust — the watch just streams
  /// whatever it has — so this is a plain window, not a completion signal.
  static const Duration _listenWindow = Duration(seconds: 20);

  /// Connect, listen for [_listenWindow], disconnect.
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
    // The WHOLE body is inside this try now, `pairedRow()` included — a
    // `LocalDb.deviceRows()` failure used to escape uncaught, breaking
    // `sync()`'s no-throw contract and leaving the manual caller's "Syncing"
    // snackbar never replaced with a result.
    try {
      final row = await pairedRow();
      if (row == null) return false;
      final deviceId = row['id'] as String?;
      final remoteId = row['remote_id'] as String?;
      if (deviceId == null || remoteId == null || remoteId.isEmpty) {
        return false;
      }
      if (deviceId == LocalDb.kPrimaryDeviceId) {
        // The primary band's id, permanently. This watch writing under it
        // would interleave its (undecoded, sample-less) rows with the band's
        // own.
        debugPrint('[pinetime] refusing to sync: the row claims the primary '
            'device id — re-pair it with a minted id.');
        return false;
      }

      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          await device.connect(timeout: const Duration(seconds: 20));
          // EVERYTHING past the connect is inside this `finally` now — a
          // throw out of `discoverServices()` or `GattBandLink(...)` used to
          // skip the disconnect below entirely, wedging the device connected
          // with nothing left to tear it down.
          try {
            final services = await device.discoverServices();
            final link = GattBandLink(
              entry: kPineTime,
              services: services,
              onLog: (m) => debugPrint('[pinetime] $m'),
            );
            _link = link;
            // ONE `finally { await stop(); }` for everything past this point
            // — a throw out of `missingCharacteristics`, `BandHost(...)` or
            // `host.run` itself would otherwise leave `_link`/`_host` set
            // with nothing left to clear them.
            try {
              final missing = link
                  .missingCharacteristics(kPineTime.requiredCharacteristics);
              if (missing.isNotEmpty) {
                debugPrint('[pinetime] ${kPineTime.label}: missing required '
                    'characteristic(s) '
                    '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
                return false;
              }
              final host = BandHost(
                adapter: const PineTimeAdapter(),
                deviceId: deviceId,
                onLog: (m) => debugPrint('[pinetime] $m'),
              );
              _host = host;
              await host.run(link).timeout(_listenWindow, onTimeout: () {});
              return true;
            } finally {
              await stop();
            }
          } finally {
            try {
              await device.disconnect();
            } catch (_) {/* already gone */}
          }
        } catch (e) {
          debugPrint('[pinetime] connect failed: $e');
          return false;
        }
      });
    } catch (e) {
      debugPrint('[pinetime] sync failed: $e');
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
