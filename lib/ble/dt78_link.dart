// The HOST for a paired DT78/DT92/DT66-family band: connect to its stored
// remote id, drive [Dt78Adapter] over the link, bank what comes back,
// disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `Dt78Adapter.signals` stays `const {}`, and nothing this file
// writes becomes a number — every row it commits carries a non-null `source`.
//
// THIN COUSIN OF `pinetime_link.dart`. There is no drain cursor and no time
// anchor to hold — the four startup polls are fire-and-forget and nothing
// here waits on a reply — so this is the same one-shot `sync()` shape:
// connect, listen for whatever the watch sends over one flush window, tear
// down.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/_registry.dart';
import 'adapters/dt78.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'ble_state.dart' show withSecondaryLinkSlot;

/// The live link to a paired DT78/DT92/DT66-family band. One instance; a
/// second concurrent unit is not a thing anyone asked for.
class Dt78Link {
  Dt78Link._();
  static final Dt78Link instance = Dt78Link._();

  /// The `device` row for the paired band, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kDt78.id) return r;
    }
    return null;
  }

  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// Whether a sync is already in flight. Read this BEFORE calling [sync] to
  /// tell "already syncing" apart from "could not reach the watch" — both
  /// collapse to the same `false` return from [sync] itself, which is the
  /// right answer for the "did this session write anything" question but the
  /// wrong one for the snack bar, where "already running" is not a failure.
  bool get busy => _busy;

  /// How long one sync session listens before tearing down. There is no
  /// drain to finish and no cursor to exhaust — the watch just answers the
  /// startup polls and whatever else it sends unprompted — so this is a
  /// plain window, not a completion signal.
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
    // snackbar never replaced with a result. Same fix as `pinetime_link.dart`.
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
        debugPrint('[dt78] refusing to sync: the row claims the primary '
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
          debugPrint('[dt78] connect failed: $e');
          return false;
        }
        // From here on the watch IS connected, so every exit — a thrown
        // service discovery, a missing characteristic, a run() that throws,
        // or the plain success path — must disconnect it. One `finally`
        // covering the whole of that, rather than the two separate
        // `disconnect()` call sites the two failure arms used to each need
        // to remember on their own, which is exactly the shape that leaves
        // the watch connected the day a THIRD failure arm is added and
        // forgets to.
        try {
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kDt78,
            services: services,
            onLog: (m) => debugPrint('[dt78] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kDt78.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[dt78] ${kDt78.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            return false;
          }
          final host = BandHost(
            adapter: const Dt78Adapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[dt78] $m'),
          );
          _host = host;
          await host.run(link).timeout(_listenWindow, onTimeout: () {});
          return true;
        } catch (e) {
          debugPrint('[dt78] sync failed: $e');
          return false;
        } finally {
          await stop();
          try {
            await device.disconnect();
          } catch (_) {/* already gone */}
        }
      });
    } catch (e) {
      debugPrint('[dt78] sync failed: $e');
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
