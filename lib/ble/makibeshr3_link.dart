// The HOST for a paired Makibes HR3: connect to its stored remote id, drive
// [MakibesHr3Adapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `MakibesHr3Adapter.signals` stays `const {}`, and nothing
// this file writes becomes a number — every row it commits carries a
// non-null `source`.
//
// THIN COUSIN OF `id115_link.dart`. There is no pairing key, no cursor and no
// documented "must write this or it stalls" behaviour to reproduce — see
// `makibeshr3.dart`'s own header on why nothing is ever written. So this is a
// plain bounded listen window: connect, catch whatever the board sends on
// its own, tear down.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import '../data/models.dart' show ArchiveRecord;
import 'adapters/_registry.dart';
import 'adapters/adapter.dart' show ReplayBandLink;
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/makibeshr3.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The live link to a paired Makibes HR3. One instance; a second concurrent
/// one is not a thing anyone asked for.
class MakibesHr3Link {
  MakibesHr3Link._();
  static final MakibesHr3Link instance = MakibesHr3Link._();

  /// How long one session listens before tearing down. There is no drain to
  /// finish and no cursor to exhaust — see the header note.
  static const Duration _listenWindow = Duration(seconds: 20);

  /// The `device` row for the paired board, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kMakibesHr3.id) return r;
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
    // of failure a caller with no try/catch of its own (`_syncMakibesHr3`)
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
        debugPrint('[makibeshr3] refusing to sync: the row claims the '
            'primary device id — re-pair it with a minted id.');
        return false;
      }

      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      return await withSecondaryLinkSlot(() async {
        final device = BluetoothDevice.fromId(remoteId);
        // EVERYTHING past this point, including `connect()` itself, so a
        // `finally` — not a return inside a bare try/catch — is what
        // guarantees `stop()`/`disconnect()` on every exit, including a
        // `connect`/`discoverServices`/`GattBandLink`/`BandHost`/`host.run`
        // throw. A `connect()` timeout can leave the platform BLE stack with
        // connection state for this peripheral even though it never
        // resolved; skipping the disconnect there used to strand it.
        try {
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kMakibesHr3,
            services: services,
            onLog: (m) => debugPrint('[makibeshr3] $m'),
          );
          _link = link;
          final missing = link
              .missingCharacteristics(kMakibesHr3.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[makibeshr3] ${kMakibesHr3.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const MakibesHr3Adapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[makibeshr3] $m'),
            buildArchive: _buildArchiveRow,
          );
          _host = host;
          await host.run(link).timeout(_listenWindow, onTimeout: () {});
          return true;
        } catch (e) {
          debugPrint('[makibeshr3] connect failed: $e');
          return false;
        } finally {
          // `BandHost.stop()` awaits `_runSub?.cancel()` and a final
          // `_commit`, neither guarded internally — a failure in either
          // must not skip the disconnect below.
          try {
            await stop();
          } catch (_) {/* best-effort teardown */}
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      });
    } catch (e) {
      debugPrint('[makibeshr3] sync failed: $e');
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
  /// zero (see `makibeshr3.dart`'s own header).
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
      reason: 'makibeshr3_frame',
    );
  }

  /// Feed raw notification bytes as if a paired board with [deviceId] were
  /// connected, and archive them. The only way in: the real entry point is a
  /// BLE notification and `flutter_blue_plus` has no simulator path, so
  /// without this seam nothing past `sync()`'s connect could be exercised.
  ///
  /// Replays through the SAME [BandHost]/[_buildArchiveRow] a real session
  /// uses, over a [ReplayBandLink] — a seam that skipped either would prove
  /// the wrong thing.
  @visibleForTesting
  Future<void> ingestForTest(
    String deviceId,
    List<(int, List<int>)> arrivals,
  ) async {
    final host = BandHost(
      adapter: const MakibesHr3Adapter(),
      deviceId: deviceId,
      onLog: (m) => debugPrint('[makibeshr3] $m'),
      buildArchive: _buildArchiveRow,
    );
    _host = host;
    final link = ReplayBandLink();
    final done = host.run(link);
    for (final (sec, value) in arrivals) {
      link.feed(kMakibesHr3ReportChar, value, atSec: sec);
    }
    // Close, then wait for `run()` to actually finish, rather than guessing
    // at a delay: the adapter's `await for` is asynchronous and a flush
    // racing it would silently drop the tail.
    await link.close();
    await done;
    await host.stop();
    _host = null;
  }
}
