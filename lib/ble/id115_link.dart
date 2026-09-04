// The HOST for a paired ID115: connect to its stored remote id, drive
// [Id115Adapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `Id115Adapter.signals` stays `const {}`, and nothing this
// file writes becomes a number — every row it commits carries a non-null
// `source`.
//
// THIN COUSIN OF `smaq2oss_link.dart`. There is no pairing key, no cursor and
// no documented "must write this or it stalls" behaviour to reproduce — see
// `id115.dart`'s own header on why nothing is ever written. So this is a
// plain bounded listen window: connect, catch whatever the board sends on
// its own over either channel, tear down.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/id115.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired ID115. One instance; a second concurrent one is
/// not a thing anyone asked for.
class Id115Link {
  Id115Link._();
  static final Id115Link instance = Id115Link._();

  /// How long one session listens before tearing down. There is no drain to
  /// finish and no cursor to exhaust — see the header note.
  static const Duration _listenWindow = Duration(seconds: 20);

  /// The `device` row for the paired board, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kId115.id) return r;
    }
    return null;
  }

  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

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
    // The WHOLE body is guarded, not just the connect below: `sync()` is
    // documented to never throw, and a database read failure or a
    // malformed stored row (a cast that does not hold) is exactly the kind
    // of failure a caller with no try/catch of its own (`_syncId115`)
    // would otherwise have to survive unassisted.
    try {
      final row = await pairedRow();
      if (row == null) return false;
      final deviceId = row['id'] as String?;
      final remoteId = row['remote_id'] as String?;
      if (deviceId == null || remoteId == null || remoteId.isEmpty) {
        return false;
      }
      if (deviceId == LocalDb.kPrimaryDeviceId) {
        debugPrint('[id115] refusing to sync: the row claims the primary '
            'device id — re-pair it with a minted id.');
        return false;
      }

      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      return await withSecondaryLinkSlot(() async {
        final device = BluetoothDevice.fromId(remoteId);
        try {
          await device.connect(timeout: const Duration(seconds: 20));
        } catch (e) {
          // Never connected: nothing to disconnect.
          debugPrint('[id115] connect failed: $e');
          return false;
        }
        // EVERYTHING past this point runs with the radio connected, so a
        // `finally` — not a return inside a bare try/catch — is what
        // guarantees `stop()`/`disconnect()` on every exit, including a
        // `discoverServices`/`GattBandLink`/`BandHost`/`host.run` throw. A
        // caught-and-returned exception here used to skip that cleanup and
        // leave the GATT connection open.
        try {
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kId115,
            services: services,
            onLog: (m) => debugPrint('[id115] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kId115.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[id115] ${kId115.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const Id115Adapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[id115] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          await host.run(link).timeout(_listenWindow, onTimeout: () {});
          return true;
        } catch (e) {
          debugPrint('[id115] connect failed: $e');
          return false;
        } finally {
          await stop();
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      });
    } catch (e) {
      debugPrint('[id115] sync failed: $e');
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
  }

  /// Bank one frame verbatim — this board's decode coverage is deliberately
  /// zero (see `id115.dart`'s own header).
  ArchiveRecord? _buildArchiveRow(List<int> bytes, int capturedAtMs) {
    if (bytes.isEmpty) return null;
    return ArchiveRecord(
      hex: _hex(bytes),
      // NULL, not 0 — see `tlw64_link.dart`'s identical note on why a
      // constant 0 would be accidental thinning-exemption policy.
      counter: null,
      packetType: bytes[0],
      recTs: null,
      capturedAt: capturedAtMs,
      reason: 'id115_frame',
    );
  }
}
