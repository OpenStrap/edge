// The HOST for a paired Jyou/Y5-class band: connect to its stored remote id,
// drive [JyouAdapter] over the link, bank what comes back, disconnect.
//
// NOTHING HERE HAS MET HARDWARE (ASSUMPTIONS R6). The registry entry stays
// EXPERIMENTAL, `JyouAdapter.signals` stays `const {}`, and nothing this file
// writes becomes a number — every row it commits carries a non-null `source`.
//
// THIN COUSIN OF `oura_link.dart`, MINUS THE AUTH/CURSOR MACHINERY. There is
// no pairing key, no drain cursor and no time anchor to hold: the band has no
// auth, offloads nothing (it just streams live), and every frame is stamped
// on arrival. So this is a one-shot [JyouLink.sync] — connect, listen for
// whatever the band sends on its own over one flush window, tear down —
// with none of the state [OuraLink] persists between sessions.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../data/db.dart';
import 'adapters/_registry.dart';
import 'adapters/gatt_link.dart';
import 'adapters/host.dart' show BandHost;
import 'adapters/jyou.dart';
import 'ble_state.dart' show withSecondaryLinkSlot;

/// The live link to a paired Jyou band. One instance; a second concurrent
/// band of this family is not a thing anyone asked for.
class JyouLink {
  JyouLink._();
  static final JyouLink instance = JyouLink._();

  /// The `device` row for the paired band, or null.
  static Future<Map<String, Object?>?> pairedRow() async {
    for (final r in await LocalDb.deviceRows()) {
      if (r['adapter_id'] == kJyou.id) return r;
    }
    return null;
  }

  /// The most recent battery/firmware note the band reported, or null.
  int? get batteryPct => _batteryPct;
  String? get firmware => _firmware;
  int? _batteryPct;
  String? _firmware;

  GattBandLink? _link;
  BandHost? _host;
  bool _busy = false;

  /// How long one sync session listens before tearing down. There is no
  /// drain to finish and no cursor to exhaust — the band just streams
  /// whatever it has (device info/battery on connect, steps/HR as its own
  /// sensor produces one) — so this is a plain window, not a completion
  /// signal.
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
    try {
      final row = await pairedRow();
      if (row == null) return false;
      final deviceId = row['id'] as String?;
      final remoteId = row['remote_id'] as String?;
      if (deviceId == null || remoteId == null || remoteId.isEmpty) {
        return false;
      }
      if (deviceId == LocalDb.kPrimaryDeviceId) {
        // The primary band's id, permanently. This band writing under it
        // would interleave its (undecoded, sample-less) rows with the
        // band's own.
        debugPrint('[jyou] refusing to sync: the row claims the primary '
            'device id — re-pair it with a minted id.');
        return false;
      }

      // A cap on concurrent SECONDARY links (never the primary band's own
      // connect — see ble_state.dart's kMaxConcurrentSecondaryLinks doc).
      return await withSecondaryLinkSlot(() async {
        try {
          final device = BluetoothDevice.fromId(remoteId);
          await device.connect(timeout: const Duration(seconds: 20));
          final services = await device.discoverServices();
          final link = GattBandLink(
            entry: kJyou,
            services: services,
            onLog: (m) => debugPrint('[jyou] $m'),
          );
          _link = link;
          final missing =
              link.missingCharacteristics(kJyou.requiredCharacteristics);
          if (missing.isNotEmpty) {
            debugPrint('[jyou] ${kJyou.label}: missing required '
                'characteristic(s) '
                '${missing.map((u) => u.substring(0, 8)).join(", ")}.');
            await device.disconnect().catchError((_) {});
            return false;
          }
          final host = BandHost(
            adapter: const JyouAdapter(),
            deviceId: deviceId,
            onLog: (m) => debugPrint('[jyou] $m'),
            onNote: _handleNote,
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
          debugPrint('[jyou] connect failed: $e');
          return false;
        }
      });
    } catch (e) {
      debugPrint('[jyou] sync failed: $e');
      return false;
    }
  }

  void _handleNote(String key, Object? value) {
    switch (key) {
      case 'battery':
        if (value is int) _batteryPct = value;
      case 'firmware':
        if (value is String) _firmware = value;
      default:
        debugPrint('[jyou] $key = $value');
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
